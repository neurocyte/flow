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

test "normalize_file_path_windows" {
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_windows("example.txt", &file_path_buf));
    try std.testing.expectEqualStrings("\\example.txt", pm.normalize_file_path_windows("/example.txt", &file_path_buf));
    try std.testing.expectEqualStrings(".\\example.txt", pm.normalize_file_path_windows("./example.txt", &file_path_buf));
    try std.testing.expectEqualStrings(".\\.\\example.txt", pm.normalize_file_path_windows("././example.txt", &file_path_buf));
    try std.testing.expectEqualStrings(".\\\\example.txt", pm.normalize_file_path_windows(".//example.txt", &file_path_buf));
    try std.testing.expectEqualStrings(".\\\\.\\example.txt", pm.normalize_file_path_windows(".//./example.txt", &file_path_buf));
    try std.testing.expectEqualStrings(".\\", pm.normalize_file_path_windows("./", &file_path_buf));
    try std.testing.expectEqualStrings(".", pm.normalize_file_path_windows(".", &file_path_buf));
    try std.testing.expectEqualStrings("C:\\User\\x\\example.txt", pm.normalize_file_path_windows("C:\\User\\x/example.txt", &file_path_buf));
    try std.testing.expectEqualStrings("C:\\User\\x\\path\\example.txt", pm.normalize_file_path_windows("C:\\User\\x/path/example.txt", &file_path_buf));
    try std.testing.expectEqualStrings("C:\\User\\x\\path\\example.txt", pm.normalize_file_path_windows("C:/User/x/path/example.txt", &file_path_buf));
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

test "strip_trailing_separators" {
    try std.testing.expectEqualStrings("/usr", pm.strip_trailing_separators("/usr"));
    try std.testing.expectEqualStrings("/usr", pm.strip_trailing_separators("/usr/"));
    try std.testing.expectEqualStrings("/usr", pm.strip_trailing_separators("/usr///"));
    try std.testing.expectEqualStrings("/", pm.strip_trailing_separators("/"));
    if (builtin.os.tag == .windows) {
        // {{env:SystemDrive}} expands to "C:", the project directory is "C:\"
        try std.testing.expectEqualStrings("C:", pm.strip_trailing_separators("C:\\"));
        try std.testing.expectEqualStrings("C:", pm.strip_trailing_separators("C:"));
        try std.testing.expectEqualStrings("\\", pm.strip_trailing_separators("\\"));
    }
}

test "same_directory" {
    try std.testing.expect(pm.same_directory("/usr", "/usr"));
    try std.testing.expect(pm.same_directory("/usr/", "/usr"));
    try std.testing.expect(pm.same_directory("/", "/"));
    // exact directory matches only: nothing below a listed directory matches
    try std.testing.expect(!pm.same_directory("/usr/share", "/usr"));
    try std.testing.expect(!pm.same_directory("/usr", "/usr/share"));
    try std.testing.expect(!pm.same_directory("/usrx", "/usr"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(pm.same_directory("C:\\", "C:"));
        try std.testing.expect(pm.same_directory("C:\\", "c:\\"));
        try std.testing.expect(pm.same_directory("C:/Users", "c:\\users"));
        try std.testing.expect(!pm.same_directory("C:\\Users", "C:"));
    } else {
        // case is significant everywhere else
        try std.testing.expect(!pm.same_directory("/Usr", "/usr"));
    }
}
