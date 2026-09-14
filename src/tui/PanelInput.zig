const std = @import("std");
const tp = @import("thespian");
const command = @import("command");
const keybind = @import("keybind");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

focused: bool = false,
mode: keybind.Mode,

pub fn init(allocator: std.mem.Allocator, mode_name: []const u8) !Self {
    return .{ .mode = try keybind.mode(mode_name, allocator, .{ .insert_command = "do_nothing" }) };
}

pub fn deinit(self: *Self, w: Widget) void {
    if (self.focused) tui.release_keyboard_focus(w);
    self.mode.deinit();
}

pub fn focus(self: *Self, w: Widget) void {
    if (self.focused) return;
    self.focused = true;
    if (tui.mini_mode() != null)
        command.executeName("exit_mini_mode", .empty()) catch {};
    if (tui.input_mode_outer() != null)
        command.executeName("exit_overlay_mode", .empty()) catch {};
    tui.set_keyboard_focus(w);
    tui.need_render(@src());
}

pub fn unfocus(self: *Self, w: Widget) void {
    if (!self.focused) return;
    self.focused = false;
    tui.release_keyboard_focus(w);
    tui.need_render(@src());
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (!self.focused) return false;
    if (!try m.match(.{ "I", tp.more })) return false;
    _ = try self.mode.bindings.receive(from, m);
    return true; // swallow input
}

pub fn copy_to_clipboard(text: []const u8) void {
    const owned = tui.clipboard_allocator().dupe(u8, text) catch return;
    tui.clipboard_clear_all();
    tui.clipboard_start_group();
    tui.clipboard_add_chunk(owned);
    tui.clipboard_send_to_system() catch {};
}
