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

    const result = try names.toOwnedSlice(allocator);
    std.mem.sort([]u8, result, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);

    // Remove adjacent duplicates that survived the sort.
    var w: usize = 0;
    for (result) |name| {
        if (w == 0 or !std.ascii.eqlIgnoreCase(result[w - 1], name)) {
            result[w] = name;
            w += 1;
        } else {
            allocator.free(name);
        }
    }
    return result[0..w];
}

pub fn find(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
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

    return allocator.dupe(u8, std.mem.sliceTo(file, 0));
}
