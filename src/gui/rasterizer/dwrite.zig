/// DirectWrite glyph rasterizer
///
const std = @import("std");
const glyph_constraint = @import("glyph_constraint");
const face_metrics = @import("face_metrics");
const flow_sprite = @import("flow_sprite");
const win32 = @import("win32").everything;
const XY = @import("xy").XY;

const log = std.log.scoped(.dwrite_rasterizer);

const Self = @This();

pub const GlyphSplit = enum { single, left, right };
pub const Hinting = @import("gui_config").Hinting;
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
    cap_height_px: i32 = 0,
    underline_position: i32 = 0,
    underline_thickness: u16 = 1,
    box_thickness: u16 = 1,
    size_px: u16 = 16,
    face: ?*win32.IDWriteFontFace = null,
    synth: SynthFlags = .{},

    face_width: f64 = 0,
    face_height: f64 = 0,
    face_y: f64 = 0,
    icon_height: f64 = 0,
    icon_height_single: f64 = 0,

    primary_metrics: face_metrics.FaceMetrics = .{},
};

fn dwriteFaceMetrics(face: *win32.IDWriteFontFace, size_px: u16) face_metrics.FaceMetrics {
    var m: win32.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&m);
    const ppem: f64 = @floatFromInt(@max(size_px, 1));
    const ppu: f64 = ppem / @as(f64, @floatFromInt(@max(m.designUnitsPerEm, 1)));
    const ascent: f64 = @as(f64, @floatFromInt(m.ascent)) * ppu;

    const descent: f64 = @as(f64, @floatFromInt(m.descent)) * ppu;
    const line_gap: f64 = @max(0.0, @as(f64, @floatFromInt(m.lineGap)) * ppu);

    const cap: ?f64 = if (m.capHeight > 0) @as(f64, @floatFromInt(m.capHeight)) * ppu else null;
    const ex: ?f64 = if (m.xHeight > 0) @as(f64, @floatFromInt(m.xHeight)) * ppu else null;

    return .{
        .px_per_em = ppem,
        .advance = designGlyphAdvancePx(face, 'M', ppu) orelse (ppem * 0.5),
        .ascent = ascent,
        .line_height = ascent + descent + line_gap,
        .cap_height = cap,
        .ex_height = ex,
        .ic_width = designGlyphAdvancePx(face, '\u{6C34}', ppu),
    };
}

fn designGlyphAdvancePx(face: *win32.IDWriteFontFace, codepoint: u32, ppu: f64) ?f64 {
    var gi: [2]u16 = .{ 0, 0 };
    const cps = [_]u32{codepoint};
    if (face.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) < 0 or gi[0] == 0) return null;
    var gm: [1]win32.DWRITE_GLYPH_METRICS = undefined;
    const gi_arr: [2]u16 = .{ gi[0], 0 };
    if (face.GetDesignGlyphMetrics(@ptrCast(&gi_arr), 1, &gm, 0) < 0) return null;
    const adv = @as(f64, @floatFromInt(gm[0].advanceWidth)) * ppu;
    return if (adv > 0) adv else null;
}

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
    is_baseline: bool,
};

pub const FaceResolution = struct {
    font: Font,
    is_real_match: bool,
};

const FaceKey = struct {
    family_hash: u64,
    weight: u16,
    italic: bool,
};

allocator: std.mem.Allocator,
hinting: Hinting = .normal,
factory: *win32.IDWriteFactory,
cache: std.AutoHashMapUnmanaged(FaceKey, *win32.IDWriteFontFace) = .empty,
block_and_line_symbols: SymbolRasterizer = .default,
allow_color_glyphs: bool = true,
fallback: ?*FallbackResolver = null,
glyph_scratch: std.ArrayListUnmanaged(u8) = .empty,

pub fn init(allocator: std.mem.Allocator) !Self {
    var factory: *win32.IDWriteFactory = undefined;
    const hr = win32.DWriteCreateFactory(
        win32.DWRITE_FACTORY_TYPE_SHARED,
        win32.IID_IDWriteFactory,
        @ptrCast(&factory),
    );
    if (hr < 0) {
        log.err("DWriteCreateFactory failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DWriteInit;
    }
    return .{ .allocator = allocator, .factory = factory };
}

pub fn deinit(self: *Self) void {
    if (self.fallback) |fb| {
        fb.deinit(self.allocator);
        self.allocator.destroy(fb);
    }
    self.fallback = null;
    var it = self.cache.valueIterator();
    while (it.next()) |face| _ = face.*.IUnknown.Release();
    self.cache.deinit(self.allocator);
    self.glyph_scratch.deinit(self.allocator);
    _ = self.factory.IUnknown.Release();
}

pub fn loadFont(_: *Self, _: []const u8, _: u16) !Font {
    return error.DWriteNotImplemented;
}

pub fn loadFontFromPath(_: *Self, _: []const u8, _: u16) !Font {
    return error.DWriteNotImplemented;
}

const FontResolution = struct {
    face: *win32.IDWriteFontFace,
    style_match: bool, // returned font matches requested weight+style
};

fn utf8ToUtf16Z(buf: []u16, s: []const u8) !usize {
    if (s.len + 1 > buf.len) return error.NameTooLong;
    const n = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s);
    buf[n] = 0;
    return n;
}

fn findFamily(
    collection: *win32.IDWriteFontCollection,
    family_utf8: []const u8,
) !u32 {
    var name_buf: [256]u16 = undefined;
    _ = try utf8ToUtf16Z(&name_buf, family_utf8);

    var index: u32 = 0;
    var exists: win32.BOOL = 0;
    const hr = collection.FindFamilyName(@ptrCast(&name_buf), &index, &exists);
    if (hr < 0 or exists == 0) return error.FontNotFound;
    return index;
}

