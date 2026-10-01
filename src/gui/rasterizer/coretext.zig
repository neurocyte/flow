/// CoreText glyph rasterizer
///
const std = @import("std");
const glyph_constraint = @import("glyph_constraint");
const face_metrics = @import("face_metrics");
const flow_sprite = @import("flow_sprite");
const XY = @import("xy").XY;
const blit = @import("blit");
const c = @import("coretext/c.zig");
const uucode_utils = @import("uucode_utils");
const uucode = uucode_utils.uucode;
const build_options = @import("build_options");

const log = std.log.scoped(.coretext_rasterizer);

const Self = @This();

pub const GlyphSplit = enum { single, left, right };
const gui_config = @import("gui_config");
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
    /// CTFontRef, owned by the face cache rather than by the Font.
    face: c.Ref = null,
    synth: SynthFlags = .{},

    face_width: f64 = 0,
    face_height: f64 = 0,
    face_y: f64 = 0,
    icon_height: f64 = 0,
    icon_height_single: f64 = 0,

    primary_metrics: face_metrics.FaceMetrics = .{},
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
    size_px: u16,
};

fn cfString(s: []const u8) ?c.Ref {
    const str = c.CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), c.kCFStringEncodingUTF8, 0);
    return if (str == null) null else str;
}

fn cfStringToUtf8(str: c.Ref, buf: []u8) ?[]const u8 {
    if (str == null) return null;
    if (c.CFStringGetCString(str, buf.ptr, @intCast(buf.len), c.kCFStringEncodingUTF8) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

fn cfNumber(value: f64) c.Ref {
    return c.CFNumberCreate(null, c.kCFNumberDoubleType, &value);
}

fn cfDictionary(keys: []const c.Ref, values: []const c.Ref) c.Ref {
    std.debug.assert(keys.len == values.len);
    return c.CFDictionaryCreate(
        null,
        keys.ptr,
        values.ptr,
        @intCast(keys.len),
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
}

fn ctWeight(css_weight: u16) f64 {
    const anchors = [_]struct { css: u16, ct: f64 }{
        .{ .css = 100, .ct = -0.80 }, // UltraLight
        .{ .css = 200, .ct = -0.60 }, // Thin
        .{ .css = 300, .ct = -0.40 }, // Light
        .{ .css = 400, .ct = 0.00 }, // Regular
        .{ .css = 500, .ct = 0.23 }, // Medium
        .{ .css = 600, .ct = 0.30 }, // Semibold
        .{ .css = 700, .ct = 0.40 }, // Bold
        .{ .css = 800, .ct = 0.56 }, // Heavy
        .{ .css = 900, .ct = 0.62 }, // Black
    };
    if (css_weight <= anchors[0].css) return anchors[0].ct;
    const last = anchors[anchors.len - 1];
    if (css_weight >= last.css) return last.ct;
    for (anchors[1..], 1..) |hi, i| {
        if (css_weight > hi.css) continue;
        const lo = anchors[i - 1];
        const span: f64 = @floatFromInt(hi.css - lo.css);
        const into: f64 = @floatFromInt(css_weight - lo.css);
        return lo.ct + (hi.ct - lo.ct) * (into / span);
    }
    return 0;
}

fn glyphForCodepoint(font: c.Ref, codepoint: u21) ?c.CGGlyph {
    var utf16: [2]c.UniChar = undefined;
    var len: usize = 0;
    if (codepoint < 0x10000) {
        utf16[0] = @intCast(codepoint);
        len = 1;
    } else {
        const v = codepoint - 0x10000;
        utf16[0] = @intCast(0xD800 + (v >> 10));
        utf16[1] = @intCast(0xDC00 + (v & 0x3FF));
        len = 2;
    }
    var glyphs: [2]c.CGGlyph = .{ 0, 0 };
    _ = c.CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, @intCast(len));
    if (glyphs[0] == 0) return null;
    return glyphs[0];
}

fn glyphAdvancePx(font: c.Ref, codepoint: u21) ?f64 {
    const glyph = glyphForCodepoint(font, codepoint) orelse return null;
    const glyphs = [_]c.CGGlyph{glyph};
    const adv = c.CTFontGetAdvancesForGlyphs(font, 0, &glyphs, null, 1);
    return if (adv > 0) adv else null;
}

fn ctFaceMetrics(font: c.Ref) face_metrics.FaceMetrics {
    // The em size a face was created at, which is not the requested size for a
    // fallback face that has been scaled to match the primary.
    const ppem: f64 = @max(1.0, c.CTFontGetSize(font));
    const ascent = c.CTFontGetAscent(font);
    const descent = c.CTFontGetDescent(font); // positive, below baseline
    const leading = @max(0.0, c.CTFontGetLeading(font));
    const cap = c.CTFontGetCapHeight(font);
    const ex = c.CTFontGetXHeight(font);

    return .{
        .px_per_em = ppem,
        .advance = glyphAdvancePx(font, 'M') orelse (ppem * 0.5),
        .ascent = ascent,
        .line_height = ascent + descent + leading,
        .cap_height = if (cap > 0) cap else null,
        .ex_height = if (ex > 0) ex else null,
        .ic_width = glyphAdvancePx(font, '\u{6C34}'),
    };
}

fn fillFontMetrics(font_ref: c.Ref, size_px: u16, out: *Font) !void {
    const ascent_f = c.CTFontGetAscent(font_ref);
    const descent_f = c.CTFontGetDescent(font_ref);
    const linegap_f = @max(0.0, c.CTFontGetLeading(font_ref));

    const face_height_f = ascent_f + descent_f + linegap_f;
    if (!(face_height_f > 0)) return error.BadFontMetrics;
    const face_baseline_f = linegap_f / 2.0 + descent_f;
    const cell_h_f = @max(1.0, @round(face_height_f));
    const cell_h: u16 = @intFromFloat(cell_h_f);
    const cell_baseline_f = @round(face_baseline_f - (cell_h_f - face_height_f) / 2.0);
    const ascent_px: i32 = @intFromFloat(cell_h_f - cell_baseline_f);

    const cap_raw: i32 = @intFromFloat(@round(c.CTFontGetCapHeight(font_ref)));
    const cap_height_px: i32 = if (cap_raw > 0) cap_raw else @divTrunc(ascent_px * 7, 10);

    const ul_pos_px: i32 = @intFromFloat(@round(c.CTFontGetUnderlinePosition(font_ref)));
    const ul_thk_raw = c.CTFontGetUnderlineThickness(font_ref);
    const ul_thk_px: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@round(ul_thk_raw)))));
    const box_thk_px: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@ceil(ul_thk_raw)))));
    const ul_centre_from_top: i32 = ascent_px - ul_pos_px;
    const ul_top_unclamped: i32 = ul_centre_from_top - @divTrunc(@as(i32, ul_thk_px), 2);
    const cell_h_i: i32 = @intCast(cell_h);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_top_unclamped));

    var cell_w: u16 = @max(1, size_px / 2);
    var face_advance_px: f64 = @floatFromInt(cell_w);
    if (glyphAdvancePx(font_ref, 'M')) |adv| {
        const adv_i: i32 = @intFromFloat(@round(adv));
        if (adv_i > 0) {
            cell_w = @intCast(adv_i);
            face_advance_px = adv;
        }
    }

    const grid_metrics = glyph_constraint.metricsFromFace(.{
        .cell_width = cell_w,
        .cell_height = cell_h,
        .cell_baseline_from_top = @floatFromInt(ascent_px),
        .face_advance = face_advance_px,
        .face_ascent = ascent_f,
        .face_descent = -descent_f,
        .face_line_gap = linegap_f,
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
        .face = font_ref,
        .synth = .{},
        .face_width = grid_metrics.face_width,
        .face_height = grid_metrics.face_height,
        .face_y = grid_metrics.face_y,
        .icon_height = grid_metrics.icon_height,
        .icon_height_single = grid_metrics.icon_height_single,
        .primary_metrics = ctFaceMetrics(font_ref),
    };
}

