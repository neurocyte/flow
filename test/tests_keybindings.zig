const std = @import("std");
const tui = @import("tui");
const Bindings = tui.keybindings.Bindings;

test "match" {
    const alloc = std.testing.allocator;
    var bind = try Bindings.init(alloc);
    defer bind.deinit();

    try tui.keybindings.addVimNamespace(&bind);
    bind.activateNamespace("vim");
    bind.activateMode("insert");

    try bind.history.append(.{ .key = 'j' });
    try bind.history.append(.{ .key = 'k' });
    try std.testing.expectEqual(tui.keybindings.vim.actions.return_to_normal_mode, bind.matchHistory());
}
