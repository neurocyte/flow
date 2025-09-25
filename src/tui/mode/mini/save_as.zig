const std = @import("std");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    try self.file_path.appendSlice(self.allocator, editor.file_path orelse "");
    if (editor.get_primary().selection) |sel| ret: {
        const text = editor.get_selection(sel, self.allocator) catch break :ret;
        defer self.allocator.free(text);
        if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
            self.file_path.clearRetainingCapacity();
        try self.file_path.appendSlice(self.allocator, text);
    }
}

pub fn name(_: *Type) []const u8 {
    return " save as";
}

pub fn select(self: *Type) void {
    if (root.is_directory(self.file_path.items)) return;
    if (self.file_path.items.len > 0)
        tp.self_pid().send(.{ "cmd", "save_file_as", .{self.file_path.items} }) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}