const nerd_font_data = @embedFile("nerd_font");
const noto_emoji_data: []const u8 = if (build_options.embed_emoji) @embedFile("noto_emoji_font") else "";

pub const iosevka_medium = @embedFile("iosevka_medium");
pub const iosevka_extrabold = @embedFile("iosevka_extrabold");
pub const iosevka_medium_italic = @embedFile("iosevka_medium_italic");
pub const iosevka_extrabold_italic = @embedFile("iosevka_extrabold_italic");

pub fn embeddedDefault(bold: bool, italic: bool) []const u8 {
    return if (bold and italic) iosevka_extrabold_italic else if (bold) iosevka_extrabold else if (italic) iosevka_medium_italic else iosevka_medium;
}

fn faceFromData(data: []const u8, size_px: u16) c.Ref {
    if (data.len == 0) return null;
    const cf_data = c.CFDataCreate(null, data.ptr, @intCast(data.len));
    if (cf_data == null) return null;
    defer c.CFRelease(cf_data);
    const descriptor = c.CTFontManagerCreateFontDescriptorFromData(cf_data);
    if (descriptor == null) return null;
    defer c.CFRelease(descriptor);
    return c.CTFontCreateWithFontDescriptor(descriptor, @floatFromInt(size_px), null);
}

allocator: std.mem.Allocator,
hinting: Hinting = .normal,
cache: std.AutoHashMapUnmanaged(FaceKey, c.Ref) = .empty,
block_and_line_symbols: SymbolRasterizer = .default,
allow_color_glyphs: bool = true,
fallback: FallbackCache = .{},
glyph_scratch: std.ArrayListUnmanaged(u8) = .empty,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.cache.valueIterator();
    while (it.next()) |face| if (face.*) |f| c.CFRelease(f);
    self.cache.deinit(self.allocator);
    self.fallback.deinit(self.allocator);
    self.glyph_scratch.deinit(self.allocator);
}

