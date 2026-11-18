const std = @import("std");
const vcs_hunks = @import("tui").exports.mode.vcs_hunks;

fn map(diff: []const u8, line: usize) !usize {
    const ranges = try vcs_hunks.parse_headers(std.testing.allocator, diff);
    defer std.testing.allocator.free(ranges);
    return vcs_hunks.map_line(ranges, line);
}

test "vcs_hunks parse_header" {
    try std.testing.expectEqual(vcs_hunks.Range{ .old_start = 3, .old_count = 2, .new_start = 4, .new_count = 5 }, vcs_hunks.parse_header("@@ -3,2 +4,5 @@ fn main() void {").?);
    try std.testing.expectEqual(vcs_hunks.Range{ .old_start = 7, .old_count = 1, .new_start = 7, .new_count = 1 }, vcs_hunks.parse_header("@@ -7 +7 @@").?);
    try std.testing.expectEqual(null, vcs_hunks.parse_header("diff --git a/f b/f"));
}

test "vcs_hunks distance" {
    try std.testing.expectEqual(@as(usize, 0), vcs_hunks.distance("@@ -10,3 +10,4 @@", 12));
    try std.testing.expectEqual(@as(usize, 2), vcs_hunks.distance("@@ -10,3 +10,4 @@", 8));
    try std.testing.expectEqual(@as(usize, 1), vcs_hunks.distance("@@ -10,3 +10,4 @@", 14));
}

test "vcs_hunks map_line through a changed block" {
    const diff = "@@ -3,2 +3,4 @@\n-a\n-b\n+c\n+d\n+e\n+f\n";
    try std.testing.expectEqual(@as(usize, 1), try map(diff, 1));
    try std.testing.expectEqual(@as(usize, 3), try map(diff, 4));
    try std.testing.expectEqual(@as(usize, 8), try map(diff, 6));
}

test "vcs_hunks map_line through an insert" {
    const diff = "@@ -2,0 +3,2 @@\n+x\n+y\n";
    try std.testing.expectEqual(@as(usize, 2), try map(diff, 2));
    try std.testing.expectEqual(@as(usize, 5), try map(diff, 3));
}

test "vcs_hunks map_line through a delete" {
    const diff = "@@ -4,2 +3,0 @@\n-x\n-y\n";
    try std.testing.expectEqual(@as(usize, 3), try map(diff, 3));
    try std.testing.expectEqual(@as(usize, 4), try map(diff, 5));
    try std.testing.expectEqual(@as(usize, 4), try map(diff, 6));
}

test "vcs_hunks map_line through several hunks" {
    const diff = "@@ -2,0 +3,1 @@\n+x\n@@ -5,1 +6,0 @@\n-y\n@@ -9,1 +9,3 @@\n-z\n+1\n+2\n+3\n";
    try std.testing.expectEqual(@as(usize, 4), try map(diff, 3));
    try std.testing.expectEqual(@as(usize, 7), try map(diff, 7));
    try std.testing.expectEqual(@as(usize, 9), try map(diff, 9));
    try std.testing.expectEqual(@as(usize, 12), try map(diff, 10));
}

test "vcs_hunks map_line without hunks" {
    try std.testing.expectEqual(@as(usize, 42), try map("", 42));
}
