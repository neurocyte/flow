/// FreeType-based glyph rasterizer
const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/ftbbox.h");
    @cInclude("freetype/tttables.h");
});
const XY = @import("xy").XY;
const flow_sprite = @import("flow_sprite");
pub const font_finder = @import("font_finder");
const fallback_resolver = @import("fallback_resolver");

const Self = @This();

pub const GlyphSplit = enum { single, left, right };
const Hinting = @import("gui_config").Hinting;
const SymbolRasterizer = @import("gui_config").SymbolRasterizer;
const uucode_utils = @import("uucode_utils");
const uucode = uucode_utils.uucode;
const glyph_constraint = @import("glyph_constraint");
const blit = @import("blit");

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
    size_px: u16 = 16,
    ascent_px: i32 = 0,
    cap_height_px: i32 = 0,
    underline_position: i32 = 0,
    underline_thickness: u16 = 1,
    box_thickness: u16 = 1,
    face: c.FT_Face = null,
    synth: SynthFlags = .{},

    face_width: f64 = 0,
    face_height: f64 = 0,
    face_y: f64 = 0,
    icon_height: f64 = 0,
    icon_height_single: f64 = 0,

    primary_metrics: fallback_resolver.FaceMetrics = .{},
};

pub fn constraintMetrics(font: Font) glyph_constraint.Metrics {
    return .{
        .cell_width = font.cell_size.x,
        .cell_height = font.cell_size.y,
        .face_width = font.face_width,
        .face_height = font.face_height,
        .face_y = font.face_y,
        .icon_height = font.icon_height,
        .icon_height_single = font.icon_height_single,
    };
}

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

const CachedFace = struct {
    path: []u8,
    face_index: i32,
    face: c.FT_Face,
    size_px: u16,
    generation: u64,
};

library: c.FT_Library,
allocator: std.mem.Allocator,
hinting: Hinting = .normal,
faces: std.ArrayListUnmanaged(CachedFace) = .empty,
generation: u64 = 0,
regular_path: ?[]u8 = null,
block_and_line_symbols: SymbolRasterizer = .default,
allow_color_glyphs: bool = true,
fallback: ?*FallbackResolver = null,

pub fn init(allocator: std.mem.Allocator) !Self {
    var library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    return .{ .library = library, .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    if (self.fallback) |fb| {
        fb.deinit(self.library, self.allocator);
        self.allocator.destroy(fb);
    }
    self.fallback = null;
    if (self.regular_path) |p| self.allocator.free(p);
    self.regular_path = null;
    for (self.faces.items) |entry| {
        _ = c.FT_Done_Face(entry.face);
        self.allocator.free(entry.path);
    }
    self.faces.deinit(self.allocator);
    _ = c.FT_Done_FreeType(self.library);
}

pub fn releaseUnusedFaces(self: *Self) void {
    var i: usize = 0;
    while (i < self.faces.items.len) {
        const entry = self.faces.items[i];
        if (entry.generation == self.generation) {
            i += 1;
            continue;
        }
        _ = c.FT_Done_Face(entry.face);
        self.allocator.free(entry.path);
        _ = self.faces.swapRemove(i);
    }
}

fn cachedFace(self: *Self, path: []const u8, face_index: i32, size_px: u16) !c.FT_Face {
    for (self.faces.items) |*entry| {
        if (entry.face_index != face_index or !std.mem.eql(u8, entry.path, path)) continue;
        entry.generation = self.generation;
        if (entry.size_px != size_px) {
            if (!setFacePixelSize(entry.face, size_px)) return error.SetSizeFailed;
            entry.size_px = size_px;
        }
        return entry.face;
    }

    const path_z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(self.library, path_z.ptr, face_index, &face) != 0)
        return error.FaceLoadFailed;
    errdefer _ = c.FT_Done_Face(face);

    if (!setFacePixelSize(face, size_px))
        return error.SetSizeFailed;

    const path_copy = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(path_copy);

    try self.faces.append(self.allocator, .{
        .path = path_copy,
        .face_index = face_index,
        .face = face,
        .size_px = size_px,
        .generation = self.generation,
    });
    return face;
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const match = try font_finder.findFont(self.allocator, name);
    defer self.allocator.free(match.path);
    return self.loadFontFromPath(match.path, match.face_index, size_px);
}

