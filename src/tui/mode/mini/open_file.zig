const std = @import("std");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) error{ Exit, OutOfMemory }!void {
    var project_name_buf: [512]u8 = undefined;
    const project_path = tp.env.get().str("project");
    const project_name = project_manager.abbreviate_home(&project_name_buf, project_path);
    try self.file_path.appendSlice(self.allocator, project_name);
    try self.file_path.append(self.allocator, std.fs.path.sep);
    const editor = tui.get_active_editor() orelse return;
    if (editor.file_path) |old_path|
        if (std.mem.lastIndexOf(u8, old_path, "/")) |pos|
            try self.file_path.appendSlice(self.allocator, old_path[0 .. pos + 1]);
    if (editor.get_primary().selection) |sel| ret: {
        const text = editor.get_selection(sel, self.allocator) catch break :ret;
        defer self.allocator.free(text);
        if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
            self.file_path.clearRetainingCapacity();
        try self.file_path.appendSlice(self.allocator, text);
    }
}

pub fn name(_: *Type) []const u8 {
    return " open";
}

pub fn select(self: *Type) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    const file_path = project_manager.expand_home(self.allocator, &buf, self.file_path.items);
    if (root.is_directory(file_path))
        tp.self_pid().send(.{ "cmd", "change_project", .{file_path} }) catch {}
    else if (file_path.len > 0)
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}
