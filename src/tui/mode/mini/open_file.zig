const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) error{ Exit, OutOfMemory }!void {
    var path_buf: [512]u8 = undefined;
    const project_path = tp.env.get().str("project");
    const project_name = project_manager.abbreviate_home(&path_buf, project_path);
    try self.file_path.appendSlice(self.allocator, project_name);
    try self.file_path.append(self.allocator, std.fs.path.sep);
    const editor = tui.get_active_editor() orelse return;
    if (editor.file_path) |old_path| {
        if (std.fs.path.dirname(old_path)) |dirname| {
            if (std.fs.path.isAbsolute(dirname)) {
                const abbreviated_dirname = project_manager.abbreviate_home(&path_buf, dirname);
                self.file_path.clearRetainingCapacity();
                try self.file_path.appendSlice(self.allocator, abbreviated_dirname);
            } else {
                try self.file_path.appendSlice(self.allocator, dirname);
            }
            try self.file_path.append(self.allocator, std.fs.path.sep);
        }
    }
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
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const file_path = project_manager.expand_home(self.allocator, &buf, self.file_path.items);
        const cmd_ = switch (self.select) {
            .normal => "navigate",
            .alternate => "navigate_split_vertical",
        };
        if (file_path.len > 0) {
            var open_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
            var dir_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
            const open: cbor.Raw = .{ .bytes = cbor.fmt(&open_buf, .{ "cmd", cmd_, .{ .file = file_path } }) };
            tui.probe(file_path, .{
                .file = open,
                .other = open,
                .dir = .{ .bytes = cbor.fmt(&dir_buf, .{ "cmd", "change_project", .{file_path} }) },
            });
        }
    }
    command.executeName("exit_mini_mode", .empty()) catch {};
}