pub fn loadFontFromPath(self: *Self, path: []const u8, face_index: i32, size_px: u16) !Font {
    const face = try self.cachedFace(path, face_index, size_px);

    const sm = face.*.size.*.metrics;
    const m_ascent: f64 = @as(f64, @floatFromInt(sm.ascender)) / 64.0;
    const m_descent: f64 = @as(f64, @floatFromInt(sm.descender)) / 64.0; // < 0, below baseline
    const m_line_height: f64 = @as(f64, @floatFromInt(sm.height)) / 64.0;
    const m_line_gap: f64 = @max(0.0, m_line_height - (m_ascent - m_descent));
    const m_face_baseline: f64 = (m_line_gap / 2.0) - m_descent; // baseline up from cell bottom
    const cell_h_f: f64 = @max(1.0, @round(m_line_height));
    const cell_h: u16 = @intFromFloat(cell_h_f);
    const cell_baseline: f64 = @round(m_face_baseline - (cell_h_f - m_line_height) / 2.0);
    const ascent_px: i32 = @intFromFloat(cell_h_f - cell_baseline);

    // Cell width from advance of 'M', cap height from its top bearing
    var cell_w: u16 = @max(1, size_px / 2);
    var cap_height_px: i32 = @divTrunc(ascent_px * 7, 10); // fallback
    var face_advance_px: f64 = @floatFromInt(cell_w); // unrounded advance
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0) {
        const adv: i32 = @intCast((face.*.glyph.*.advance.x + 32) >> 6);
        if (adv > 0) {
            cell_w = @intCast(adv);
            face_advance_px = @as(f64, @floatFromInt(face.*.glyph.*.advance.x)) / 64.0;
        }
        const cap: i32 = @intCast((face.*.glyph.*.metrics.horiBearingY + 32) >> 6);
        if (cap > 0) cap_height_px = cap;
    }

    const grid_metrics = glyph_constraint.metricsFromFace(.{
        .cell_width = cell_w,
        .cell_height = cell_h,
        .cell_baseline_from_top = @floatFromInt(ascent_px),
        .face_advance = face_advance_px,
        .face_ascent = m_ascent,
        .face_descent = m_descent,
        .face_line_gap = m_line_gap,
        .cap_height = @floatFromInt(cap_height_px),
    });

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
    const box_thk_px: u16 = @intCast(@max(1, @divFloor(ul_thk_q6 + 63, 64)));
    // Convert from baseline-up centre to cell-top-down top-edge.
    const ul_centre_from_top: i32 = ascent_px - ul_pos_px;
    const ul_top_unclamped: i32 = ul_centre_from_top - @divTrunc(@as(i32, ul_thk_px), 2);
    const cell_h_i: i32 = @intCast(cell_h);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_top_unclamped));

    return .{
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .size_px = size_px,
        .ascent_px = ascent_px,
        .cap_height_px = cap_height_px,
        .underline_position = ul_top,
        .underline_thickness = ul_thk_px,
        .box_thickness = box_thk_px,
        .face = face,
        .face_width = grid_metrics.face_width,
        .face_height = grid_metrics.face_height,
        .face_y = grid_metrics.face_y,
        .icon_height = grid_metrics.icon_height,
        .icon_height_single = grid_metrics.icon_height_single,
        .primary_metrics = ftFaceMetrics(face),
    };
}

/// Resolve a face for a given family + weight + style
pub fn resolveFace(self: *Self, req: FaceRequest) !FaceResolution {
    if (req.is_baseline) {
        self.generation += 1;
        if (self.regular_path) |old| self.allocator.free(old);
        self.regular_path = null;
    }

    const match = try font_finder.findFontVariant(
        self.allocator,
        req.family,
        req.css_weight,
        req.italic,
    );
    errdefer self.allocator.free(match.path);

    const is_real = if (req.is_baseline)
        true
    else if (self.regular_path) |reg|
        !std.mem.eql(u8, match.path, reg)
    else
        true;

    const font = try self.loadFontFromPath(match.path, match.face_index, req.size_px);

    if (req.is_baseline) {
        self.regular_path = match.path; // transfer ownership
    } else {
        self.allocator.free(match.path);
    }

    return .{ .font = font, .is_real_match = is_real };
}