fn resolveCachedFace(
    self: *Self,
    family_utf8: []const u8,
    css_weight: u16,
    italic: bool,
) !FontResolution {
    const key = FaceKey{
        .family_hash = std.hash.Wyhash.hash(0, family_utf8),
        .weight = css_weight,
        .italic = italic,
    };
    if (self.cache.get(key)) |cached|
        return .{ .face = cached, .style_match = true };

    var collection: *win32.IDWriteFontCollection = undefined;
    if (self.factory.GetSystemFontCollection(&collection, 1) < 0)
        return error.FontNotFound;
    defer _ = collection.IUnknown.Release();

    const idx = try findFamily(collection, family_utf8);

    var family: *win32.IDWriteFontFamily = undefined;
    if (collection.GetFontFamily(idx, &family) < 0) return error.FontNotFound;
    defer _ = family.IUnknown.Release();

    var font: *win32.IDWriteFont = undefined;
    const style: win32.DWRITE_FONT_STYLE = if (italic) .ITALIC else .NORMAL;
    const weight: win32.DWRITE_FONT_WEIGHT = @enumFromInt(@as(i32, css_weight));
    if (family.GetFirstMatchingFont(weight, .NORMAL, style, &font) < 0)
        return error.FontNotFound;
    defer _ = font.IUnknown.Release();

    const got_weight: i32 = @intFromEnum(font.GetWeight());
    const got_style = font.GetStyle();
    const sims = font.GetSimulations();
    const want_w: i32 = @intCast(css_weight);
    const weight_close = @abs(got_weight - want_w) <= 50;
    const style_ok = (italic and got_style != .NORMAL) or (!italic and got_style == .NORMAL);
    const no_sims = (sims.BOLD == 0 and sims.OBLIQUE == 0);
    const style_match = weight_close and style_ok and no_sims;

    var face: *win32.IDWriteFontFace = undefined;
    if (font.CreateFontFace(&face) < 0) return error.FontNotFound;

    try self.cache.put(self.allocator, key, face);
    return .{ .face = face, .style_match = style_match };
}

fn fillFontMetrics(face: *win32.IDWriteFontFace, size_px: u16, out: *Font) !void {
    var m: win32.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&m);
    if (m.designUnitsPerEm == 0) return error.BadFontMetrics;
    const em = @as(f32, @floatFromInt(size_px));
    const scale: f32 = em / @as(f32, @floatFromInt(m.designUnitsPerEm));

    const ascent_f: f32 = @as(f32, @floatFromInt(m.ascent)) * scale;
    const descent_f: f32 = @as(f32, @floatFromInt(m.descent)) * scale; // DWrite descent is positive (below baseline)
    const linegap_f: f32 = @max(0.0, @as(f32, @floatFromInt(m.lineGap)) * scale);

    const face_height_f: f32 = ascent_f + descent_f + linegap_f;
    const face_baseline_f: f32 = linegap_f / 2.0 + descent_f;
    const cell_h_f: f32 = @max(1.0, @round(face_height_f));
    const cell_h: u16 = @intFromFloat(cell_h_f);
    const cell_baseline_f: f32 = @round(face_baseline_f - (cell_h_f - face_height_f) / 2.0);
    const ascent_px: i32 = @intFromFloat(cell_h_f - cell_baseline_f);
    const cap_raw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(m.capHeight)) * scale));
    const cap_height_px: i32 = if (cap_raw > 0) cap_raw else @divTrunc(ascent_px * 7, 10);

    const ul_pos_px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(m.underlinePosition)) * scale));
    const ul_thk_px_raw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(m.underlineThickness)) * scale));
    const ul_thk_px: u16 = @intCast(@max(1, ul_thk_px_raw));
    const box_thk_px: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(m.underlineThickness)) * scale)))));
    const ul_centre_from_top: i32 = ascent_px - ul_pos_px;
    const ul_top_unclamped: i32 = ul_centre_from_top - @divTrunc(@as(i32, ul_thk_px), 2);
    const cell_h_i: i32 = @intCast(cell_h);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_top_unclamped));

    var cell_w: u16 = @max(1, size_px / 2);
    var face_advance_px: f64 = @floatFromInt(cell_w); // unrounded advance
    {
        const cps = [_]u32{'M'};
        var gi: [2]u16 = .{ 0, 0 };
        if (face.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) == 0 and gi[0] != 0) {
            var gm: [1]win32.DWRITE_GLYPH_METRICS = undefined;
            const gi_sentinel: [2]u16 = .{ gi[0], 0 };
            if (face.GetDesignGlyphMetrics(@ptrCast(&gi_sentinel), 1, &gm, 0) == 0) {
                const adv_f: f32 = @as(f32, @floatFromInt(gm[0].advanceWidth)) * scale;
                const adv_i: i32 = @intFromFloat(@round(adv_f));
                if (adv_i > 0) {
                    cell_w = @intCast(adv_i);
                    face_advance_px = adv_f;
                }
            }
        }
    }

    const grid_metrics = glyph_constraint.metricsFromFace(.{
        .cell_width = cell_w,
        .cell_height = cell_h,
        .cell_baseline_from_top = @floatFromInt(ascent_px),
        .face_advance = face_advance_px,
        .face_ascent = @as(f64, ascent_f),
        .face_descent = -@as(f64, descent_f),
        .face_line_gap = @as(f64, linegap_f),
        .cap_height = @floatFromInt(cap_height_px),
    });

    out.* = .{
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .ascent_px = ascent_px,
        .cap_height_px = cap_height_px,
        .underline_position = ul_top,
        .underline_thickness = ul_thk_px,
        .box_thickness = box_thk_px,
        .size_px = size_px,
        .face = face,
        .synth = .{},
        .face_width = grid_metrics.face_width,
        .face_height = grid_metrics.face_height,
        .face_y = grid_metrics.face_y,
        .icon_height = grid_metrics.icon_height,
        .icon_height_single = grid_metrics.icon_height_single,
        .primary_metrics = dwriteFaceMetrics(face, size_px),
    };
}

pub fn resolveFace(self: *Self, req: FaceRequest) !FaceResolution {
    const fallbacks = [_][]const u8{ "Cascadia Mono", "Consolas" };

    const res = self.resolveCachedFace(req.family, req.css_weight, req.italic) catch |first_err| blk: {
        if (!req.is_baseline) return first_err;
        for (fallbacks) |alt| {
            if (std.ascii.eqlIgnoreCase(alt, req.family)) continue;
            if (self.resolveCachedFace(alt, req.css_weight, req.italic)) |r| {
                log.warn("family '{s}' not found, using '{s}'", .{ req.family, alt });
                break :blk r;
            } else |_| {}
        }
        return first_err;
    };

    var font: Font = .{};
    try fillFontMetrics(res.face, req.size_px, &font);

    return .{
        .font = font,
        .is_real_match = if (req.is_baseline) true else res.style_match,
    };
}

const RenderingMode = win32.DWRITE_RENDERING_MODE;

fn pickRenderingMode(hinting: Hinting) RenderingMode {
    return switch (hinting) {
        .none => .NATURAL,
        .slight => .NATURAL_SYMMETRIC,
        .normal => .NATURAL_SYMMETRIC,
        .mono => .ALIASED,
    };
}

