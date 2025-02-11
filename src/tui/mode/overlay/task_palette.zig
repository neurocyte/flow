const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());

pub const label = "Run a task";
pub const name = " task";
pub const description = "task";

pub const Entry = struct {
    label: []const u8,
    hint: []const u8,
};

pub fn deinit(palette: *Type) void {
    clear_entries(palette);
}

pub fn load_entries(palette: *Type) !usize {
    const rsp = try project_manager.request_tasks(palette.allocator);
    defer palette.allocator.free(rsp.buf);
    var iter: []const u8 = rsp.buf;
    var len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var task: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract(&task))) {
            (try palette.entries.addOne()).* = .{ .label = try palette.allocator.dupe(u8, task), .hint = "" };
        } else return error.InvalidTaskMessageField;
    }
    return if (palette.entries.items.len == 0) label.len else 1;
}

pub fn clear_entries(palette: *Type) void {
    for (palette.entries.items) |entry|
        palette.allocator.free(entry.label);
    palette.entries.clearRetainingCapacity();
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value = std.ArrayList(u8).init(palette.allocator);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.hint);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var task: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &task) catch false)) return;
    var buffer_name = std.ArrayList(u8).init(menu.*.opts.ctx.allocator);
    defer buffer_name.deinit();
    buffer_name.writer().print("*{s}*", .{task}) catch {};
    project_manager.add_task(task) catch {};
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "create_scratch_buffer", .{ buffer_name.items, "", "conf" } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "shell_execute_stream", .{task} }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}

pub fn delete_item(menu: *Type.MenuState, button: *Type.ButtonState) bool {
    var task: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &task) catch false)) return false;
    command.executeName("delete_task", command.fmt(.{task})) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    return true; //refresh list
}
