const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Switch buffers";
pub const name = " buffer";
pub const description = "buffer";
const dirty_indicator = "";
const hidden_indicator = "-";

pub const Entry = struct {
    label: []const u8,
    icon: []const u8,
    color: ?u24,
    indicator: []const u8,
};

pub fn load_entries(palette: *Type) !usize {
    const buffer_manager = tui.get_buffer_manager() orelse return 0;
    const buffers = try buffer_manager.list_most_recently_used(palette.allocator);
    defer palette.allocator.free(buffers);
    for (buffers) |buffer| {
        const indicator = if (buffer.is_dirty())
            dirty_indicator
        else if (buffer.is_hidden())
            hidden_indicator
        else
            "";
        (try palette.entries.addOne()).* = .{
            .label = buffer.file_path,
            .icon = buffer.file_type_icon orelse "",
            .color = buffer.file_type_color,
            .indicator = indicator,
        };
    }
    return if (palette.entries.items.len == 0) label.len else 4;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value = std.ArrayList(u8).init(palette.allocator);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.icon);
    try cbor.writeValue(writer, entry.color);
    try cbor.writeValue(writer, entry.indicator);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonState, theme: *const Widget.Theme, selected: bool) bool {
    const style_base = theme.editor_widget;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        button.plane.fill(" ");
        button.plane.home();
    }

    button.plane.set_style(style_hint);
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}", .{pointer}) catch {};

    var iter = button.opts.label;
    var file_path_: []const u8 = undefined;
    var icon: []const u8 = undefined;
    var color: u24 = undefined;
    if (!(cbor.matchString(&iter, &file_path_) catch false)) @panic("invalid buffer file path");
    if (!(cbor.matchString(&iter, &icon) catch false)) @panic("invalid buffer file type icon");
    if (!(cbor.matchInt(u24, &iter, &color) catch false)) @panic("invalid buffer file type color");
    if (tui.config().show_fileicons) {
        tui.render_file_icon(&button.plane, icon, color);
        _ = button.plane.print(" ", .{}) catch {};
    }
    button.plane.set_style(style_label);
    _ = button.plane.print(" {s} ", .{file_path_}) catch {};

    var indicator: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &indicator) catch false))
        indicator = "";
    button.plane.set_style(style_hint);
    _ = button.plane.print_aligned_right(0, "{s} ", .{indicator}) catch {};

    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            tui.render_match_cell(&button.plane, 0, index + 4, theme) catch break;
        } else break;
    }
    return false;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var file_path: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}

pub fn delete_item(menu: *Type.MenuState, button: *Type.ButtonState) bool {
    var file_path: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return false;
    command.executeName("delete_buffer", command.fmt(.{file_path})) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    return true; //refresh list
}
