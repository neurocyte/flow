/// DirectWrite glyph rasterizer
///
const std = @import("std");
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
    size_px: u16 = 16,
    face: ?*win32.IDWriteFontFace = null,
    synth: SynthFlags = .{},
};

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
    const descent_f: f32 = @as(f32, @floatFromInt(m.descent)) * scale;
    const linegap_f: f32 = @as(f32, @floatFromInt(m.lineGap)) * scale;
    const ascent_px: i32 = @intFromFloat(@round(ascent_f));
    const cap_raw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(m.capHeight)) * scale));
    const cap_height_px: i32 = if (cap_raw > 0) cap_raw else @divTrunc(ascent_px * 7, 10);
    const cell_h_f: f32 = ascent_f + descent_f + @max(0.0, linegap_f);
    const cell_h: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@ceil(cell_h_f)))));

    const ul_pos_px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(m.underlinePosition)) * scale));
    const ul_thk_px_raw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(m.underlineThickness)) * scale));
    const ul_thk_px: u16 = @intCast(@max(1, ul_thk_px_raw));
    const ul_centre_from_top: i32 = ascent_px - ul_pos_px;
    const ul_top_unclamped: i32 = ul_centre_from_top - @divTrunc(@as(i32, ul_thk_px), 2);
    const cell_h_i: i32 = @intCast(cell_h);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_top_unclamped));

    var cell_w: u16 = @max(1, size_px / 2);
    {
        const cps = [_]u32{'M'};
        var gi: [2]u16 = .{ 0, 0 };
        if (face.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) == 0 and gi[0] != 0) {
            var gm: [1]win32.DWRITE_GLYPH_METRICS = undefined;
            const gi_sentinel: [2]u16 = .{ gi[0], 0 };
            if (face.GetDesignGlyphMetrics(@ptrCast(&gi_sentinel), 1, &gm, 0) == 0) {
                const adv_f: f32 = @as(f32, @floatFromInt(gm[0].advanceWidth)) * scale;
                const adv_i: i32 = @intFromFloat(@round(adv_f));
                if (adv_i > 0) cell_w = @intCast(adv_i);
            }
        }
    }

    out.* = .{
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .ascent_px = ascent_px,
        .cap_height_px = cap_height_px,
        .underline_position = ul_top,
        .underline_thickness = ul_thk_px,
        .size_px = size_px,
        .face = face,
        .synth = .{},
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
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    const face = font.face orelse return .{ .format = .alpha };

    // Check if primary face has the glyph
    var gi_check: [2]u16 = .{ 0, 0 };
    const cps_check = [_]u32{@intCast(codepoint)};
    const has_glyph = (face.GetGlyphIndices(@ptrCast(&cps_check), 1, @ptrCast(&gi_check)) >= 0 and gi_check[0] != 0);

    if (has_glyph) {
        return renderFromFace(self, face, font.size_px, font.ascent_px, font.ascent_px, font.cap_height_px, font.synth, codepoint, split, font.cell_size, staging_buf);
    }

    // Try fallback
    if (self.fallback) |fb| {
        if (fb.resolve(self.allocator, codepoint, font.size_px)) |fb_face| {
            return renderFromFace(self, fb_face.face, font.size_px, fb_face.ascent_px, font.ascent_px, font.cap_height_px, .{}, codepoint, split, font.cell_size, staging_buf);
        }
    } else {
        const fb = self.allocator.create(FallbackResolver) catch
            return renderFromFace(self, face, font.size_px, font.ascent_px, font.ascent_px, font.cap_height_px, font.synth, codepoint, split, font.cell_size, staging_buf);
        fb.* = FallbackResolver.initResolver(self.factory);
        @constCast(&self.fallback).* = fb;
        if (fb.resolve(self.allocator, codepoint, font.size_px)) |fb_face| {
            return renderFromFace(self, fb_face.face, font.size_px, fb_face.ascent_px, font.ascent_px, font.cap_height_px, .{}, codepoint, split, font.cell_size, staging_buf);
        }
    }

    // .notdef
    return renderFromFace(self, face, font.size_px, font.ascent_px, font.ascent_px, font.cap_height_px, font.synth, codepoint, split, font.cell_size, staging_buf);
}

