const std = @import("std");
const fc = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

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
