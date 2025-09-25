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
pub const icon = "󰈞  ";

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
        const indicator = tui.get_buffer_state_indicator(buffer);
        (try palette.entries.addOne()).* = .{
            .label = buffer.get_file_path(),
            .icon = buffer.file_type_icon orelse "",
            .color = buffer.file_type_color,
            .indicator = indicator,
        };
    }
    return if (palette.entries.items.len == 0) label.len + 3 else 4;
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
    return tui.render_file_item_cbor(&button.plane, button.opts.label, button.active, selected, button.hover, theme);
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
