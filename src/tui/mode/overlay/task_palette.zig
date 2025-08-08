const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const Widget = @import("../../Widget.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());

pub const label = "Run a task";
pub const name = " task";
pub const description = "task";

pub const Entry = struct {
    label: []const u8,
    command: ?[]const u8 = null,
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
            (try palette.entries.addOne()).* = .{ .label = try palette.allocator.dupe(u8, task) };
        } else return error.InvalidTaskMessageField;
    }
    (try palette.entries.addOne()).* = .{
        .label = try palette.allocator.dupe(u8, " Add new task"),
        .command = "add_task",
    };
    return if (palette.entries.items.len == 0) label.len else blk: {
        var longest: usize = 0;
        for (palette.entries.items) |item| longest = @max(longest, item.label.len);
        break :blk if (longest < label.len) return label.len - longest + 1 else 1;
    };
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
    try cbor.writeValue(writer, entry);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonState, theme: *const Widget.Theme, selected: bool) bool {
    var entry: Entry = undefined;
    var iter = button.opts.label; // label contains cbor entry object and matches
    if (!(cbor.matchValue(&iter, cbor.extract(&entry)) catch false))
        entry.label = "#ERROR#";

    const style_base = theme.editor_widget;
    const style_label =
        if (button.active)
            theme.editor_cursor
        else if (button.hover or selected)
            theme.editor_selection
        else if (entry.command) |_|
            theme.input_placeholder
        else
            theme.editor_widget;

    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    button.plane.fill(" ");
    button.plane.home();
    button.plane.set_style(style_hint);
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}", .{pointer}) catch {};
    button.plane.set_style(style_label);
    _ = button.plane.print("{s} ", .{entry.label}) catch {};
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            tui.render_match_cell(&button.plane, 0, index + 1, theme) catch break;
        } else break;
    }
    return false;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var entry: Entry = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&entry)) catch false)) return;
    var buffer_name = std.ArrayList(u8).init(menu.*.opts.ctx.allocator);
    defer buffer_name.deinit();
    buffer_name.writer().print("*{s}*", .{entry.label}) catch {};
    if (entry.command) |cmd| {
        tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
        tp.self_pid().send(.{ "cmd", cmd, .{entry.label} }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    } else {
        project_manager.add_task(entry.label) catch {};
        tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
        tp.self_pid().send(.{ "cmd", "create_scratch_buffer", .{ buffer_name.items, "", "conf" } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
        tp.self_pid().send(.{ "cmd", "shell_execute_stream", .{entry.label} }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    }
}

pub fn delete_item(menu: *Type.MenuState, button: *Type.ButtonState) bool {
    var entry: Entry = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&entry)) catch false)) return false;
    command.executeName("delete_task", command.fmt(.{entry.label})) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    return true; //refresh list
}
