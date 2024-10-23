const std = @import("std");
const tui = @import("tui");
const kb = tui.keybindings;
const alloc = std.testing.allocator;

test "binding.match.1" {
    const binding = kb.Binding{.keys = &.{.{.key = 'j'}}};
    const sequence: []const kb.KeyEvent = &.{.{.key = 'j'}};
    const result = binding.match(sequence);
    try std.testing.expect(result == .matched);
}

test "binding.match.2" {
    const binding = kb.Binding{.keys = &.{.{.key = 'j'}, .{.key = 'k'}}};
    const sequence: []const kb.KeyEvent = &.{.{.key = 'j'}};
    const result = binding.match(sequence);
    try std.testing.expect(result == .match_possible);
}

test "binding.match.3" {
    const binding = kb.Binding{.keys = &.{.{.key = 'j'}, .{.key = 'k'}}};
    const sequence: []const kb.KeyEvent = &.{.{.key = 'j'}, .{.key = 'k'}};
    const result = binding.match(sequence);
    try std.testing.expect(result == .matched);
}

test "binding.match.4" {
    const binding = kb.Binding{.keys = &.{.{.key = 'j'}, .{.key = 'k'}}};
    const sequence: []const kb.KeyEvent = &.{.{.key = 'k'}, .{.key = 'j'}};
    const result = binding.match(sequence);
    try std.testing.expect(result == .match_impossible);
}

test "Bindings.register" {
    var bindings = try kb.Bindings.init(alloc);
    defer bindings.deinit();
    _ = &bindings;
    //try bindings.registerKeyEvent(.{});
}


