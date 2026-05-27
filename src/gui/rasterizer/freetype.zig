/// FreeType-based glyph rasterizer
const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});
const XY = @import("xy").XY;
const geometric = @import("geometric");
pub const font_finder = @import("font_finder");

const Self = @This();

pub const GlyphSplit = enum { single, left, right };
const Hinting = @import("gui_config").Hinting;
const SymbolRasterizer = @import("gui_config").SymbolRasterizer;
const uucode = @import("vaxis").uucode;

pub const RasterFormat = enum(u2) {
    alpha = 0,
    subpixel = 1,
    color = 2,
};

pub const RenderResult = struct { format: RasterFormat };

pub const Fonts = struct {};

pub const SynthFlags = packed struct(u8) {
    italic: bool = false,
    bold: bool = false,
    _pad: u6 = 0,
};

pub const Font = struct {
    cell_size: XY(u16) = .{ .x = 8, .y = 16 },
    ascent_px: i32 = 0,
    /// Top edge of the underline bar, in pixels from the top of the cell.
    underline_position: i32 = 0,
    /// Thickness of the underline bar, in pixels (>= 1).
    underline_thickness: u16 = 1,
    face: c.FT_Face = null,
    synth: SynthFlags = .{},
};

pub const FaceRequest = struct {
    family: []const u8,
    css_weight: u16,
    italic: bool,
    size_px: u16,
    /// regular face for a font set
    is_baseline: bool,
};

pub const FaceResolution = struct {
    font: Font,
    /// face differs from baseline
    is_real_match: bool,
};

library: c.FT_Library,
allocator: std.mem.Allocator,
hinting: Hinting = .normal,
regular_path: ?[]u8 = null,
block_and_line_symbols: SymbolRasterizer = .default,
fallback: ?*FallbackResolver = null,

pub fn init(allocator: std.mem.Allocator) !Self {
    var library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    return .{ .library = library, .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    if (self.fallback) |fb| {
        fb.deinit(self.allocator, self.library);
        self.allocator.destroy(fb);
    }
    self.fallback = null;
    if (self.regular_path) |p| self.allocator.free(p);
    self.regular_path = null;
    _ = c.FT_Done_FreeType(self.library);
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const path = try font_finder.findFont(self.allocator, name);
    defer self.allocator.free(path);
    return self.loadFontFromPath(path, size_px);
}

pub fn loadFontFromPath(self: *Self, path: []const u8, size_px: u16) !Font {
    const path_z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(self.library, path_z.ptr, 0, &face) != 0)
        return error.FaceLoadFailed;
    errdefer _ = c.FT_Done_Face(face);

    if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0)
        return error.SetSizeFailed;

    // Derive cell metrics from the full block glyph (U+2588), same strategy
    // as truetype.zig: the rendered bitmap defines exact cell dimensions.
    var ascent_px: i32 = @intCast((face.*.size.*.metrics.ascender + 32) >> 6);
    var cell_h: u16 = size_px;
    if (c.FT_Load_Char(face, 0x2588, c.FT_LOAD_RENDER) == 0) {
        const bm = face.*.glyph.*.bitmap;
        if (bm.rows > 0) {
            cell_h = @intCast(bm.rows);
            ascent_px = face.*.glyph.*.bitmap_top;
        }
    }

    // Cell width from advance of 'M'.
    var cell_w: u16 = @max(1, size_px / 2);
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0) {
        const adv: i32 = @intCast((face.*.glyph.*.advance.x + 32) >> 6);
        if (adv > 0) cell_w = @intCast(adv);
    }

    // Underline metrics: face fields are in font units. y_scale is 16.16 fixed
    // and produces 26.6 pixel values when multiplied with font units >> 16.
    // underline_position is the *centre* of the bar, with the y-axis pointing
    // up from the baseline (negative = below baseline, the usual case).
    const y_scale: i64 = @intCast(face.*.size.*.metrics.y_scale);
    const ul_pos_units: i64 = @intCast(face.*.underline_position);
    const ul_thk_units: i64 = @intCast(face.*.underline_thickness);
    const ul_pos_q6: i64 = @divFloor(ul_pos_units * y_scale, 1 << 16);
    const ul_thk_q6: i64 = @divFloor(ul_thk_units * y_scale, 1 << 16);
    const ul_pos_px: i32 = @intCast(@divFloor(ul_pos_q6 + 32, 64));
    const ul_thk_px_raw: i32 = @intCast(@divFloor(ul_thk_q6 + 32, 64));
    const ul_thk_px: u16 = @intCast(@max(1, ul_thk_px_raw));
    // Convert from baseline-up centre to cell-top-down top-edge.
    const ul_centre_from_top: i32 = ascent_px - ul_pos_px;
    const ul_top_unclamped: i32 = ul_centre_from_top - @divTrunc(@as(i32, ul_thk_px), 2);
    const cell_h_i: i32 = @intCast(cell_h);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_top_unclamped));

    return .{
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .ascent_px = ascent_px,
        .underline_position = ul_top,
        .underline_thickness = ul_thk_px,
        .face = face,
    };
}