pub fn glyphAdvance(_: *const Self, font: Font, codepoint: u21) ?u16 {
    const face = font.face orelse return null;
    var gi: [2]u16 = .{ 0, 0 };
    const cps = [_]u32{@intCast(codepoint)};
    if (face.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) < 0) return null;
    if (gi[0] == 0) return null;
    var m: win32.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&m);
    if (m.designUnitsPerEm == 0) return null;
    const scale: f32 = @as(f32, @floatFromInt(font.size_px)) / @as(f32, @floatFromInt(m.designUnitsPerEm));
    var gm: [1]win32.DWRITE_GLYPH_METRICS = undefined;
    const gi_arr: [2]u16 = .{ gi[0], 0 };
    if (face.GetDesignGlyphMetrics(@ptrCast(&gi_arr), 1, &gm, 0) < 0) return null;
    const adv: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(gm[0].advanceWidth)) * scale));
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
    if (self.block_and_line_symbols == .sprite) {
        const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
        const buf_h: i32 = @intCast(font.cell_size.y);
        const x_offset: i32 = switch (split) {
            .single, .left => 0,
            .right => @intCast(font.cell_size.x),
        };
        const cw: i32 = @intCast(font.cell_size.x);
        const ch: i32 = @intCast(font.cell_size.y);
        if (flow_sprite.renderSprite(self.allocator, codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch, font.box_thickness))
            return .{ .format = .alpha };
    }

    const face = font.face orelse return .{ .format = .alpha };

    const metrics = constraintMetrics(font);

    // Check if primary face has the glyph
    var gi_check: [2]u16 = .{ 0, 0 };
    const cps_check = [_]u32{@intCast(codepoint)};
    const has_glyph = (face.GetGlyphIndices(@ptrCast(&cps_check), 1, @ptrCast(&gi_check)) >= 0 and gi_check[0] != 0);

    const want_color = emoji_presentation and self.allow_color_glyphs;
    if (has_glyph and !want_color) {
        return renderFromFace(self, face, font.size_px, font.ascent_px, font.synth, codepoint, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
    }

    // Try fallback
    if (self.fallback) |fb| {
        if (fb.resolve(self.allocator, codepoint, font.size_px, font.primary_metrics)) |fb_face| {
            return renderFromFace(self, fb_face.face, fb_face.size_px, font.ascent_px, .{}, codepoint, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
        }
    } else {
        const fb = self.allocator.create(FallbackResolver) catch
            return renderFromFace(self, face, font.size_px, font.ascent_px, font.synth, codepoint, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
        fb.* = FallbackResolver.initResolver(self.factory);
        @constCast(&self.fallback).* = fb;
        if (fb.resolve(self.allocator, codepoint, font.size_px, font.primary_metrics)) |fb_face| {
            return renderFromFace(self, fb_face.face, fb_face.size_px, font.ascent_px, .{}, codepoint, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
        }
    }

    // .notdef
    return renderFromFace(self, face, font.size_px, font.ascent_px, font.synth, codepoint, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
}

fn renderFromFace(
    self: *const Self,
    face: *win32.IDWriteFontFace,
    size_px: u16,
    ascent_px: i32,
    synth: SynthFlags,
    codepoint: u21,
    split: GlyphSplit,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
    metrics: glyph_constraint.Metrics,
    cell_size: XY(u16),
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);

    var gi: [2]u16 = .{ 0, 0 };
    const cps = [_]u32{@intCast(codepoint)};
    if (face.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) < 0)
        return .{ .format = .alpha };
    if (gi[0] == 0) return .{ .format = .alpha };

    const indices: [2]u16 = .{ gi[0], 0 };
    const advances = [_]f32{0};
    const offsets = [_]win32.DWRITE_GLYPH_OFFSET{.{ .advanceOffset = 0, .ascenderOffset = 0 }};

    const run = win32.DWRITE_GLYPH_RUN{
        .fontFace = face,
        .fontEmSize = @floatFromInt(size_px),
        .glyphCount = 1,
        .glyphIndices = @ptrCast(&indices),
        .glyphAdvances = @ptrCast(&advances),
        .glyphOffsets = @ptrCast(&offsets),
        .isSideways = 0,
        .bidiLevel = 0,
    };

    // synthetic italic
    const shear_matrix: win32.DWRITE_MATRIX = .{
        .m11 = 1.0,
        .m12 = 0.0,
        .m21 = -0.2126, // tan(12 deg), negative because y axis points down
        .m22 = 1.0,
        .dx = 0,
        .dy = 0,
    };
    const transform_ptr: ?*const win32.DWRITE_MATRIX =
        if (synth.italic) &shear_matrix else null;

    if (self.allow_color_glyphs)
        if (renderColorGlyph(self, &run, transform_ptr, ascent_px, split, cell_size, staging_buf)) |rr|
            return rr;

    const rmode = pickRenderingMode(self.hinting);
    const tex_type: win32.DWRITE_TEXTURE_TYPE = if (rmode == .ALIASED)
        .ALIASED_1x1
    else
        .CLEARTYPE_3x1;
    const result_fmt: RasterFormat = if (tex_type == .ALIASED_1x1) .alpha else .subpixel;
    const bytes_per_texel: i32 = if (tex_type == .ALIASED_1x1) 1 else 3;

    var analysis: *win32.IDWriteGlyphRunAnalysis = undefined;
    if (self.factory.CreateGlyphRunAnalysis(
        &run,
        1.0,
        transform_ptr,
        rmode,
        .NATURAL,
        0.0,
        @floatFromInt(ascent_px),
        &analysis,
    ) < 0) return .{ .format = result_fmt };
    defer _ = analysis.IUnknown.Release();

    var bounds: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (analysis.GetAlphaTextureBounds(tex_type, &bounds) < 0)
        return .{ .format = result_fmt };
    const src_w: i32 = bounds.right - bounds.left;
    const src_h: i32 = bounds.bottom - bounds.top;
    if (src_w <= 0 or src_h <= 0) return .{ .format = result_fmt };

    const buf_size: usize = @intCast(src_w * src_h * bytes_per_texel);
    const scratch: *std.ArrayListUnmanaged(u8) = @constCast(&self.glyph_scratch);
    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(self.allocator, buf_size) catch return .{ .format = result_fmt };
    scratch.items.len = buf_size;
    const tex = scratch.items;

    if (analysis.CreateAlphaTexture(tex_type, &bounds, @ptrCast(tex.ptr), @intCast(buf_size)) < 0)
        return .{ .format = result_fmt };

    const off_x: i32 = bounds.left;
    const off_y: i32 = bounds.top;

    if (constraint.doesAnything()) {
        const rect_w: f64 = @floatFromInt(src_w);
        const rect_h: f64 = @floatFromInt(src_h);
        const cell_h_f: f64 = @floatFromInt(cell_size.y);

        const cg = constraint.constrain(.{
            .width = rect_w,
            .height = rect_h,
            .x = @floatFromInt(bounds.left),
            .y = cell_h_f - @as(f64, @floatFromInt(bounds.bottom)),
        }, metrics, constraint_width);

        const cell_w_f: f64 = @floatFromInt(metrics.cell_width);
        var gx: f64 = cg.x;
        if (constraint.size != .stretch and metrics.face_width < cell_w_f)
            gx += @round((cell_w_f - metrics.face_width) / 2.0);

        rescale: {
            var sm: win32.DWRITE_MATRIX = .{
                .m11 = @floatCast(cg.width / rect_w),
                .m12 = 0,
                .m21 = 0,
                .m22 = @floatCast(cg.height / rect_h),
                .dx = 0,
                .dy = 0,
            };
            var a2: *win32.IDWriteGlyphRunAnalysis = undefined;
            if (self.factory.CreateGlyphRunAnalysis(&run, 1.0, &sm, rmode, .NATURAL, 0.0, @floatFromInt(ascent_px), &a2) < 0) break :rescale;
            defer _ = a2.IUnknown.Release();
            var b2: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (a2.GetAlphaTextureBounds(tex_type, &b2) < 0) break :rescale;
            const w2: i32 = b2.right - b2.left;
            const h2: i32 = b2.bottom - b2.top;
            if (w2 <= 0 or h2 <= 0) break :rescale;
            const sz2: usize = @intCast(w2 * h2 * bytes_per_texel);
            const tex2 = self.allocator.alloc(u8, sz2) catch break :rescale;
            defer self.allocator.free(tex2);
            if (a2.CreateAlphaTexture(tex_type, &b2, @ptrCast(tex2.ptr), @intCast(sz2)) < 0) break :rescale;
            const dst_x0: i32 = @intFromFloat(@round(gx));
            const dst_y0: i32 = @intFromFloat(@round(cell_h_f - (cg.y + cg.height)));
            blitChannelsAt(staging_buf, buf_w, buf_h, tex2, w2, h2, bytes_per_texel, tex_type, dst_x0, dst_y0);
            return .{ .format = result_fmt };
        }
        // fall through to unconstrained blit
    }

    const glyph_extent: i32 = bounds.right;
    const center_offset: i32 = if (split != .single and glyph_extent < buf_w)
        @divTrunc(buf_w - glyph_extent, 2)
    else
        0;

    const base_x: i32 = center_offset + off_x;
    const bpt: usize = @intCast(bytes_per_texel);
    const row_start: i32 = @max(0, -off_y);
    const row_end: i32 = @min(src_h, buf_h - off_y);
    const col_start: i32 = @max(0, -base_x);
    const col_end: i32 = @min(src_w, buf_w - base_x);
    var row: i32 = row_start;
    while (row < row_end) : (row += 1) {
        const dst_row: usize = @intCast((off_y + row) * buf_w);
        const src_row: usize = @as(usize, @intCast(row * src_w)) * bpt;
        var col: i32 = col_start;
        while (col < col_end) : (col += 1) {
            const dst_idx: usize = (dst_row + @as(usize, @intCast(base_x + col))) * 4;
            const src_idx: usize = src_row + @as(usize, @intCast(col)) * bpt;
            if (tex_type == .ALIASED_1x1) {
                staging_buf[dst_idx + 0] = tex[src_idx];
            } else {
                staging_buf[dst_idx + 0] = tex[src_idx + 0];
                staging_buf[dst_idx + 1] = tex[src_idx + 1];
                staging_buf[dst_idx + 2] = tex[src_idx + 2];
            }
        }
    }

    return .{ .format = result_fmt };
}

const ColorLayer = struct {
    mask: []u8, // 1 byte/px grayscale coverage
    left: i32,
    top: i32,
    w: i32,
    h: i32,
    color: win32.DWRITE_COLOR_F,
};

fn renderColorGlyph(
    self: *const Self,
    run: *const win32.DWRITE_GLYPH_RUN,
    transform_ptr: ?*const win32.DWRITE_MATRIX,
    ascent_px: i32,
    split: GlyphSplit,
    cell_size: XY(u16),
    staging_buf: []u8,
) ?RenderResult {
    var factory2: *win32.IDWriteFactory2 = undefined;
    if (self.factory.IUnknown.QueryInterface(win32.IID_IDWriteFactory2, @ptrCast(&factory2)) < 0)
        return null;
    defer _ = factory2.IUnknown.Release();

    var enumerator: *win32.IDWriteColorGlyphRunEnumerator = undefined;
    const hr = factory2.TranslateColorGlyphRun(
        0.0,
        @floatFromInt(ascent_px),
        run,
        null,
        .NATURAL,
        transform_ptr,
        0,
        &enumerator,
    );
    if (hr == win32.DWRITE_E_NOCOLOR) return null;
    if (hr < 0) return null;
    defer _ = enumerator.IUnknown.Release();

    var layers: std.ArrayList(ColorLayer) = .empty;
    defer {
        for (layers.items) |l| self.allocator.free(l.mask);
        layers.deinit(self.allocator);
    }

    var min_left: i32 = std.math.maxInt(i32);
    var min_top: i32 = std.math.maxInt(i32);
    var max_right: i32 = std.math.minInt(i32);
    var max_bottom: i32 = std.math.minInt(i32);

    const rmode = pickRenderingMode(self.hinting);
    const tex_type: win32.DWRITE_TEXTURE_TYPE = if (rmode == .ALIASED)
        .ALIASED_1x1
    else
        .CLEARTYPE_3x1;
    const bytes_per_texel: i32 = if (tex_type == .ALIASED_1x1) 1 else 3;

    while (true) {
        var has_run: win32.BOOL = 0;
        if (enumerator.MoveNext(&has_run) < 0) break;
        if (has_run == 0) break;

        var color_run: ?*win32.DWRITE_COLOR_GLYPH_RUN = null;
        if (enumerator.GetCurrentRun(&color_run) < 0) continue;
        const cr = color_run orelse continue;

        var analysis: *win32.IDWriteGlyphRunAnalysis = undefined;
        if (self.factory.CreateGlyphRunAnalysis(
            &cr.glyphRun,
            1.0,
            transform_ptr,
            rmode,
            .NATURAL,
            0.0,
            @floatFromInt(ascent_px),
            &analysis,
        ) < 0) continue;
        defer _ = analysis.IUnknown.Release();

        var bounds: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (analysis.GetAlphaTextureBounds(tex_type, &bounds) < 0) continue;
        const lw = bounds.right - bounds.left;
        const lh = bounds.bottom - bounds.top;
        if (lw <= 0 or lh <= 0) continue;

        const tex_size: usize = @intCast(lw * lh * bytes_per_texel);
        const tex = self.allocator.alloc(u8, tex_size) catch continue;
        defer self.allocator.free(tex);
        if (analysis.CreateAlphaTexture(tex_type, &bounds, @ptrCast(tex.ptr), @intCast(tex_size)) < 0) {
            continue;
        }

        const px_count: usize = @intCast(lw * lh);
        const mask = self.allocator.alloc(u8, px_count) catch continue;
        if (bytes_per_texel == 1) {
            @memcpy(mask, tex[0..px_count]);
        } else {
            var i: usize = 0;
            while (i < px_count) : (i += 1) {
                const r: u32 = tex[i * 3 + 0];
                const g: u32 = tex[i * 3 + 1];
                const b: u32 = tex[i * 3 + 2];
                mask[i] = @intCast((r + g + b) / 3);
            }
        }

        // paletteIndex 0xFFFF means we should use the context foreground colour
        const color: win32.DWRITE_COLOR_F = if (cr.paletteIndex == 0xFFFF)
            .{ .r = 1, .g = 1, .b = 1, .a = 1 }
        else
            cr.runColor;

        layers.append(self.allocator, .{
            .mask = mask,
            .left = bounds.left,
            .top = bounds.top,
            .w = lw,
            .h = lh,
            .color = color,
        }) catch {
            self.allocator.free(mask);
            continue;
        };

        min_left = @min(min_left, bounds.left);
        min_top = @min(min_top, bounds.top);
        max_right = @max(max_right, bounds.right);
        max_bottom = @max(max_bottom, bounds.bottom);
    }

    if (layers.items.len == 0) return null;

    const native_w = max_right - min_left;
    const native_h = max_bottom - min_top;
    if (native_w <= 0 or native_h <= 0) return null;

    const composed = self.allocator.alloc(u8, @intCast(native_w * native_h * 4)) catch return null;
    defer self.allocator.free(composed);
    @memset(composed, 0);

    for (layers.items) |l| {
        var y: i32 = 0;
        while (y < l.h) : (y += 1) {
            const cy = (l.top - min_top) + y;
            if (cy < 0 or cy >= native_h) continue;
            var x: i32 = 0;
            while (x < l.w) : (x += 1) {
                const cx = (l.left - min_left) + x;
                if (cx < 0 or cx >= native_w) continue;
                const cov: f32 = @as(f32, @floatFromInt(l.mask[@intCast(y * l.w + x)])) / 255.0;
                const sa = cov * l.color.a;
                if (sa <= 0.0) continue;
                const idx: usize = @intCast((cy * native_w + cx) * 4);
                const inv = 1.0 - sa;
                const dr: f32 = @floatFromInt(composed[idx + 0]);
                const dg: f32 = @floatFromInt(composed[idx + 1]);
                const db: f32 = @floatFromInt(composed[idx + 2]);
                const da: f32 = @floatFromInt(composed[idx + 3]);
                composed[idx + 0] = clamp255(sa * l.color.r * 255.0 + dr * inv);
                composed[idx + 1] = clamp255(sa * l.color.g * 255.0 + dg * inv);
                composed[idx + 2] = clamp255(sa * l.color.b * 255.0 + db * inv);
                composed[idx + 3] = clamp255(sa * 255.0 + da * inv);
            }
        }
    }

    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);
    const target_w: i32 = if (split == .single) @as(i32, @intCast(cell_size.x)) else buf_w;
    blitColorRGBA(staging_buf, buf_w, buf_h, composed, native_w, native_h, target_w);
    return .{ .format = .color };
}

fn clamp255(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0.0, 255.0));
}

