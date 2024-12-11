const std = @import("std");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) error{ Exit, OutOfMemory }!void {
    const editor = tui.get_active_editor() orelse return;
    if (editor.is_dirty()) return tp.exit("unsaved changes");
    if (editor.file_path) |old_path|
        if (std.mem.lastIndexOf(u8, old_path, "/")) |pos|
            try self.file_path.appendSlice(old_path[0 .. pos + 1]);
    if (editor.get_primary().selection) |sel| ret: {
        const text = editor.get_selection(sel, self.allocator) catch break :ret;
        defer self.allocator.free(text);
        if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
            self.file_path.clearRetainingCapacity();
        try self.file_path.appendSlice(text);
    }
}

pub fn name(_: *Type) []const u8 {
    return " open";
}

pub fn select(self: *Type) void {
    if (root.is_directory(self.file_path.items)) return;
    if (self.file_path.items.len > 0)
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = self.file_path.items } }) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}