fn renderFromFace(
    self: *const Self,
    face: *win32.IDWriteFontFace,
    size_px: u16,
    ascent_px: i32,
    cell_ascent_px: i32,
    cap_height_px: i32,
    synth: SynthFlags,
    codepoint: u21,
    split: GlyphSplit,
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
    const tex = self.allocator.alloc(u8, buf_size) catch return .{ .format = result_fmt };
    defer self.allocator.free(tex);

    if (analysis.CreateAlphaTexture(tex_type, &bounds, @ptrCast(tex.ptr), @intCast(buf_size)) < 0)
        return .{ .format = result_fmt };

    const off_x: i32 = bounds.left;
    const off_y: i32 = bounds.top;
    const target_w: i32 = if (split == .single) @as(i32, @intCast(cell_size.x)) else buf_w;

    const overflows = src_w > target_w or src_h > buf_h or off_y < 0 or off_y + src_h > buf_h;
    if (overflows) {
        blitScaledChannels(staging_buf, buf_w, buf_h, tex, src_w, src_h, bytes_per_texel, target_w, cell_ascent_px, cap_height_px);
        return .{ .format = result_fmt };
    }

    const glyph_extent: i32 = bounds.right;
    const center_offset: i32 = if (split != .single and glyph_extent < buf_w)
        @divTrunc(buf_w - glyph_extent, 2)
    else
        0;

    var row: i32 = 0;
    while (row < src_h) : (row += 1) {
        const dst_y = off_y + row;
        if (dst_y < 0 or dst_y >= buf_h) continue;
        var col: i32 = 0;
        while (col < src_w) : (col += 1) {
            const dst_x = center_offset + off_x + col;
            if (dst_x < 0 or dst_x >= buf_w) continue;

            const dst_idx: usize = @as(usize, @intCast(dst_y * buf_w + dst_x)) * 4;
            if (dst_idx + 3 >= staging_buf.len) continue;

            const src_idx: usize = @as(usize, @intCast(row * src_w + col)) * @as(usize, @intCast(bytes_per_texel));
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

fn srcChannel(src: []const u8, gw: i32, gh: i32, channels: i32, ch: i32, x: i32, y: i32) u8 {
    const cx: i32 = std.math.clamp(x, 0, gw - 1);
    const cy: i32 = std.math.clamp(y, 0, gh - 1);
    const idx: usize = @intCast((cy * gw + cx) * channels + ch);
    if (idx >= src.len) return 0;
    return src[idx];
}

fn sampleChannelBilinear(src: []const u8, gw: i32, gh: i32, channels: i32, ch: i32, fx: f32, fy: f32) u8 {
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const tx: f32 = fx - @floor(fx);
    const ty: f32 = fy - @floor(fy);
    const c00: f32 = @floatFromInt(srcChannel(src, gw, gh, channels, ch, x0, y0));
    const c10: f32 = @floatFromInt(srcChannel(src, gw, gh, channels, ch, x0 + 1, y0));
    const c01: f32 = @floatFromInt(srcChannel(src, gw, gh, channels, ch, x0, y0 + 1));
    const c11: f32 = @floatFromInt(srcChannel(src, gw, gh, channels, ch, x0 + 1, y0 + 1));
    const top = c00 * (1 - tx) + c10 * tx;
    const bot = c01 * (1 - tx) + c11 * tx;
    return @intFromFloat(@round(std.math.clamp(top * (1 - ty) + bot * ty, 0, 255)));
}

fn blitScaledChannels(
    staging_buf: []u8,
    buf_w: i32,
    buf_h: i32,
    src: []const u8,
    gw: i32,
    gh: i32,
    channels: i32,
    target_w: i32,
    cell_ascent_px: i32,
    cap_height_px: i32,
) void {
    if (gw <= 0 or gh <= 0) return;
    const baseline: i32 = if (cell_ascent_px > 0 and cell_ascent_px <= buf_h) cell_ascent_px else buf_h;
    const cap: i32 = if (cap_height_px > 0 and cap_height_px <= baseline) cap_height_px else baseline;
    const sx: f32 = @as(f32, @floatFromInt(target_w)) / @as(f32, @floatFromInt(gw));
    const sy: f32 = @as(f32, @floatFromInt(cap)) / @as(f32, @floatFromInt(gh));
    const s: f32 = @min(@min(sx, sy), 1.0);
    const sw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(gw)) * s))));
    const sh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(gh)) * s))));
    const dst_x0: i32 = @divTrunc(target_w - sw, 2);
    const dst_y0: i32 = (baseline - cap) + @divTrunc(cap - sh, 2);
    const inv_s: f32 = 1.0 / s;

    var dy: i32 = 0;
    while (dy < sh) : (dy += 1) {
        const py = dst_y0 + dy;
        if (py < 0 or py >= buf_h) continue;
        const fsy = (@as(f32, @floatFromInt(dy)) + 0.5) * inv_s - 0.5;
        var dx: i32 = 0;
        while (dx < sw) : (dx += 1) {
            const px = dst_x0 + dx;
            if (px < 0 or px >= buf_w) continue;
            const fsx = (@as(f32, @floatFromInt(dx)) + 0.5) * inv_s - 0.5;
            const dst_idx: usize = @as(usize, @intCast(py * buf_w + px)) * 4;
            if (dst_idx + 3 >= staging_buf.len) continue;
            var ch: i32 = 0;
            while (ch < channels) : (ch += 1)
                staging_buf[dst_idx + @as(usize, @intCast(ch))] =
                    sampleChannelBilinear(src, gw, gh, channels, ch, fsx, fsy);
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
        const fb = self.font_fallback orelse return self.resolveEmbedded(allocator, codepoint, size_px);

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
            return self.resolveEmbedded(allocator, codepoint, size_px);

        // Check if MapCharacters actually returned a font (it can return S_OK with null)
        const font_ptr: ?*win32.IDWriteFont = @ptrCast(mapped_font);
        const mapped = font_ptr orelse
            return self.resolveEmbedded(allocator, codepoint, size_px);
        defer _ = mapped.IUnknown.Release();

        var face: *win32.IDWriteFontFace = undefined;
        if (mapped.CreateFontFace(&face) < 0)
            return self.resolveEmbedded(allocator, codepoint, size_px);

        // Compute ascent for the fallback face
        var metrics: win32.DWRITE_FONT_METRICS = undefined;
        face.GetMetrics(&metrics);
        const face_ascent: i32 = if (metrics.designUnitsPerEm != 0) blk: {
            const em: f32 = @floatFromInt(size_px);
            const s: f32 = em / @as(f32, @floatFromInt(metrics.designUnitsPerEm));
            break :blk @intFromFloat(@round(@as(f32, @floatFromInt(metrics.ascent)) * s));
        } else @intCast(size_px);

        if (self.faces.items.len >= 255) {
            _ = face.IUnknown.Release();
            self.cache.put(allocator, codepoint, .{ .found = false, .index = 0 }) catch {};
            return null;
        }

        const idx: u8 = @intCast(self.faces.items.len);
        self.faces.append(allocator, .{
            .face = face,
            .ascent_px = face_ascent,
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
    ) ?*const FallbackFace {
        if (self.embedded_face) |ef| {
            var gi: [2]u16 = .{ 0, 0 };
            const cps = [_]u32{@intCast(codepoint)};
            if (ef.GetGlyphIndices(@ptrCast(&cps), 1, @ptrCast(&gi)) >= 0 and gi[0] != 0) {
                var m: win32.DWRITE_FONT_METRICS = undefined;
                ef.GetMetrics(&m);
                const ascent: i32 = if (m.designUnitsPerEm != 0) blk: {
                    const em: f32 = @floatFromInt(size_px);
                    const s: f32 = em / @as(f32, @floatFromInt(m.designUnitsPerEm));
                    break :blk @intFromFloat(@round(@as(f32, @floatFromInt(m.ascent)) * s));
                } else @intCast(size_px);

                const idx: u8 = @intCast(self.faces.items.len);
                self.faces.append(allocator, .{ .face = ef, .ascent_px = ascent }) catch {};
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