fn rgbaChannel(src: []const u8, gw: i32, gh: i32, x: i32, y: i32, ch: usize) u8 {
    const cx: i32 = std.math.clamp(x, 0, gw - 1);
    const cy: i32 = std.math.clamp(y, 0, gh - 1);
    return src[@intCast((cy * gw + cx) * 4 + @as(i32, @intCast(ch)))];
}

fn sampleRGBABilinear(src: []const u8, gw: i32, gh: i32, fx: f32, fy: f32) [4]u8 {
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const tx: f32 = fx - @floor(fx);
    const ty: f32 = fy - @floor(fy);
    var out: [4]u8 = undefined;
    inline for (0..4) |ch| {
        const c00: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0, y0, ch));
        const c10: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0 + 1, y0, ch));
        const c01: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0, y0 + 1, ch));
        const c11: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0 + 1, y0 + 1, ch));
        const top = c00 * (1 - tx) + c10 * tx;
        const bot = c01 * (1 - tx) + c11 * tx;
        out[ch] = @intFromFloat(@round(std.math.clamp(top * (1 - ty) + bot * ty, 0, 255)));
    }
    return out;
}

fn blitColorRGBA(
    staging_buf: []u8,
    buf_w: i32,
    buf_h: i32,
    src: []const u8,
    gw: i32,
    gh: i32,
    target_w: i32,
) void {
    if (gw <= 0 or gh <= 0) return;
    const sx: f32 = @as(f32, @floatFromInt(target_w)) / @as(f32, @floatFromInt(gw));
    const sy: f32 = @as(f32, @floatFromInt(buf_h)) / @as(f32, @floatFromInt(gh));
    const s: f32 = @min(sx, sy);
    const sw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(gw)) * s))));
    const sh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(gh)) * s))));
    const dst_x0: i32 = @divTrunc(target_w - sw, 2);
    const dst_y0: i32 = @divTrunc(buf_h - sh, 2);
    const inv_s: f32 = 1.0 / s;

    const dy_start: i32 = @max(0, -dst_y0);
    const dy_end: i32 = @min(sh, buf_h - dst_y0);
    const dx_start: i32 = @max(0, -dst_x0);
    const dx_end: i32 = @min(sw, buf_w - dst_x0);
    var dy: i32 = dy_start;
    while (dy < dy_end) : (dy += 1) {
        const dst_row: usize = @intCast((dst_y0 + dy) * buf_w);
        const fsy = (@as(f32, @floatFromInt(dy)) + 0.5) * inv_s - 0.5;
        var dx: i32 = dx_start;
        while (dx < dx_end) : (dx += 1) {
            const fsx = (@as(f32, @floatFromInt(dx)) + 0.5) * inv_s - 0.5;
            const rgba = sampleRGBABilinear(src, gw, gh, fsx, fsy);
            const dst_idx: usize = (dst_row + @as(usize, @intCast(dst_x0 + dx))) * 4;
            staging_buf[dst_idx + 0] = rgba[0];
            staging_buf[dst_idx + 1] = rgba[1];
            staging_buf[dst_idx + 2] = rgba[2];
            staging_buf[dst_idx + 3] = rgba[3];
        }
    }
}