pub fn loadFont(_: *Self, _: []const u8, _: u16) !Font {
    return error.CoreTextNotImplemented;
}

pub fn loadFontFromPath(_: *Self, _: []const u8, _: u16) !Font {
    return error.CoreTextNotImplemented;
}

fn createFace(family: []const u8, css_weight: u16, italic: bool, size_px: u16) ?c.Ref {
    const family_str = cfString(family) orelse return null;
    defer c.CFRelease(family_str);

    const weight_num = cfNumber(ctWeight(css_weight));
    defer if (weight_num) |n| c.CFRelease(n);
    const slant_num = cfNumber(if (italic) 0.3 else 0.0);
    defer if (slant_num) |n| c.CFRelease(n);

    const trait_keys = [_]c.Ref{ c.kCTFontWeightTrait, c.kCTFontSlantTrait };
    const trait_values = [_]c.Ref{ weight_num, slant_num };
    const traits = cfDictionary(&trait_keys, &trait_values);
    defer if (traits) |t| c.CFRelease(t);

    const attr_keys = [_]c.Ref{ c.kCTFontFamilyNameAttribute, c.kCTFontTraitsAttribute };
    const attr_values = [_]c.Ref{ family_str, traits };
    const attributes = cfDictionary(&attr_keys, &attr_values);
    defer if (attributes) |a| c.CFRelease(a);

    const descriptor = c.CTFontDescriptorCreateWithAttributes(attributes);
    if (descriptor == null) return null;
    defer c.CFRelease(descriptor);

    return c.CTFontCreateWithFontDescriptor(descriptor, @floatFromInt(size_px), null);
}

fn familyMatches(font: c.Ref, family: []const u8) bool {
    const name = c.CTFontCopyFamilyName(font) orelse return false;
    defer c.CFRelease(name);
    var buf: [256]u8 = undefined;
    const got = cfStringToUtf8(name, &buf) orelse return false;
    return std.ascii.eqlIgnoreCase(got, family);
}

fn resolveBuiltin(self: *Self, req: FaceRequest) !FaceResolution {
    const key = FaceKey{
        .family_hash = std.hash.Wyhash.hash(0, gui_config.builtin_fontface),
        .weight = req.css_weight,
        .italic = req.italic,
        .size_px = req.size_px,
    };
    const face = self.cache.get(key) orelse blk: {
        const bold = req.css_weight >= 600;
        const f = faceFromData(embeddedDefault(bold, req.italic), req.size_px) orelse
            return error.FontNotFound;
        self.cache.put(self.allocator, key, f) catch {
            c.CFRelease(f);
            return error.FontNotFound;
        };
        break :blk f;
    };

    var font: Font = .{};
    try fillFontMetrics(face, req.size_px, &font);
    return .{ .font = font, .is_real_match = true };
}

