const std = @import("std");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    const file_path = editor.file_path orelse return;
    try self.mini_editor.buffer.insert(file_path);
    const basename = std.fs.path.basename(file_path);
    const extension = std.fs.path.extension(basename);
    self.mini_editor.buffer.select_range(file_path.len - basename.len, file_path.len - extension.len);
}

pub fn name(_: *Type) []const u8 {
    return " rename";
}

pub fn select(self: *Type) void {
    rename(self) catch |e| std.log.err("rename_file: {t}", .{e});
    command.executeName("exit_mini_mode", .empty()) catch {};
}

fn rename(self: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    const from_path = editor.file_path orelse return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    const to_path = project_manager.expand_home(self.allocator, &buf, self.file_path());
    if (to_path.len == 0 or std.mem.eql(u8, to_path, from_path)) return;
    try tui.apply_single_file_operation(self.allocator, .{ .kind = .rename, .path = from_path, .to_path = to_path, .conflict = .fail }, .{});
}