pub fn glyphAdvance(self: *const Self, font: Font, codepoint: u21) ?u16 {
    const face = font.face orelse return null;
    if (c.FT_Get_Char_Index(face, codepoint) == 0) {
        // Check fallback faces
        if (self.fallback) |fb| {
            if (fb.resolveExisting(codepoint, false)) |fb_face| {
                if (c.FT_Load_Char(fb_face.ft_face, codepoint, c.FT_LOAD_DEFAULT) == 0) {
                    const adv: i32 = @intCast((fb_face.ft_face.*.glyph.*.advance.x + 32) >> 6);
                    return if (adv > 0) @intCast(adv) else null;
                }
            }
        }
        return null;
    }
    if (c.FT_Load_Char(face, codepoint, c.FT_LOAD_DEFAULT) != 0) return null;
    const adv: i32 = @intCast((face.*.glyph.*.advance.x + 32) >> 6);
    return if (adv > 0) @intCast(adv) else null;
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    emoji_presentation: bool,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
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

    if (self.block_and_line_symbols == .sprite) {
        if (flow_sprite.renderSprite(self.allocator, codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch, font.box_thickness))
            return .{ .format = .alpha };
    }

    const face = font.face orelse return .{ .format = .alpha };
    const metrics = constraintMetrics(font);

    // For emoji presentation prefer a color fallback over a monochrome primary
    const want_color = emoji_presentation and self.allow_color_glyphs;
    if (c.FT_Get_Char_Index(face, codepoint) != 0 and (!want_color or ftHasColor(face))) {
        return renderFromFace(self, face, font.ascent_px, font.synth, codepoint, constraint, constraint_width, split, font.cell_size, metrics, staging_buf);
    }

    const resolver: ?*FallbackResolver = if (self.fallback) |existing| existing else blk: {
        const new_fb = self.allocator.create(FallbackResolver) catch break :blk null;
        new_fb.* = .{};
        @constCast(&self.fallback).* = new_fb;
        break :blk new_fb;
    };
    if (resolver) |fb| {
        if (fb.resolve(self.library, self.allocator, codepoint, font.size_px, want_color, font.primary_metrics)) |fb_face| {
            return renderFromFace(self, fb_face.ft_face, font.ascent_px, .{}, codepoint, constraint, constraint_width, split, font.cell_size, metrics, staging_buf);
        }
    }

    return renderFromFace(self, face, font.ascent_px, font.synth, codepoint, constraint, constraint_width, split, font.cell_size, metrics, staging_buf);
}

/// FreeType's FT_HAS_COLOR(face) macro:
///   #define FT_HAS_COLOR( face ) ( !!( (face)->face_flags & FT_FACE_FLAG_COLOR ) )
inline fn ftHasColor(face: c.FT_Face) bool {
    return (face.*.face_flags & c.FT_FACE_FLAG_COLOR) != 0;
}

fn renderFromFace(
    self: *const Self,
    face: c.FT_Face,
    cell_ascent_px: i32,
    synth: SynthFlags,
    codepoint: u21,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
    split: GlyphSplit,
    cell_size: XY(u16),
    metrics: glyph_constraint.Metrics,
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);

    const has_color_face = self.allow_color_glyphs and ftHasColor(face);
    const constrained = constraint.doesAnything() and !has_color_face;

    const hint_flags: c_long = switch (self.hinting) {
        .none => c.FT_LOAD_NO_HINTING,
        .slight => c.FT_LOAD_TARGET_LIGHT,
        .normal => c.FT_LOAD_TARGET_NORMAL,
        .mono => c.FT_LOAD_TARGET_MONO,
    };

    const glyph_hint_flags: c_long = if (constrained) c.FT_LOAD_NO_HINTING else hint_flags;
    const load_flags: c.FT_Int32 = if (has_color_face)
        @intCast(c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR | hint_flags)
    else
        @intCast(c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_BITMAP | glyph_hint_flags);
    if (c.FT_Load_Char(face, codepoint, load_flags) != 0) return .{ .format = .alpha };

    if (synth.italic and !has_color_face) {
        var shear: c.FT_Matrix = .{
            .xx = 0x10000,
            .xy = 13932,
            .yx = 0,
            .yy = 0x10000,
        };
        c.FT_Outline_Transform(&face.*.glyph.*.outline, &shear);
    }

    if (constrained and face.*.glyph.*.outline.n_points > 0)
        applyConstraintOutline(&face.*.glyph.*.outline, constraint, metrics, constraint_width, @intCast(cell_size.y), cell_ascent_px);

    const render_mode: c.FT_Render_Mode = if (self.hinting == .mono and !has_color_face)
        c.FT_RENDER_MODE_MONO
    else
        c.FT_RENDER_MODE_NORMAL;
    if (c.FT_Render_Glyph(face.*.glyph, render_mode) != 0) return .{ .format = .alpha };

    const bm = face.*.glyph.*.bitmap;
    if (bm.rows == 0 or bm.width == 0) return .{ .format = .alpha };
    if (bm.pitch <= 0) return .{ .format = .alpha };

    const pitch: u32 = @intCast(bm.pitch);
    const is_mono = bm.pixel_mode == c.FT_PIXEL_MODE_MONO;
    const gw: i32 = @intCast(bm.width);
    const target_w: i32 = if (split == .single) @as(i32, @intCast(cell_size.x)) else buf_w;

    if (bm.pixel_mode == c.FT_PIXEL_MODE_BGRA) {
        blit.colorBGRA(staging_buf, buf_w, buf_h, bm.buffer, pitch, gw, @intCast(bm.rows), target_w);
        return .{ .format = .color };
    }

    const off_x: i32 = face.*.glyph.*.bitmap_left;
    const off_y: i32 = if (constrained)
        @as(i32, @intCast(cell_size.y)) - face.*.glyph.*.bitmap_top
    else
        cell_ascent_px - face.*.glyph.*.bitmap_top;

    const glyph_extent: i32 = off_x + gw;
    const center_offset: i32 = if (!constrained and split != .single and glyph_extent < buf_w)
        @divTrunc(buf_w - glyph_extent, 2)
    else
        0;

    const base_x: i32 = center_offset + off_x;
    blit.alphaPitched(staging_buf, buf_w, buf_h, bm.buffer, pitch, gw, @intCast(bm.rows), base_x, off_y, is_mono);
    return .{ .format = .alpha };
}

