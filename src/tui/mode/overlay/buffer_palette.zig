const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());

pub const label = "Switch buffers";
pub const name = " buffer";
pub const description = "buffer";
const dirty_indicator = "";

pub const Entry = struct {
    label: []const u8,
    hint: []const u8,
};

pub fn load_entries(palette: *Type) !usize {
    const buffer_manager = tui.get_buffer_manager() orelse return 0;
    const buffers = try buffer_manager.list_most_recently_used(palette.allocator);
    defer palette.allocator.free(buffers);
    for (buffers) |buffer| {
        const hint = if (buffer.is_dirty()) dirty_indicator else "";
        (try palette.entries.addOne()).* = .{ .label = buffer.file_path, .hint = hint };
    }
    return if (palette.entries.items.len == 0) label.len else 2;
}

pub fn clear_entries(palette: *Type) void {
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
