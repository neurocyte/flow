const std = @import("std");
const fc = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

/// Returns a sorted, deduplicated list of monospace font family names.
/// Caller owns the returned slice and each string within it.
pub fn list(allocator: std.mem.Allocator) ![][]u8 {
    const config = fc.FcInitLoadConfigAndFonts() orelse return error.FontconfigInit;
    defer fc.FcConfigDestroy(config);

    const pat = fc.FcPatternCreate() orelse return error.OutOfMemory;
    defer fc.FcPatternDestroy(pat);
    _ = fc.FcPatternAddInteger(pat, fc.FC_SPACING, fc.FC_MONO);
    // Only list scalable text faces.
    _ = fc.FcPatternAddBool(pat, fc.FC_OUTLINE, fc.FcTrue);
    _ = fc.FcPatternAddBool(pat, fc.FC_COLOR, fc.FcFalse);

    const os = fc.FcObjectSetCreate() orelse return error.OutOfMemory;
    defer fc.FcObjectSetDestroy(os);
    _ = fc.FcObjectSetAdd(os, fc.FC_FAMILY);

    const font_set = fc.FcFontList(config, pat, os) orelse return error.OutOfMemory;
    defer fc.FcFontSetDestroy(font_set);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    for (0..@intCast(font_set.*.nfont)) |i| {
        var family: [*c]fc.FcChar8 = undefined;
        if (fc.FcPatternGetString(font_set.*.fonts[i], fc.FC_FAMILY, 0, &family) != fc.FcResultMatch)
            continue;
        try names.append(allocator, try allocator.dupe(u8, std.mem.sliceTo(family, 0)));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);

    // Remove adjacent duplicates that survived the sort.
    var w: usize = 0;
    for (names.items) |name| {
        if (w == 0 or !std.ascii.eqlIgnoreCase(names.items[w - 1], name)) {
            names.items[w] = name;
            w += 1;
        } else {
            allocator.free(name);
        }
    }
    names.shrinkRetainingCapacity(w);

    return try names.toOwnedSlice(allocator);
}

/// A resolved font file plus the subfont index.
pub const FontMatch = struct {
    path: []u8,
    face_index: i32,
};

pub fn find(allocator: std.mem.Allocator, name: []const u8) !FontMatch {
    const config = fc.FcInitLoadConfigAndFonts() orelse return error.FontconfigInit;
    defer fc.FcConfigDestroy(config);

    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const pat = fc.FcNameParse(name_z.ptr) orelse return error.FontPatternParse;
    defer fc.FcPatternDestroy(pat);

    _ = fc.FcConfigSubstitute(config, pat, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pat);

    var result: fc.FcResult = undefined;
    const font = fc.FcFontMatch(config, pat, &result) orelse return error.FontNotFound;
    defer fc.FcPatternDestroy(font);

    var file: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(font, fc.FC_FILE, 0, &file) != fc.FcResultMatch)
        return error.FontPathNotFound;

    var index: c_int = 0;
    _ = fc.FcPatternGetInteger(font, fc.FC_INDEX, 0, &index);

    return .{
        .path = try allocator.dupe(u8, std.mem.sliceTo(file, 0)),
        .face_index = index,
    };
}

/// Map CSS-style weight (100..900) to fontconfig's weight scale
fn cssToFcWeight(css: u16) u16 {
    const c = std.math.clamp(css, 100, 900);
    return switch ((c + 50) / 100) {
        0, 1 => 0, // Thin
        2 => 40, // ExtraLight
        3 => 50, // Light
        4 => 80, // Regular
        5 => 100, // Medium
        6 => 180, // SemiBold
        7 => 200, // Bold
        8 => 205, // ExtraBold
        else => 210, // Black
    };
}

pub const FallbackCandidate = struct {
    path: []u8,
    face_index: i32,
    has_color: bool,
};

/// Query for fonts that provide a specific codepoint
pub fn findFallbackFonts(
    allocator: std.mem.Allocator,
    codepoint: u21,
    prefer_color: bool,
) ![]FallbackCandidate {
    const config = fc.FcInitLoadConfigAndFonts() orelse return error.FontconfigInit;
    defer fc.FcConfigDestroy(config);

    const pat = fc.FcPatternCreate() orelse return error.OutOfMemory;
    defer fc.FcPatternDestroy(pat);

    const cs = fc.FcCharSetCreate() orelse return error.OutOfMemory;
    defer fc.FcCharSetDestroy(cs);
    _ = fc.FcCharSetAddChar(cs, codepoint);
    _ = fc.FcPatternAddCharSet(pat, fc.FC_CHARSET, cs);

    if (prefer_color) {
        _ = fc.FcPatternAddBool(pat, fc.FC_COLOR, 1);
        _ = fc.FcPatternAddString(pat, fc.FC_FAMILY, "emoji");
    } else {
        _ = fc.FcPatternAddString(pat, fc.FC_FAMILY, "monospace");
    }

    _ = fc.FcConfigSubstitute(config, pat, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pat);

    var result: fc.FcResult = undefined;
    const font_set = fc.FcFontSort(config, pat, 0, null, &result);
    if (font_set == null) return allocator.alloc(FallbackCandidate, 0);
    defer fc.FcFontSetDestroy(font_set);

    const max_candidates = 10;
    var candidates: std.ArrayList(FallbackCandidate) = .empty;
    errdefer {
        for (candidates.items) |c_| allocator.free(c_.path);
        candidates.deinit(allocator);
    }

    const nfont: usize = @intCast(font_set.*.nfont);
    for (0..@min(nfont, max_candidates)) |i| {
        const font_pat = font_set.*.fonts[i];

        var file: [*c]fc.FcChar8 = undefined;
        if (fc.FcPatternGetString(font_pat, fc.FC_FILE, 0, &file) != fc.FcResultMatch)
            continue;

        var index: c_int = 0;
        _ = fc.FcPatternGetInteger(font_pat, fc.FC_INDEX, 0, &index);

        var color_val: c_int = 0;
        _ = fc.FcPatternGetBool(font_pat, fc.FC_COLOR, 0, &color_val);

        try candidates.append(allocator, .{
            .path = try allocator.dupe(u8, std.mem.sliceTo(file, 0)),
            .face_index = index,
            .has_color = color_val != 0,
        });
    }

    return try candidates.toOwnedSlice(allocator);
}

/// Resolve a specific weight + slant variant of a family
pub fn findVariant(
    allocator: std.mem.Allocator,
    family: []const u8,
    css_weight: u16,
    italic: bool,
) !FontMatch {
    const fc_weight = cssToFcWeight(css_weight);
    const slant: u16 = if (italic) 100 else 0; // ITALIC=100, ROMAN=0
    const query = try std.fmt.allocPrint(
        allocator,
        "{s}:weight={d}:slant={d}",
        .{ family, fc_weight, slant },
    );
    defer allocator.free(query);
    return find(allocator, query);
}