const CachedFace = struct { face: c.Ref, style_match: bool };

fn resolveCachedFace(self: *Self, family: []const u8, css_weight: u16, italic: bool, size_px: u16) !CachedFace {
    const key = FaceKey{
        .family_hash = std.hash.Wyhash.hash(0, family),
        .weight = css_weight,
        .italic = italic,
        .size_px = size_px,
    };
    const face = self.cache.get(key) orelse blk: {
        const f = createFace(family, css_weight, italic, size_px) orelse return error.FontNotFound;
        // CoreText substitutes silently
        if (!familyMatches(f, family)) {
            c.CFRelease(f);
            return error.FontNotFound;
        }
        self.cache.put(self.allocator, key, f) catch {
            c.CFRelease(f);
            return error.FontNotFound;
        };
        break :blk f;
    };

    const traits = c.CTFontGetSymbolicTraits(face);
    const style_match = (!italic or (traits & c.kCTFontTraitItalic) != 0) and
        (css_weight < 600 or (traits & c.kCTFontTraitBold) != 0);
    return .{ .face = face, .style_match = style_match };
}

pub fn resolveFace(self: *Self, req: FaceRequest) !FaceResolution {
    // The built-in face bypasses font lookup entirely.
    if (std.mem.eql(u8, req.family, gui_config.builtin_fontface))
        return self.resolveBuiltin(req);

    const fallbacks = [_][]const u8{ "SF Mono", "Menlo", "Monaco" };

    const res = self.resolveCachedFace(req.family, req.css_weight, req.italic, req.size_px) catch |first_err| blk: {
        if (!req.is_baseline) return first_err;
        for (fallbacks) |alt| {
            if (std.ascii.eqlIgnoreCase(alt, req.family)) continue;
            if (self.resolveCachedFace(alt, req.css_weight, req.italic, req.size_px)) |r| {
                log.warn("family '{s}' not found, using '{s}'", .{ req.family, alt });
                break :blk r;
            } else |_| {}
        }
        // Nothing usable on this system.
        return self.resolveBuiltin(req) catch first_err;
    };

    var font: Font = .{};
    try fillFontMetrics(res.face, req.size_px, &font);

    return .{
        .font = font,
        .is_real_match = if (req.is_baseline) true else res.style_match,
    };
}

pub fn glyphAdvance(_: *const Self, font: Font, codepoint: u21) ?u16 {
    const face = font.face orelse return null;
    const adv = glyphAdvancePx(face, codepoint) orelse return null;
    const rounded: i32 = @intFromFloat(@round(adv));
    return if (rounded > 0) @intCast(rounded) else null;
}