fn applyConstraintOutline(
    outline: *c.FT_Outline,
    constraint: glyph_constraint.Constraint,
    metrics: glyph_constraint.Metrics,
    constraint_width: u2,
    cell_height: i32,
    cell_baseline_from_top: i32,
) void {
    if (outline.n_points <= 0) return;

    var bbox: c.FT_BBox = undefined;
    _ = c.FT_Outline_Get_BBox(outline, &bbox);
    const rect_x: f64 = @as(f64, @floatFromInt(bbox.xMin)) / 64.0;
    const rect_y: f64 = @as(f64, @floatFromInt(bbox.yMin)) / 64.0;
    const rect_w: f64 = @as(f64, @floatFromInt(bbox.xMax - bbox.xMin)) / 64.0;
    const rect_h: f64 = @as(f64, @floatFromInt(bbox.yMax - bbox.yMin)) / 64.0;
    if (rect_w <= 0 or rect_h <= 0) return;

    const baseline_from_bottom: f64 = @as(f64, @floatFromInt(cell_height)) -
        @as(f64, @floatFromInt(cell_baseline_from_top));

    const cg = constraint.constrain(.{
        .width = rect_w,
        .height = rect_h,
        .x = rect_x,
        .y = rect_y + baseline_from_bottom,
    }, metrics, constraint_width);

    const cell_w_f: f64 = @floatFromInt(metrics.cell_width);
    var gx: f64 = cg.x;
    if (constraint.size != .stretch and metrics.face_width < cell_w_f)
        gx += @round((cell_w_f - metrics.face_width) / 2.0);

    const scale_x: f64 = cg.width / rect_w;
    const scale_y: f64 = cg.height / rect_h;

    const points = outline.points[0..@intCast(outline.n_points)];
    for (points) |*p| {
        const px: f64 = (@as(f64, @floatFromInt(p.x)) / 64.0 - rect_x) * scale_x + gx;
        const py: f64 = (@as(f64, @floatFromInt(p.y)) / 64.0 - rect_y) * scale_y + cg.y;
        p.x = @intFromFloat(@round(px * 64.0));
        p.y = @intFromFloat(@round(py * 64.0));
    }
}

const nerd_font_data = @embedFile("nerd_font");

const build_options = @import("build_options");

const noto_emoji_data: []const u8 = if (build_options.embed_emoji) @embedFile("noto_emoji_font") else "";

fn setFacePixelSize(face: c.FT_Face, size_px: u16) bool {
    if (c.FT_Set_Pixel_Sizes(face, 0, size_px) == 0) return true;

    const n = face.*.num_fixed_sizes;
    if (n <= 0) return false;

    var best: c_int = 0;
    var best_score: i32 = std.math.maxInt(i32);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const h: i32 = @intCast(face.*.available_sizes[@intCast(i)].height);
        const d: i32 = @as(i32, @intCast(size_px)) - h;
        // prefer strikes >= size_px
        const score: i32 = if (d <= 0) -d else d * 2;
        if (score < best_score) {
            best_score = score;
            best = i;
        }
    }
    return c.FT_Select_Size(face, best) == 0;
}