fn blitChannelsAt(
    staging_buf: []u8,
    buf_w: i32,
    buf_h: i32,
    src: []const u8,
    gw: i32,
    gh: i32,
    channels: i32,
    tex_type: win32.DWRITE_TEXTURE_TYPE,
    dst_x0: i32,
    dst_y0: i32,
) void {
    if (gw <= 0 or gh <= 0) return;
    const ch_n: usize = @intCast(channels);
    const row_start: i32 = @max(0, -dst_y0);
    const row_end: i32 = @min(gh, buf_h - dst_y0);
    const col_start: i32 = @max(0, -dst_x0);
    const col_end: i32 = @min(gw, buf_w - dst_x0);
    var row: i32 = row_start;
    while (row < row_end) : (row += 1) {
        const dst_row: usize = @intCast((dst_y0 + row) * buf_w);
        const src_row: usize = @as(usize, @intCast(row * gw)) * ch_n;
        var col: i32 = col_start;
        while (col < col_end) : (col += 1) {
            const dst_idx: usize = (dst_row + @as(usize, @intCast(dst_x0 + col))) * 4;
            const src_idx: usize = src_row + @as(usize, @intCast(col)) * ch_n;
            if (tex_type == .ALIASED_1x1) {
                staging_buf[dst_idx + 0] = src[src_idx];
            } else {
                staging_buf[dst_idx + 0] = src[src_idx + 0];
                staging_buf[dst_idx + 1] = src[src_idx + 1];
                staging_buf[dst_idx + 2] = src[src_idx + 2];
            }
        }
    }
}