const FallbackCache = struct {
    const max_faces = 255;
    const Key = struct { cp: u21, color: bool };
    const CacheEntry = struct { found: bool, index: u8 };
    const Entry = struct {
        font: c.Ref,
        id_hash: u64,
        embedded: bool,
        scale: f64 = 1.0,
    };

    cache: std.AutoHashMapUnmanaged(Key, CacheEntry) = .empty,
    faces: std.ArrayList(Entry) = .empty,
    embedded_loaded: bool = false,
    current_size_px: u16 = 0,

    fn deinit(self: *FallbackCache, allocator: std.mem.Allocator) void {
        for (self.faces.items) |*e| if (e.font) |f| c.CFRelease(f);
        self.faces.deinit(allocator);
        self.cache.deinit(allocator);
    }

    fn scaledSize(size_px: u16, scale: f64) u16 {
        return @intFromFloat(@max(1.0, @round(@as(f64, @floatFromInt(size_px)) * scale)));
    }

    fn resize(entry: *Entry, size_px: u16) void {
        const copy = c.CTFontCreateCopyWithAttributes(
            entry.font,
            @floatFromInt(scaledSize(size_px, entry.scale)),
            null,
            null,
        ) orelse return;
        c.CFRelease(entry.font);
        entry.font = copy;
    }

    const embedded_fonts = [_]struct { data: []const u8, tag: []const u8 }{
        .{ .data = nerd_font_data, .tag = "<embedded:nerd_font>" },
        .{ .data = noto_emoji_data, .tag = "<embedded:noto_color_emoji>" },
        .{ .data = iosevka_medium, .tag = "<embedded:iosevka>" },
    };

    fn loadEmbedded(self: *FallbackCache, allocator: std.mem.Allocator, size_px: u16) void {
        if (self.embedded_loaded) return;
        self.embedded_loaded = true;
        inline for (embedded_fonts) |ef| {
            if (ef.data.len != 0) {
                if (faceFromData(ef.data, size_px)) |font| {
                    self.faces.append(allocator, .{
                        .font = font,
                        .id_hash = std.hash.Wyhash.hash(0, ef.tag),
                        .embedded = true,
                    }) catch c.CFRelease(font);
                }
            }
        }
    }

    fn cacheNegative(self: *FallbackCache, allocator: std.mem.Allocator, key: Key) ?c.Ref {
        self.cache.put(allocator, key, .{ .found = false, .index = 0 }) catch {};
        return null;
    }

    fn hit(self: *FallbackCache, allocator: std.mem.Allocator, key: Key, idx: usize) ?c.Ref {
        self.cache.put(allocator, key, .{ .found = true, .index = @intCast(idx) }) catch {};
        return self.faces.items[idx].font;
    }

    fn resolve(
        self: *FallbackCache,
        allocator: std.mem.Allocator,
        base: c.Ref,
        codepoint: u21,
        size_px: u16,
        prefer_color: bool,
        primary: face_metrics.FaceMetrics,
    ) ?c.Ref {
        if (self.current_size_px != 0 and self.current_size_px != size_px)
            for (self.faces.items) |*e| resize(e, size_px);
        self.current_size_px = size_px;
        self.loadEmbedded(allocator, size_px);

        const key: Key = .{ .cp = codepoint, .color = prefer_color };
        if (self.cache.get(key)) |entry|
            return if (entry.found) self.faces.items[entry.index].font else null;

        for (self.faces.items, 0..) |*e, idx| {
            if (!e.embedded) continue;
            if (glyphForCodepoint(e.font, codepoint) == null) continue;
            return self.hit(allocator, key, idx);
        }

        var utf8: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8) catch
            return self.cacheNegative(allocator, key);
        const str = cfString(utf8[0..utf8_len]) orelse return self.cacheNegative(allocator, key);
        defer c.CFRelease(str);
        const range: c.CFRange = .{ .location = 0, .length = c.CFStringGetLength(str) };

        const found = c.CTFontCreateForString(base, str, range) orelse
            return self.cacheNegative(allocator, key);
        // CoreText returns the base font itself when nothing better covers the string
        if (glyphForCodepoint(found, codepoint) == null) {
            c.CFRelease(found);
            return self.cacheNegative(allocator, key);
        }

        var name_buf: [256]u8 = undefined;
        const id_hash = blk: {
            const name = c.CTFontCopyFamilyName(found) orelse break :blk @as(u64, codepoint);
            defer c.CFRelease(name);
            const utf = cfStringToUtf8(name, &name_buf) orelse break :blk @as(u64, codepoint);
            break :blk std.hash.Wyhash.hash(0, utf);
        };
        for (self.faces.items, 0..) |*e, idx| {
            if (e.id_hash != id_hash) continue;
            c.CFRelease(found);
            return self.hit(allocator, key, idx);
        }

        if (self.faces.items.len >= max_faces) {
            c.CFRelease(found);
            return self.cacheNegative(allocator, key);
        }

        // Fallback faces are scaled so their x-height lines up with the primary face
        const scale = face_metrics.faceScaleFactor(primary, ctFaceMetrics(found));
        var entry: Entry = .{ .font = found, .id_hash = id_hash, .embedded = false, .scale = scale };
        if (scaledSize(size_px, scale) != size_px) resize(&entry, size_px);

        const idx = self.faces.items.len;
        self.faces.append(allocator, entry) catch {
            c.CFRelease(entry.font);
            return self.cacheNegative(allocator, key);
        };
        return self.hit(allocator, key, idx);
    }
};