const FtBackend = struct {
    pub const Context = c.FT_Library;
    pub const Face = struct {
        ft_face: c.FT_Face,
        has_color: bool,
        ascent_px: i32,
    };

    pub const embedded_fonts = [_]fallback_resolver.EmbeddedFont{
        .{ .data = nerd_font_data, .is_color = false, .tag = "<embedded:nerd_font>" },
        .{ .data = noto_emoji_data, .is_color = true, .tag = "<embedded:noto_color_emoji>" },
    };

    pub fn preferColor(codepoint: u21) bool {
        return uucode.get(.is_emoji_presentation, @intCast(codepoint));
    }

    fn faceFromHandle(face: c.FT_Face, has_color: bool) Face {
        const ascent: i32 = @intCast((face.*.size.*.metrics.ascender + 32) >> 6);
        return .{ .ft_face = face, .has_color = has_color, .ascent_px = ascent };
    }

    pub fn loadEmbedded(library: c.FT_Library, _: std.mem.Allocator, data: []const u8, size_px: u16, is_color: bool) ?Face {
        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(library, data.ptr, @intCast(data.len), 0, &face) != 0) return null;
        if (!setFacePixelSize(face, size_px)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        return faceFromHandle(face, is_color);
    }

    pub fn loadPath(library: c.FT_Library, allocator: std.mem.Allocator, cand: font_finder.FallbackCandidate, size_px: u16) ?Face {
        const path_z = allocator.dupeZ(u8, cand.path) catch return null;
        defer allocator.free(path_z);
        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(library, path_z.ptr, cand.face_index, &face) != 0) return null;
        if (!setFacePixelSize(face, size_px)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        return faceFromHandle(face, cand.has_color);
    }

    pub fn hasGlyph(face: *const Face, codepoint: u21) bool {
        return c.FT_Get_Char_Index(face.ft_face, codepoint) != 0;
    }

    pub fn faceMetrics(face: *const Face) fallback_resolver.FaceMetrics {
        return ftFaceMetrics(face.ft_face);
    }

    pub fn setFaceSize(_: c.FT_Library, face: *Face, size_px: u16) void {
        if (!setFacePixelSize(face.ft_face, size_px)) return;
        face.ascent_px = @intCast((face.ft_face.*.size.*.metrics.ascender + 32) >> 6);
    }

    pub fn deinitFace(_: c.FT_Library, _: std.mem.Allocator, face: *Face) void {
        _ = c.FT_Done_Face(face.ft_face);
    }
};

fn ftFaceMetrics(ft_face: c.FT_Face) fallback_resolver.FaceMetrics {
    const sm = ft_face.*.size.*.metrics;
    const ppem: f64 = @floatFromInt(sm.y_ppem);
    const ascent: f64 = @as(f64, @floatFromInt(sm.ascender)) / 64.0;
    const line_height: f64 = @as(f64, @floatFromInt(sm.height)) / 64.0;

    var advance: f64 = if (ppem > 0) ppem * 0.5 else 8.0;
    if (c.FT_Load_Char(ft_face, 'M', c.FT_LOAD_DEFAULT) == 0) {
        const adv = @as(f64, @floatFromInt(ft_face.*.glyph.*.advance.x)) / 64.0;
        if (adv > 0) advance = adv;
    }

    var cap: ?f64 = null;
    var ex: ?f64 = null;
    const upm: f64 = @floatFromInt(@max(ft_face.*.units_per_EM, 1));
    const ppu: f64 = if (ppem > 0) ppem / upm else 0;
    if (c.FT_Get_Sfnt_Table(ft_face, c.FT_SFNT_OS2)) |os2_ptr| {
        const os2: *c.TT_OS2 = @ptrCast(@alignCast(os2_ptr));
        if (os2.*.version != 0xFFFF and os2.*.version >= 2 and ppu > 0) {
            if (os2.*.sCapHeight > 0) cap = @as(f64, @floatFromInt(os2.*.sCapHeight)) * ppu;
            if (os2.*.sxHeight > 0) ex = @as(f64, @floatFromInt(os2.*.sxHeight)) * ppu;
        }
    }

    var ic: ?f64 = null;
    if (c.FT_Get_Char_Index(ft_face, 0x6C34) != 0 and c.FT_Load_Char(ft_face, 0x6C34, c.FT_LOAD_DEFAULT) == 0) {
        const adv = @as(f64, @floatFromInt(ft_face.*.glyph.*.advance.x)) / 64.0;
        if (adv > 0) ic = adv;
    }

    return .{
        .px_per_em = if (ppem > 0) ppem else 1.0,
        .advance = advance,
        .ascent = ascent,
        .line_height = line_height,
        .cap_height = cap,
        .ex_height = ex,
        .ic_width = ic,
    };
}

const FallbackResolver = fallback_resolver.FallbackResolver(FtBackend);