const nerd_font_data = @embedFile("nerd_font");

const HRESULT = win32.HRESULT;
const S_OK: HRESULT = 0;

const FallbackResolver = struct {
    const FallbackFace = struct {
        face: *win32.IDWriteFontFace,
        ascent_px: i32,
        size_px: u16,
    };

    const CacheEntry = struct { found: bool, index: u8 };

    cache: std.AutoHashMapUnmanaged(u21, CacheEntry) = .empty,
    faces: std.ArrayList(FallbackFace) = .empty,
    font_fallback: ?*win32.IDWriteFontFallback = null,
    system_collection: ?*win32.IDWriteFontCollection = null,
    embedded_face: ?*win32.IDWriteFontFace = null,
    embedded_ascent: i32 = 0,
    current_size_px: u16 = 0,

    fn initResolver(factory: *win32.IDWriteFactory) FallbackResolver {
        var result: FallbackResolver = .{};
        var factory2: *win32.IDWriteFactory2 = undefined;
        if (factory.IUnknown.QueryInterface(win32.IID_IDWriteFactory2, @ptrCast(&factory2)) >= 0) {
            var fb: *win32.IDWriteFontFallback = undefined;
            if (factory2.GetSystemFontFallback(&fb) >= 0) {
                result.font_fallback = fb;
            }
            _ = factory2.IUnknown.Release();
        }
        var coll: *win32.IDWriteFontCollection = undefined;
        if (factory.GetSystemFontCollection(&coll, 0) >= 0) {
            result.system_collection = coll;
        }
        result.loadEmbeddedFont(factory);
        return result;
    }

    fn loadEmbeddedFont(self: *FallbackResolver, factory: *win32.IDWriteFactory) void {
        const data = nerd_font_data;

        var loader = EmbeddedFontFileLoader.init(data);
        if (factory.RegisterFontFileLoader(@ptrCast(&loader)) < 0) return;
        defer _ = factory.UnregisterFontFileLoader(@ptrCast(&loader));

        var font_file: *win32.IDWriteFontFile = undefined;
        const key: u32 = 0;
        if (factory.CreateCustomFontFileReference(
            @ptrCast(&key),
            @sizeOf(u32),
            @ptrCast(&loader),
            &font_file,
        ) < 0) return;
        defer _ = font_file.IUnknown.Release();

        var files = [_]*win32.IDWriteFontFile{font_file};
        var face: *win32.IDWriteFontFace = undefined;
        if (factory.CreateFontFace(.TRUETYPE, 1, @ptrCast(@constCast(&files)), 0, .{}, &face) < 0) return;

        var metrics: win32.DWRITE_FONT_METRICS = undefined;
        face.GetMetrics(&metrics);
        self.embedded_face = face;
        if (metrics.designUnitsPerEm != 0) {
            self.embedded_ascent = @intFromFloat(@round(
                @as(f32, @floatFromInt(metrics.ascent)) /
                    @as(f32, @floatFromInt(metrics.designUnitsPerEm)) * 16.0,
            ));
        }
    }

    fn deinit(self: *FallbackResolver, allocator: std.mem.Allocator) void {
        if (self.embedded_face) |ef| _ = ef.IUnknown.Release();
        for (self.faces.items) |f| _ = f.face.IUnknown.Release();
        if (self.font_fallback) |fb| _ = fb.IUnknown.Release();
        if (self.system_collection) |coll| _ = coll.IUnknown.Release();
        self.faces.deinit(allocator);
        self.cache.deinit(allocator);
    }

    fn resolve(
        self: *FallbackResolver,
        allocator: std.mem.Allocator,
        codepoint: u21,
        size_px: u16,
        primary: face_metrics.FaceMetrics,
    ) ?*const FallbackFace {
        if (self.current_size_px != 0 and self.current_size_px != size_px) {
            for (self.faces.items) |f| _ = f.face.IUnknown.Release();
            self.faces.clearRetainingCapacity();
            self.cache.clearRetainingCapacity();
        }
        self.current_size_px = size_px;

        if (self.cache.get(codepoint)) |entry| {
            return if (entry.found) &self.faces.items[entry.index] else null;
        }

        // Try system font fallback first
        const fb = self.font_fallback orelse return self.resolveEmbedded(allocator, codepoint, size_px, primary);

        // Encode codepoint as UTF-16 for MapCharacters
        var text_buf: [2]u16 = undefined;
        const text_len: u32 = if (codepoint >= 0x10000) blk: {
            const hi: u16 = @intCast(((codepoint - 0x10000) >> 10) + 0xD800);
            const lo: u16 = @intCast(((codepoint - 0x10000) & 0x3FF) + 0xDC00);
            text_buf = .{ hi, lo };
            break :blk 2;
        } else blk: {
            text_buf = .{ @intCast(codepoint), 0 };
            break :blk 1;
        };

        // Set up the text analysis source on the stack
        var source = TextAnalysisSource.init(&text_buf, text_len);

        var mapped_length: u32 = 0;
        var mapped_font: *win32.IDWriteFont = undefined;
        var scale: f32 = 1.0;

        const hr = fb.MapCharacters(
            @ptrCast(&source),
            0,
            text_len,
            self.system_collection,
            null,
            .NORMAL,
            .NORMAL,
            .NORMAL,
            &mapped_length,
            @ptrCast(&mapped_font),
            &scale,
        );

        if (hr < 0 or mapped_length == 0)
            return self.resolveEmbedded(allocator, codepoint, size_px, primary);

        // Check if MapCharacters actually returned a font (it can return S_OK with null)
        const font_ptr: ?*win32.IDWriteFont = @ptrCast(mapped_font);
        const mapped = font_ptr orelse
            return self.resolveEmbedded(allocator, codepoint, size_px, primary);
        defer _ = mapped.IUnknown.Release();

        var face: *win32.IDWriteFontFace = undefined;
        if (mapped.CreateFontFace(&face) < 0)
            return self.resolveEmbedded(allocator, codepoint, size_px, primary);

        // Size-adjust the fallback to match the primary face
        const size_scale = face_metrics.faceScaleFactor(primary, dwriteFaceMetrics(face, size_px));
        const adj: u16 = @intFromFloat(@max(1.0, @round(@as(f64, @floatFromInt(size_px)) * size_scale)));

        // Compute ascent for the fallback face at its adjusted size.
        var metrics: win32.DWRITE_FONT_METRICS = undefined;
        face.GetMetrics(&metrics);
        const face_ascent: i32 = if (metrics.designUnitsPerEm != 0) blk: {
            const em: f32 = @floatFromInt(adj);
            const s: f32 = em / @as(f32, @floatFromInt(metrics.designUnitsPerEm));
            break :blk @intFromFloat(@round(@as(f32, @floatFromInt(metrics.ascent)) * s));
        } else @intCast(adj);

        if (self.faces.items.len >= 255) {
            _ = face.IUnknown.Release();
            self.cache.put(allocator, codepoint, .{ .found = false, .index = 0 }) catch {};
            return null;
        }

        const idx: u8 = @intCast(self.faces.items.len);
        self.faces.append(allocator, .{
            .face = face,
            .ascent_px = face_ascent,
            .size_px = adj,
        }) catch {
            _ = face.IUnknown.Release();
            self.cache.put(allocator, codepoint, .{ .found = false, .index = 0 }) catch {};
            return null;
        };

        self.cache.put(allocator, codepoint, .{ .found = true, .index = idx }) catch {};
        return &self.faces.items[idx];
    }

    fn resolveEmbedded(
        self: *FallbackResolver,
        allocator: std.mem.Allocator,
        codepoint: u21,
        size_px: u16,
        primary: face_metrics.FaceMetrics,
    ) ?*const FallbackFace {
        if (self.embedded_face) |ef| {
            var gi: [2]u16 = .{ 0, 0 };
            const cps = [_]u32{@intCast(codepoint)};
            if (ef.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) >= 0 and gi[0] != 0) {
                const scale = face_metrics.faceScaleFactor(primary, dwriteFaceMetrics(ef, size_px));
                const adj: u16 = @intFromFloat(@max(1.0, @round(@as(f64, @floatFromInt(size_px)) * scale)));
                var m: win32.DWRITE_FONT_METRICS = undefined;
                ef.GetMetrics(&m);
                const ascent: i32 = if (m.designUnitsPerEm != 0) blk: {
                    const em: f32 = @floatFromInt(adj);
                    const s: f32 = em / @as(f32, @floatFromInt(m.designUnitsPerEm));
                    break :blk @intFromFloat(@round(@as(f32, @floatFromInt(m.ascent)) * s));
                } else @intCast(adj);

                const idx: u8 = @intCast(self.faces.items.len);
                self.faces.append(allocator, .{ .face = ef, .ascent_px = ascent, .size_px = adj }) catch {};
                self.cache.put(allocator, codepoint, .{ .found = true, .index = idx }) catch {};
                return &self.faces.items[idx];
            }
        }
        self.cache.put(allocator, codepoint, .{ .found = false, .index = 0 }) catch {};
        return null;
    }
};

