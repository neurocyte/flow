const std = @import("std");
const MiniBuffer = @import("tui").exports.MiniBuffer;

const a = std.testing.allocator;
const eq = std.testing.expectEqualStrings;

test "mini_buffer insert and navigate" {
    var mb: MiniBuffer = .init(a);
    defer mb.deinit();
    try mb.insert("hello world");
    try eq("hello world", mb.bytes());
    mb.move_word_left(.move);
    try mb.insert("big ");
    try eq("hello big world", mb.bytes());
    mb.move_begin(.move);
    try mb.insert(">");
    mb.move_end(.move);
    try mb.insert("<");
    try eq(">hello big world<", mb.bytes());
    mb.move_left(.move);
    try mb.delete_backward();
    try mb.delete_forward();
    try eq(">hello big worl", mb.bytes());
}

test "mini_buffer selection" {
    var mb: MiniBuffer = .init(a);
    defer mb.deinit();
    try mb.insert("foo/bar baz");
    mb.move_word_left(.select);
    try eq("baz", mb.selected_text().?);
    mb.move_word_left(.select);
    try eq("bar baz", mb.selected_text().?);
    try mb.insert("x");
    try eq("foo/x", mb.bytes());
    try std.testing.expect(mb.selection() == null);
    mb.select_all();
    try eq("foo/x", mb.selected_text().?);
    mb.move_left(.move);
    try std.testing.expectEqual(0, mb.cursor);
    mb.move_right(.select);
    mb.move_right(.select);
    try mb.delete_backward();
    try eq("o/x", mb.bytes());
}

test "mini_buffer word delete" {
    var mb: MiniBuffer = .init(a);
    defer mb.deinit();
    try mb.insert("src/tui/MiniBuffer.zig");
    try mb.delete_word_left();
    try eq("src/tui/MiniBuffer.", mb.bytes());
    try mb.delete_word_left();
    try eq("src/tui/", mb.bytes());
    mb.move_begin(.move);
    try mb.delete_word_right();
    try eq("tui/", mb.bytes());
    try mb.delete_to_end();
    try eq("", mb.bytes());
}

test "mini_buffer graphemes" {
    var mb: MiniBuffer = .init(a);
    defer mb.deinit();
    try mb.insert("aé👍🏽b");
    mb.move_left(.move);
    try mb.delete_backward();
    try eq("aéb", mb.bytes());
    try mb.delete_backward();
    try eq("ab", mb.bytes());
}

test "mini_buffer undo redo" {
    var mb: MiniBuffer = .init(a);
    defer mb.deinit();
    try mb.insert("a");
    try mb.insert("b");
    try mb.insert("c");
    mb.move_left(.move);
    try mb.insert("X");
    try mb.paste("pasted");
    try eq("abXpastedc", mb.bytes());
    try mb.undo();
    try eq("abXc", mb.bytes());
    try mb.undo();
    try eq("abc", mb.bytes());
    try mb.undo();
    try eq("", mb.bytes());
    try mb.undo();
    try eq("", mb.bytes());
    try mb.redo();
    try mb.redo();
    try eq("abXc", mb.bytes());
    try std.testing.expectEqual(3, mb.cursor);
    try mb.insert("!");
    try mb.redo();
    try eq("abX!c", mb.bytes());
    try mb.set_text("replaced");
    try mb.undo();
    try eq("abX!c", mb.bytes());
}

test "mini_buffer typing over a selection is one undo step" {
    var mb: MiniBuffer = .init(a);
    defer mb.deinit();
    try mb.set_text("old query");
    mb.select_all();
    try mb.insert("n");
    try mb.insert("e");
    try mb.insert("w");
    try eq("new", mb.bytes());
    try mb.undo();
    try eq("old query", mb.bytes());
    try eq("old query", mb.selected_text().?);
}
