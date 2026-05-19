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
block_and_line_symbols: SymbolRasterizer = .geometric,

pub fn init(allocator: std.mem.Allocator) !Self {
    var library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    return .{ .library = library, .allocator = allocator };
}

pub fn deinit(self: *Self) void {
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

    // FT_LOAD_NO_BITMAP forces an outline (needed for italic-synth shearing,
    // and avoids embedded bitmap strikes that may not match our cell metrics).
    const hint_flags: c_long = switch (self.hinting) {
        .none => c.FT_LOAD_NO_HINTING,
        .slight => c.FT_LOAD_TARGET_LIGHT,
        .normal => c.FT_LOAD_TARGET_NORMAL,
        .mono => c.FT_LOAD_TARGET_MONO,
    };
    const load_flags: c.FT_Int32 = @intCast(c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_BITMAP | hint_flags);
    if (c.FT_Load_Char(face, codepoint, load_flags) != 0) return .{ .format = .alpha };

    // Synthetic italic: 12 degree shear of the outline
    if (font.synth.italic) {
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
    if (bm.pitch <= 0) return .{ .format = .alpha }; // skip bottom-up bitmaps (unusual for normal mode)

    const pitch: u32 = @intCast(bm.pitch);
    const off_x: i32 = face.*.glyph.*.bitmap_left;
    const off_y: i32 = font.ascent_px - face.*.glyph.*.bitmap_top;
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