/// Minimal IDWriteFontFileLoader that serves a single embedded font from memory.
const EmbeddedFontFileLoader = extern struct {
    vtable: *const win32.IDWriteFontFileLoader.VTable,
    data: [*]const u8,
    data_len: u32,

    const loader_vtable: win32.IDWriteFontFileLoader.VTable = .{
        .base = .{
            .QueryInterface = @ptrCast(&loaderQueryInterface),
            .AddRef = @ptrCast(&loaderAddRef),
            .Release = @ptrCast(&loaderRelease),
        },
        .CreateStreamFromKey = @ptrCast(&loaderCreateStream),
    };

    fn init(data: []const u8) EmbeddedFontFileLoader {
        return .{ .vtable = &loader_vtable, .data = data.ptr, .data_len = @intCast(data.len) };
    }

    fn loaderQueryInterface(_: *const EmbeddedFontFileLoader, _: *const win32.Guid, _: *?*anyopaque) callconv(.winapi) HRESULT {
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }
    fn loaderAddRef(_: *const EmbeddedFontFileLoader) callconv(.winapi) u32 {
        return 1;
    }
    fn loaderRelease(_: *const EmbeddedFontFileLoader) callconv(.winapi) u32 {
        return 1;
    }

    fn loaderCreateStream(self: *const EmbeddedFontFileLoader, _: ?*const anyopaque, _: u32, stream_out: **win32.IDWriteFontFileStream) callconv(.winapi) HRESULT {
        stream_out.* = @ptrCast(&embedded_stream_instance);
        _ = self;
        return S_OK;
    }
};