fn isColorFace(font: c.Ref) bool {
    return (c.CTFontGetSymbolicTraits(font) & c.kCTFontTraitColorGlyphs) != 0;
}

/// tan(12 deg), the synthetic-italic shear
const synth_shear = 0.2126;

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

    if (self.block_and_line_symbols == .sprite) {
        const x_offset: i32 = switch (split) {
            .single, .left => 0,
            .right => @intCast(font.cell_size.x),
        };
        if (flow_sprite.renderSprite(
            self.allocator,
            codepoint,
            staging_buf,
            buf_w,
            buf_h,
            x_offset,
            @intCast(font.cell_size.x),
            @intCast(font.cell_size.y),
            font.box_thickness,
        )) return .{ .format = .alpha };
    }

    const face = font.face orelse return .{ .format = .alpha };
    const metrics = constraintMetrics(font);

    // For emoji presentation prefer a color fallback over a monochrome primary
    const want_color = emoji_presentation and self.allow_color_glyphs;
    if (glyphForCodepoint(face, codepoint) != null and (!want_color or isColorFace(face)))
        return renderFromFace(self, face, font.ascent_px, font.synth, codepoint, constraint, constraint_width, split, font.cell_size, metrics, staging_buf);

    const fallback: *FallbackCache = @constCast(&self.fallback);
    const prefer_color = want_color or uucode.get(.is_emoji_presentation, @intCast(codepoint));
    if (fallback.resolve(self.allocator, face, codepoint, font.size_px, prefer_color, font.primary_metrics)) |fb_face|
        return renderFromFace(self, fb_face, font.ascent_px, .{}, codepoint, constraint, constraint_width, split, font.cell_size, metrics, staging_buf);

    // Nothing on this system covers the codepoint
    // the primary face's notdef box is glyph 0
    return renderGlyph(self, face, 0, font.ascent_px, font.synth, constraint, constraint_width, split, font.cell_size, metrics, staging_buf);
}

fn renderFromFace(
    self: *const Self,
    face: c.Ref,
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
    const glyph = glyphForCodepoint(face, codepoint) orelse return .{ .format = .alpha };
    return renderGlyph(self, face, glyph, cell_ascent_px, synth, constraint, constraint_width, split, cell_size, metrics, staging_buf);
}

fn renderGlyph(
    self: *const Self,
    face: c.Ref,
    glyph: c.CGGlyph,
    cell_ascent_px: i32,
    synth: SynthFlags,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
    split: GlyphSplit,
    cell_size: XY(u16),
    metrics: glyph_constraint.Metrics,
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);
    const buf_w_f: f64 = @floatFromInt(buf_w);
    const buf_h_f: f64 = @floatFromInt(buf_h);

    const glyphs = [_]c.CGGlyph{glyph};

    var rects: [1]c.CGRect = undefined;
    _ = c.CTFontGetBoundingRectsForGlyphs(face, 0, &glyphs, &rects, 1);
    var rect = rects[0];
    if (!(rect.size.width > 0) or !(rect.size.height > 0)) return .{ .format = .alpha };

    const has_color_face = self.allow_color_glyphs and isColorFace(face);
    if (has_color_face) {
        const target_w: f64 = if (split == .single) @floatFromInt(cell_size.x) else buf_w_f;
        return self.drawGlyph(face, glyph, colorTransform(rect, target_w, buf_h_f), .color, cell_size, staging_buf);
    }

    const shear: f64 = if (synth.italic) synth_shear else 0.0;
    if (shear != 0.0) {
        const y0 = rect.origin.y;
        const y1 = y0 + rect.size.height;
        const x0 = rect.origin.x + shear * y0;
        const x1 = rect.origin.x + rect.size.width + shear * y1;
        rect.origin.x = x0;
        rect.size.width = x1 - x0;
    }

    const transform: c.CGAffineTransform = if (constraint.doesAnything())
        constrainedTransform(rect, shear, constraint, constraint_width, metrics, buf_h_f, cell_ascent_px)
    else
        naturalTransform(rect, shear, split, buf_w_f, buf_h_f, cell_ascent_px);

    return self.drawGlyph(face, glyph, transform, .alpha, cell_size, staging_buf);
}

