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
block_and_line_symbols: SymbolRasterizer = .geometric,

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

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    const face = font.face orelse return .{ .format = .alpha };
    const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
    const buf_h: i32 = @intCast(font.cell_size.y);
    const x_offset: i32 = switch (split) {
        .single, .left => 0,
        .right => @intCast(font.cell_size.x),
    };

    // Map codepoint to glyph index
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
        .fontEmSize = @floatFromInt(font.size_px),
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
        if (font.synth.italic) &shear_matrix else null;

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
        @floatFromInt(font.ascent_px),
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

    var row: i32 = 0;
    while (row < src_h) : (row += 1) {
        const dst_y = bounds.top + row;
        if (dst_y < 0 or dst_y >= buf_h) continue;
        var col: i32 = 0;
        while (col < src_w) : (col += 1) {
            const dst_x = x_offset + bounds.left + col;
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
