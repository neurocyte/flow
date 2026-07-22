const std = @import("std");
const text_manip = @import("text_manip");

const allocator = std.testing.allocator;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expect_toggle(prefix: []const u8, input: []const u8, expected: []const u8) !void {
    const output = try text_manip.toggle_prefix_in_text(prefix, input, allocator);
    defer allocator.free(output);
    try expectEqualStrings(expected, output);
}

test "add prefix to multiple lines with trailing newline" {
    try expect_toggle("//", "one\ntwo\n", "// one\n// two\n");
}

test "add prefix to multiple lines without trailing newline" {
    try expect_toggle("//", "one\ntwo", "// one\n// two");
}

test "remove prefix from multiple lines with trailing newline" {
    try expect_toggle("//", "// one\n// two\n", "one\ntwo\n");
}

test "remove prefix from multiple lines without trailing newline" {
    try expect_toggle("//", "// one\n// two", "one\ntwo");
}

test "add prefix to single line without newline" {
    try expect_toggle("//", "one", "// one");
}

test "remove prefix from single line without newline" {
    try expect_toggle("//", "// one", "one");
}

test "empty text is unchanged" {
    try expect_toggle("//", "", "");
}

test "blank lines are preserved and not prefixed" {
    try expect_toggle("//", "one\n\ntwo\n", "// one\n\n// two\n");
}

test "prefix is added at the common indent" {
    try expect_toggle("//", "    one\n    two\n", "    // one\n    // two\n");
}

test "prefix is removed from indented lines" {
    try expect_toggle("//", "    // one\n    // two\n", "    one\n    two\n");
}

test "mixed prefixed and unprefixed lines are all prefixed" {
    try expect_toggle("//", "// one\ntwo\n", "// // one\n// two\n");
}

test "add and remove round-trip" {
    const input = "one\n  two\n\nthree";
    const commented = try text_manip.toggle_prefix_in_text("//", input, allocator);
    defer allocator.free(commented);
    const output = try text_manip.toggle_prefix_in_text("//", commented, allocator);
    defer allocator.free(output);
    try expectEqualStrings(input, output);
}