/// place the glyph on its baseline at its natural size
fn naturalTransform(
    rect: c.CGRect,
    shear: f64,
    split: GlyphSplit,
    buf_w_f: f64,
    buf_h_f: f64,
    cell_ascent_px: i32,
) c.CGAffineTransform {
    const extent = @ceil(rect.origin.x + rect.size.width);
    const center_offset: f64 = if (split != .single and extent < buf_w_f)
        @divTrunc(buf_w_f - extent, 2)
    else
        0;
    return .{
        .a = 1,
        .b = 0,
        .c = shear,
        .d = 1,
        .tx = center_offset,
        .ty = buf_h_f - @as(f64, @floatFromInt(cell_ascent_px)),
    };
}

/// fit the glyph to the box the constraint asks for
fn constrainedTransform(
    rect: c.CGRect,
    shear: f64,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
    metrics: glyph_constraint.Metrics,
    buf_h_f: f64,
    cell_ascent_px: i32,
) c.CGAffineTransform {
    const baseline_from_bottom: f64 = buf_h_f - @as(f64, @floatFromInt(cell_ascent_px));
    const cg = constraint.constrain(.{
        .width = rect.size.width,
        .height = rect.size.height,
        .x = rect.origin.x,
        .y = rect.origin.y + baseline_from_bottom,
    }, metrics, constraint_width);

    const cell_w_f: f64 = @floatFromInt(metrics.cell_width);
    var gx: f64 = cg.x;
    if (constraint.size != .stretch and metrics.face_width < cell_w_f)
        gx += @round((cell_w_f - metrics.face_width) / 2.0);

    const sx = cg.width / rect.size.width;
    const sy = cg.height / rect.size.height;
    return .{
        .a = sx,
        .b = 0,
        .c = shear * sx,
        .d = sy,
        .tx = gx - rect.origin.x * sx,
        .ty = cg.y - rect.origin.y * sy,
    };
}

/// Scale-to-fit and center
fn colorTransform(rect: c.CGRect, target_w: f64, buf_h_f: f64) c.CGAffineTransform {
    const s = @min(target_w / rect.size.width, buf_h_f / rect.size.height);
    const sw = @round(rect.size.width * s);
    const sh = @round(rect.size.height * s);
    const dst_x0 = @divTrunc(target_w - sw, 2);
    const dst_y0 = @divTrunc(buf_h_f - sh, 2);
    return .{
        .a = s,
        .b = 0,
        .c = 0,
        .d = s,
        .tx = dst_x0 - rect.origin.x * s,
        .ty = (buf_h_f - dst_y0 - sh) - rect.origin.y * s,
    };
}

/// Rasterize into a CoreGraphics bitmap context laid over the staging buffer
/// (color) or over a scratch coverage plane that is then blitted into the red
/// channel (alpha)
fn drawGlyph(
    self: *const Self,
    face: c.Ref,
    glyph: c.CGGlyph,
    transform: c.CGAffineTransform,
    format: RasterFormat,
    cell_size: XY(u16),
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);
    const px: usize = @intCast(buf_w * buf_h);

    var scratch: []u8 = &.{};
    const ctx = switch (format) {
        .color => blk: {
            const space = c.CGColorSpaceCreateDeviceRGB() orelse return .{ .format = .alpha };
            defer c.CGColorSpaceRelease(space);
            break :blk c.CGBitmapContextCreate(
                staging_buf.ptr,
                @intCast(buf_w),
                @intCast(buf_h),
                8,
                @intCast(buf_w * 4),
                space,
                c.kCGImageAlphaPremultipliedLast,
            );
        },
        .alpha, .subpixel => blk: {
            const list: *std.ArrayListUnmanaged(u8) = @constCast(&self.glyph_scratch);
            list.clearRetainingCapacity();
            list.ensureTotalCapacity(self.allocator, px) catch return .{ .format = .alpha };
            list.items.len = px;
            scratch = list.items;
            // Black ground, white glyph: in an opaque gray context the
            // resulting gray level is the coverage.
            @memset(scratch, 0);
            const space = c.CGColorSpaceCreateDeviceGray() orelse return .{ .format = .alpha };
            defer c.CGColorSpaceRelease(space);
            break :blk c.CGBitmapContextCreate(
                scratch.ptr,
                @intCast(buf_w),
                @intCast(buf_h),
                8,
                @intCast(buf_w),
                space,
                c.kCGImageAlphaNone,
            );
        },
    } orelse return .{ .format = .alpha };
    defer c.CGContextRelease(ctx);

    c.CGContextSetShouldAntialias(ctx, if (self.hinting == .mono) 0 else 1);
    // grayscale coverage only
    c.CGContextSetShouldSmoothFonts(ctx, 0);
    c.CGContextSetAllowsFontSubpixelQuantization(ctx, 1);
    c.CGContextSetShouldSubpixelQuantizeFonts(ctx, 1);
    c.CGContextSetAllowsFontSubpixelPositioning(ctx, 1);
    c.CGContextSetShouldSubpixelPositionFonts(ctx, 1);
    c.CGContextSetGrayFillColor(ctx, 1, 1);
    c.CGContextSetTextDrawingMode(ctx, c.kCGTextFill);
    c.CGContextSetTextMatrix(ctx, .{});
    c.CGContextConcatCTM(ctx, transform);

    const glyphs = [_]c.CGGlyph{glyph};
    const positions = [_]c.CGPoint{.{}};
    c.CTFontDrawGlyphs(face, &glyphs, &positions, 1, ctx);

    if (format == .color) return .{ .format = .color };

    blit.alpha8(staging_buf, buf_w, buf_h, scratch, buf_w, buf_h, 0, 0);
    return .{ .format = .alpha };
}

