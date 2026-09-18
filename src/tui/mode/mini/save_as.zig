const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const project_manager = @import("project_manager");

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
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const file_path = project_manager.expand_home(self.allocator, &buf, self.file_path.items);
        if (file_path.len > 0) {
            var save_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
            const save: cbor.Raw = .{ .bytes = cbor.fmt(&save_buf, .{ "cmd", "save_file_as", .{file_path} }) };
            tui.probe(file_path, .{ .file = save, .other = save });
        }
    }
    command.executeName("exit_mini_mode", .empty()) catch {};
}
