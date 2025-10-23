const std = @import("std");
const pm = @import("project_manager");

test "normalize_file_path_dot_prefix" {
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_dot_prefix("example.txt"));
    try std.testing.expectEqualStrings("/example.txt", pm.normalize_file_path_dot_prefix("/example.txt"));
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_dot_prefix("./example.txt"));
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_dot_prefix("././example.txt"));
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_dot_prefix(".//example.txt"));
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_dot_prefix(".//./example.txt"));
    try std.testing.expectEqualStrings("example.txt", pm.normalize_file_path_dot_prefix(".//.//example.txt"));
    try std.testing.expectEqualStrings("../example.txt", pm.normalize_file_path_dot_prefix("./../example.txt"));
    try std.testing.expectEqualStrings("../example.txt", pm.normalize_file_path_dot_prefix(".//../example.txt"));
    try std.testing.expectEqualStrings("../example.txt", pm.normalize_file_path_dot_prefix("././../example.txt"));
    try std.testing.expectEqualStrings("../example.txt", pm.normalize_file_path_dot_prefix("././/../example.txt"));
    try std.testing.expectEqualStrings("../example.txt", pm.normalize_file_path_dot_prefix(".//.//../example.txt"));
    try std.testing.expectEqualStrings("./", pm.normalize_file_path_dot_prefix("./"));
    try std.testing.expectEqualStrings(".", pm.normalize_file_path_dot_prefix("."));
}
