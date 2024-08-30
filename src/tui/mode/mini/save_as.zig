const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const root = @import("root");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const MessageFilter = @import("../../MessageFilter.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) !void {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        if (editor.file_path) |old_path|
            if (std.mem.lastIndexOf(u8, old_path, "/")) |pos|
                try self.file_path.appendSlice(old_path[0 .. pos + 1]);
        if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.a) catch break :ret;
            defer self.a.free(text);
            if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
                self.file_path.clearRetainingCapacity();
            try self.file_path.appendSlice(text);
        }
    };
}

pub fn name(_: *Type) []const u8 {
    return " save as";
}

pub fn select(self: *Type) void {
    if (root.is_directory(self.file_path.items) catch false) return;
    if (self.file_path.items.len > 0)
        tp.self_pid().send(.{ "cmd", "save_file_as", .{self.file_path.items} }) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}
