const std = @import("std");
const pm = @import("project_manager");
const builtin = @import("builtin");

test "normalize_file_path_dot_prefix" {
    try std.testing.expectEqualStrings(P1("example.txt"), pm.normalize_file_path_dot_prefix(P2("example.txt")));
    try std.testing.expectEqualStrings(P1("/example.txt"), pm.normalize_file_path_dot_prefix(P2("/example.txt")));
    try std.testing.expectEqualStrings(P1("example.txt"), pm.normalize_file_path_dot_prefix(P2("./example.txt")));
    try std.testing.expectEqualStrings(P1("example.txt"), pm.normalize_file_path_dot_prefix(P2("././example.txt")));
    try std.testing.expectEqualStrings(P1("example.txt"), pm.normalize_file_path_dot_prefix(P2(".//example.txt")));
    try std.testing.expectEqualStrings(P1("example.txt"), pm.normalize_file_path_dot_prefix(P2(".//./example.txt")));
    try std.testing.expectEqualStrings(P1("example.txt"), pm.normalize_file_path_dot_prefix(P2(".//.//example.txt")));
    try std.testing.expectEqualStrings(P1("../example.txt"), pm.normalize_file_path_dot_prefix(P2("./../example.txt")));
    try std.testing.expectEqualStrings(P1("../example.txt"), pm.normalize_file_path_dot_prefix(P2(".//../example.txt")));
    try std.testing.expectEqualStrings(P1("../example.txt"), pm.normalize_file_path_dot_prefix(P2("././../example.txt")));
    try std.testing.expectEqualStrings(P1("../example.txt"), pm.normalize_file_path_dot_prefix(P2("././/../example.txt")));
    try std.testing.expectEqualStrings(P1("../example.txt"), pm.normalize_file_path_dot_prefix(P2(".//.//../example.txt")));
    try std.testing.expectEqualStrings(P1("./"), pm.normalize_file_path_dot_prefix(P2("./")));
    try std.testing.expectEqualStrings(P1("."), pm.normalize_file_path_dot_prefix(P2(".")));
}

fn P1(file_path: []const u8) []const u8 {
    const local = struct {
        var fixed_file_path: [256]u8 = undefined;
    };
    return fix_path(&local.fixed_file_path, file_path);
}
fn P2(file_path: []const u8) []const u8 {
    const local = struct {
        var fixed_file_path: [256]u8 = undefined;
    };
    return fix_path(&local.fixed_file_path, file_path);
}
fn fix_path(dest: []u8, src: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        for (src, 0..) |c, i| switch (c) {
            std.fs.path.sep_posix => dest[i] = std.fs.path.sep_windows,
            else => dest[i] = c,
        };
        return dest[0..src.len];
    } else return src;
}