pub const font_finder = struct {
    pub const FontFinderError = error{ FontFinderNotSupported, OutOfMemory };

    pub fn findFont(_: std.mem.Allocator, _: []const u8) FontFinderError![]u8 {
        return error.FontFinderNotSupported;
    }

    fn isMonospace(descriptor: c.Ref) bool {
        const traits = c.CTFontDescriptorCopyAttribute(descriptor, c.kCTFontTraitsAttribute) orelse
            return false;
        defer c.CFRelease(traits);
        const symbolic = c.CFDictionaryGetValue(traits, c.kCTFontSymbolicTrait) orelse return false;
        var value: i32 = 0;
        if (c.CFNumberGetValue(symbolic, c.kCFNumberSInt32Type, &value) == 0) return false;
        return (@as(u32, @bitCast(value)) & c.kCTFontTraitMonoSpace) != 0;
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn listFonts(allocator: std.mem.Allocator) FontFinderError![][]u8 {
        const collection = c.CTFontCollectionCreateFromAvailableFonts(null) orelse
            return allocator.alloc([]u8, 0);
        defer c.CFRelease(collection);
        const descriptors = c.CTFontCollectionCreateMatchingFontDescriptors(collection) orelse
            return allocator.alloc([]u8, 0);
        defer c.CFRelease(descriptors);

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |n| allocator.free(n);
            list.deinit(allocator);
        }

        const count = c.CFArrayGetCount(descriptors);
        var i: c.CFIndex = 0;
        while (i < count) : (i += 1) {
            const descriptor = c.CFArrayGetValueAtIndex(descriptors, i) orelse continue;
            if (!isMonospace(descriptor)) continue;

            const name = c.CTFontDescriptorCopyAttribute(descriptor, c.kCTFontFamilyNameAttribute) orelse
                continue;
            defer c.CFRelease(name);
            var buf: [256]u8 = undefined;
            const utf8 = cfStringToUtf8(name, &buf) orelse continue;
            // Families whose name starts with a dot are system-internal.
            if (utf8.len == 0 or utf8[0] == '.') continue;

            const owned = try allocator.dupe(u8, utf8);
            list.append(allocator, owned) catch {
                allocator.free(owned);
                continue;
            };
        }

        // The collection lists faces, so a family shows up once per style.
        std.mem.sort([]u8, list.items, {}, lessThan);
        var out: usize = 0;
        for (list.items) |name| {
            if (out > 0 and std.mem.eql(u8, list.items[out - 1], name)) {
                allocator.free(name);
                continue;
            }
            list.items[out] = name;
            out += 1;
        }
        list.items.len = out;

        return list.toOwnedSlice(allocator);
    }
};