/// Resolve a face for a given family + weight + style
pub fn resolveFace(self: *Self, req: FaceRequest) !FaceResolution {
    if (req.is_baseline) {
        if (self.regular_path) |old| self.allocator.free(old);
        self.regular_path = null;
    }

    const path = try font_finder.findFontVariant(
        self.allocator,
        req.family,
        req.css_weight,
        req.italic,
    );
    errdefer self.allocator.free(path);

    const is_real = if (req.is_baseline)
        true
    else if (self.regular_path) |reg|
        !std.mem.eql(u8, path, reg)
    else
        true;

    const font = try self.loadFontFromPath(path, req.size_px);

    if (req.is_baseline) {
        self.regular_path = path; // transfer ownership
    } else {
        self.allocator.free(path);
    }

    return .{ .font = font, .is_real_match = is_real };
}

/// Rasterize a glyph into the staging buffer
/// The staging buffer is RGBA8
/// alpha format is written into the red channel
pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
    const buf_h: i32 = @intCast(font.cell_size.y);
    const x_offset: i32 = switch (split) {
        .single, .left => 0,
        .right => @intCast(font.cell_size.x),
    };
    const cw: i32 = @intCast(font.cell_size.x);
    const ch: i32 = @intCast(font.cell_size.y);

    if (self.block_and_line_symbols == .geometric) {
        if (geometric.renderBlockElement(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return .{ .format = .alpha };
        if (geometric.renderBoxDrawing(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return .{ .format = .alpha };
        if (geometric.renderExtendedBlocks(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return .{ .format = .alpha };
    }

    const face = font.face orelse return .{ .format = .alpha };

    if (c.FT_Get_Char_Index(face, codepoint) != 0) {
        return renderFromFace(self, face, font.ascent_px, font.synth, codepoint, split, font.cell_size, staging_buf);
    }

    if (self.fallback) |fb| {
        if (fb.resolve(self.library, self.allocator, codepoint, font.cell_size.y)) |fb_face| {
            return renderFromFace(self, fb_face.ft_face, fb_face.ascent_px, .{}, codepoint, split, font.cell_size, staging_buf);
        }
    } else {
        const fb = self.allocator.create(FallbackResolver) catch return renderFromFace(self, face, font.ascent_px, font.synth, codepoint, split, font.cell_size, staging_buf);
        fb.* = .{};
        @constCast(&self.fallback).* = fb;
        if (fb.resolve(self.library, self.allocator, codepoint, font.cell_size.y)) |fb_face| {
            return renderFromFace(self, fb_face.ft_face, fb_face.ascent_px, .{}, codepoint, split, font.cell_size, staging_buf);
        }
    }

    return renderFromFace(self, face, font.ascent_px, font.synth, codepoint, split, font.cell_size, staging_buf);
}

fn renderFromFace(
    self: *const Self,
    face: c.FT_Face,
    ascent_px: i32,
    synth: SynthFlags,
    codepoint: u21,
    split: GlyphSplit,
    cell_size: XY(u16),
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);
    const x_offset: i32 = switch (split) {
        .single, .left => 0,
        .right => @intCast(cell_size.x),
    };

    const hint_flags: c_long = switch (self.hinting) {
        .none => c.FT_LOAD_NO_HINTING,
        .slight => c.FT_LOAD_TARGET_LIGHT,
        .normal => c.FT_LOAD_TARGET_NORMAL,
        .mono => c.FT_LOAD_TARGET_MONO,
    };
    const load_flags: c.FT_Int32 = @intCast(c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_BITMAP | hint_flags);
    if (c.FT_Load_Char(face, codepoint, load_flags) != 0) return .{ .format = .alpha };

    // Synthetic italic: 12 degree shear of the outline
    if (synth.italic) {
        var shear: c.FT_Matrix = .{
            .xx = 0x10000,
            .xy = 13932,
            .yx = 0,
            .yy = 0x10000,
        };
        c.FT_Outline_Transform(&face.*.glyph.*.outline, &shear);
    }

    const render_mode: c.FT_Render_Mode = if (self.hinting == .mono)
        c.FT_RENDER_MODE_MONO
    else
        c.FT_RENDER_MODE_NORMAL;
    if (c.FT_Render_Glyph(face.*.glyph, render_mode) != 0) return .{ .format = .alpha };

    const bm = face.*.glyph.*.bitmap;
    if (bm.rows == 0 or bm.width == 0) return .{ .format = .alpha };
    if (bm.pitch <= 0) return .{ .format = .alpha };

    const pitch: u32 = @intCast(bm.pitch);
    const off_x: i32 = face.*.glyph.*.bitmap_left;
    const off_y: i32 = ascent_px - face.*.glyph.*.bitmap_top;
    const is_mono = bm.pixel_mode == c.FT_PIXEL_MODE_MONO;

    var row: u32 = 0;
    while (row < bm.rows) : (row += 1) {
        const dst_y = off_y + @as(i32, @intCast(row));
        if (dst_y < 0 or dst_y >= buf_h) continue;

        var col: u32 = 0;
        while (col < bm.width) : (col += 1) {
            const dst_x = x_offset + off_x + @as(i32, @intCast(col));
            if (dst_x < 0 or dst_x >= buf_w) continue;

            const dst_idx: usize = @as(usize, @intCast(dst_y * buf_w + dst_x)) * 4;
            if (dst_idx >= staging_buf.len) continue;

            const px: u8 = if (is_mono) blk: {
                // 1 bit per pixel, MSB first within each byte.
                const byte = bm.buffer[row * pitch + (col >> 3)];
                const bit: u3 = @intCast(7 - (col & 7));
                break :blk if ((byte >> bit) & 1 != 0) 0xFF else 0x00;
            } else bm.buffer[row * pitch + col];
            staging_buf[dst_idx] = px;
        }
    }
    return .{ .format = .alpha };
}

const nerd_font_data = @embedFile("nerd_font");

const FallbackResolver = struct {
    const FallbackFace = struct {
        ft_face: c.FT_Face,
        has_color: bool,
        ascent_px: i32,
        path_hash: u64,
    };

    const CacheEntry = struct { found: bool, index: u8 };

    cache: std.AutoHashMapUnmanaged(u21, CacheEntry) = .empty,
    faces: std.ArrayList(FallbackFace) = .empty,
    current_size_px: u16 = 0,
    embedded_loaded: bool = false,

    fn deinit(self: *FallbackResolver, allocator: std.mem.Allocator, library: c.FT_Library) void {
        _ = library;
        for (self.faces.items) |f| _ = c.FT_Done_Face(f.ft_face);
        self.faces.deinit(allocator);
        self.cache.deinit(allocator);
    }

    fn loadEmbeddedFonts(self: *FallbackResolver, library: c.FT_Library, allocator: std.mem.Allocator, size_px: u16) void {
        if (self.embedded_loaded) return;
        self.embedded_loaded = true;

        const data = nerd_font_data;
        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(library, data.ptr, @intCast(data.len), 0, &face) != 0) return;
        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) {
            _ = c.FT_Done_Face(face);
            return;
        }
        const face_ascent: i32 = @intCast((face.*.size.*.metrics.ascender + 32) >> 6);
        self.faces.append(allocator, .{
            .ft_face = face,
            .has_color = false,
            .ascent_px = face_ascent,
            .path_hash = std.hash.Wyhash.hash(0, "<embedded:nerd_font>"),
        }) catch {
            _ = c.FT_Done_Face(face);
        };
    }

    fn resolve(
        self: *FallbackResolver,
        library: c.FT_Library,
        allocator: std.mem.Allocator,
        codepoint: u21,
        size_px: u16,
    ) ?*const FallbackFace {
        if (self.current_size_px != 0 and self.current_size_px != size_px) {
            for (self.faces.items) |f| _ = c.FT_Done_Face(f.ft_face);
            self.faces.clearRetainingCapacity();
            self.cache.clearRetainingCapacity();
            self.embedded_loaded = false;
        }
        self.current_size_px = size_px;
        self.loadEmbeddedFonts(library, allocator, size_px);

        if (self.cache.get(codepoint)) |entry| {
            return if (entry.found) &self.faces.items[entry.index] else null;
        }

        // Try system font discovery first
        const prefer_color = uucode.get(.is_emoji_presentation, @intCast(codepoint));
        const candidates = font_finder.findFallbackFonts(allocator, codepoint, prefer_color) catch return self.cacheNegative(allocator, codepoint);
        defer {
            for (candidates) |cand| allocator.free(cand.path);
            allocator.free(candidates);
        }

        for (candidates) |cand| {
            const path_hash = std.hash.Wyhash.hash(0, cand.path);

            for (self.faces.items, 0..) |existing, idx| {
                if (existing.path_hash == path_hash) {
                    if (c.FT_Get_Char_Index(existing.ft_face, codepoint) != 0) {
                        self.cache.put(allocator, codepoint, .{ .found = true, .index = @intCast(idx) }) catch {};
                        return &self.faces.items[idx];
                    }
                    break;
                }
            }

            const path_z = allocator.dupeZ(u8, cand.path) catch continue;
            defer allocator.free(path_z);

            var face: c.FT_Face = undefined;
            if (c.FT_New_Face(library, path_z.ptr, cand.face_index, &face) != 0) continue;

            if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) {
                _ = c.FT_Done_Face(face);
                continue;
            }

            if (c.FT_Get_Char_Index(face, codepoint) == 0) {
                _ = c.FT_Done_Face(face);
                continue;
            }

            const face_ascent: i32 = @intCast((face.*.size.*.metrics.ascender + 32) >> 6);

            if (self.faces.items.len >= 255) {
                _ = c.FT_Done_Face(face);
                return self.cacheNegative(allocator, codepoint);
            }

            const idx: u8 = @intCast(self.faces.items.len);
            self.faces.append(allocator, .{
                .ft_face = face,
                .has_color = cand.has_color,
                .ascent_px = face_ascent,
                .path_hash = path_hash,
            }) catch {
                _ = c.FT_Done_Face(face);
                return self.cacheNegative(allocator, codepoint);
            };

            self.cache.put(allocator, codepoint, .{ .found = true, .index = idx }) catch {};
            return &self.faces.items[idx];
        }

        // Last resort: check embedded fonts
        for (self.faces.items, 0..) |existing, idx| {
            if (existing.path_hash == std.hash.Wyhash.hash(0, "<embedded:nerd_font>") and
                c.FT_Get_Char_Index(existing.ft_face, codepoint) != 0)
            {
                self.cache.put(allocator, codepoint, .{ .found = true, .index = @intCast(idx) }) catch {};
                return &self.faces.items[idx];
            }
        }

        return self.cacheNegative(allocator, codepoint);
    }

    fn cacheNegative(self: *FallbackResolver, allocator: std.mem.Allocator, codepoint: u21) ?*const FallbackFace {
        self.cache.put(allocator, codepoint, .{ .found = false, .index = 0 }) catch {};
        return null;
    }
};