/// Static IDWriteFontFileStream that serves from the compile-time embedded nerd font data.
const EmbeddedFontFileStream = extern struct {
    vtable: *const win32.IDWriteFontFileStream.VTable,

    const stream_vtable: win32.IDWriteFontFileStream.VTable = .{
        .base = .{
            .QueryInterface = @ptrCast(&streamQueryInterface),
            .AddRef = @ptrCast(&streamAddRef),
            .Release = @ptrCast(&streamRelease),
        },
        .ReadFileFragment = @ptrCast(&streamReadFileFragment),
        .ReleaseFileFragment = @ptrCast(&streamReleaseFileFragment),
        .GetFileSize = @ptrCast(&streamGetFileSize),
        .GetLastWriteTime = @ptrCast(&streamGetLastWriteTime),
    };

    fn streamQueryInterface(_: *const EmbeddedFontFileStream, _: *const win32.Guid, _: *?*anyopaque) callconv(.winapi) HRESULT {
        return @bitCast(@as(u32, 0x80004002));
    }
    fn streamAddRef(_: *const EmbeddedFontFileStream) callconv(.winapi) u32 {
        return 1;
    }
    fn streamRelease(_: *const EmbeddedFontFileStream) callconv(.winapi) u32 {
        return 1;
    }

    fn streamReadFileFragment(_: *const EmbeddedFontFileStream, fragment_start: *?*const anyopaque, offset: u64, size: u64, ctx: *?*anyopaque) callconv(.winapi) HRESULT {
        const data = nerd_font_data;
        if (offset + size > data.len) return @bitCast(@as(u32, 0x80070057)); // E_INVALIDARG
        fragment_start.* = @ptrCast(data.ptr + @as(usize, @intCast(offset)));
        ctx.* = null;
        return S_OK;
    }
    fn streamReleaseFileFragment(_: *const EmbeddedFontFileStream, _: ?*anyopaque) callconv(.winapi) void {}
    fn streamGetFileSize(_: *const EmbeddedFontFileStream, size: *u64) callconv(.winapi) HRESULT {
        size.* = nerd_font_data.len;
        return S_OK;
    }
    fn streamGetLastWriteTime(_: *const EmbeddedFontFileStream, time: *u64) callconv(.winapi) HRESULT {
        time.* = 0;
        return S_OK;
    }
};

var embedded_stream_instance: EmbeddedFontFileStream = .{ .vtable = &EmbeddedFontFileStream.stream_vtable };

/// Minimal IDWriteTextAnalysisSource implementation for MapCharacters.
/// Lives on the stack so no COM ref counting needed.
const TextAnalysisSource = extern struct {
    vtable: *const win32.IDWriteTextAnalysisSource.VTable,
    text: *const [2]u16,
    text_len: u32,
    locale: [6]u16 = .{ 'e', 'n', '-', 'U', 'S', 0 },

    const source_vtable: win32.IDWriteTextAnalysisSource.VTable = .{
        .base = .{
            .QueryInterface = @ptrCast(&queryInterface),
            .AddRef = @ptrCast(&addRef),
            .Release = @ptrCast(&release),
        },
        .GetTextAtPosition = @ptrCast(&getTextAtPosition),
        .GetTextBeforePosition = @ptrCast(&getTextBeforePosition),
        .GetParagraphReadingDirection = @ptrCast(&getParagraphReadingDirection),
        .GetLocaleName = @ptrCast(&getLocaleName),
        .GetNumberSubstitution = @ptrCast(&getNumberSubstitution),
    };

    fn init(text: *const [2]u16, text_len: u32) TextAnalysisSource {
        return .{ .vtable = &source_vtable, .text = text, .text_len = text_len };
    }

    fn queryInterface(_: *const TextAnalysisSource, _: *const win32.Guid, _: *?*anyopaque) callconv(.winapi) HRESULT {
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(_: *const TextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *const TextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn getTextAtPosition(self: *const TextAnalysisSource, pos: u32, text_out: *?[*]const u16, len_out: *u32) callconv(.winapi) HRESULT {
        if (pos < self.text_len) {
            text_out.* = @ptrCast(&self.text[pos]);
            len_out.* = self.text_len - pos;
        } else {
            text_out.* = null;
            len_out.* = 0;
        }
        return S_OK;
    }

    fn getTextBeforePosition(self: *const TextAnalysisSource, pos: u32, text_out: *?[*]const u16, len_out: *u32) callconv(.winapi) HRESULT {
        if (pos > 0 and pos <= self.text_len) {
            text_out.* = @ptrCast(&self.text[0]);
            len_out.* = pos;
        } else {
            text_out.* = null;
            len_out.* = 0;
        }
        return S_OK;
    }

    fn getParagraphReadingDirection(_: *const TextAnalysisSource) callconv(.winapi) win32.DWRITE_READING_DIRECTION {
        return .LEFT_TO_RIGHT;
    }

    fn getLocaleName(self: *const TextAnalysisSource, _: u32, len_out: *u32, locale_out: *?[*]const u16) callconv(.winapi) HRESULT {
        locale_out.* = @ptrCast(&self.locale);
        len_out.* = self.text_len;
        return S_OK;
    }

    fn getNumberSubstitution(_: *const TextAnalysisSource, _: u32, _: *u32, _: *?*win32.IDWriteNumberSubstitution) callconv(.winapi) HRESULT {
        return S_OK;
    }
};

pub const font_finder = struct {
    pub const FontFinderError = error{ FontFinderNotSupported, OutOfMemory };

    pub fn findFont(_: std.mem.Allocator, _: []const u8) FontFinderError![]u8 {
        return error.FontFinderNotSupported;
    }

    pub fn listFonts(allocator: std.mem.Allocator) FontFinderError![][]u8 {
        var factory: *win32.IDWriteFactory = undefined;
        if (win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&factory),
        ) < 0) return allocator.alloc([]u8, 0);
        defer _ = factory.IUnknown.Release();

        var collection: *win32.IDWriteFontCollection = undefined;
        if (factory.GetSystemFontCollection(&collection, 0) < 0)
            return allocator.alloc([]u8, 0);
        defer _ = collection.IUnknown.Release();

        const count = collection.GetFontFamilyCount();
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |n| allocator.free(n);
            list.deinit(allocator);
        }
        try list.ensureTotalCapacity(allocator, count);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var family: *win32.IDWriteFontFamily = undefined;
            if (collection.GetFontFamily(i, &family) < 0) continue;
            defer _ = family.IUnknown.Release();

            var names: *win32.IDWriteLocalizedStrings = undefined;
            if (family.GetFamilyNames(&names) < 0) continue;
            defer _ = names.IUnknown.Release();
            if (names.GetCount() == 0) continue;

            var name_len: u32 = 0;
            if (names.GetStringLength(0, &name_len) < 0) continue;
            if (name_len == 0 or name_len > 1024) continue;

            const wbuf = try allocator.alloc(u16, @as(usize, name_len) + 1);
            defer allocator.free(wbuf);
            if (names.GetString(0, @ptrCast(wbuf.ptr), name_len + 1) < 0) continue;

            const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, wbuf[0..name_len]) catch
                continue;
            list.append(allocator, utf8) catch {
                allocator.free(utf8);
                continue;
            };
        }

        return list.toOwnedSlice(allocator);
    }
};
