const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Changed or untracked files";
pub const name = " status";
pub const description = "vcs status";
pub const icon = "󰈞  ";
pub const placement = .top_center;

const max_recent_files: usize = 25;

pub const Entry = struct {
    label: []const u8,
    file_icon: []const u8,
    file_color: u24,
    vcs_status: u8,
};

pub fn load_entries(palette: *Type) !usize {
    tui.message_filters().add(MessageFilter.bind(palette, receive_project_manager)) catch {};
    try project_manager.request_new_or_modified_files(max_recent_files);
    return 3;
}

pub fn clear_entries(palette: *Type) void {
    for (palette.entries.items) |entry| {
        palette.allocator.free(entry.label);
        palette.allocator.free(entry.file_icon);
    }
    palette.entries.clearRetainingCapacity();
}

pub fn deinit(palette: *Type) void {
    tui.message_filters().remove_ptr(palette);
    clear_entries(palette);
}

fn receive_project_manager(palette: *Type, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (!(cbor.match(m.buf, .{ "PRJ", tp.more }) catch false)) return false;

    var file_name: []const u8 = undefined;
    var file_type: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var file_color: u24 = undefined;
    var vcs_status: u8 = undefined;

    if (try cbor.match(m.buf, .{
        "PRJ",
        "new_or_modified_files",
        tp.any,
        tp.extract(&file_name),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
        tp.extract(&vcs_status),
    })) {
        try append_entry(palette, file_name, file_icon, file_color, vcs_status);
    } else if (try cbor.match(m.buf, .{ "PRJ", "new_or_modified_files_done", tp.any, tp.any })) {
        palette.start_query(0) catch {};
        tui.need_render(@src());
    } else {
        palette.logger.err("receive", tp.unexpected(m));
    }
    return true;
}

fn append_entry(palette: *Type, file_name: []const u8, file_icon: []const u8, file_color: u24, vcs_status: u8) !void {
    const path = try palette.allocator.dupe(u8, file_name);
    errdefer palette.allocator.free(path);
    const icon_copy = try palette.allocator.dupe(u8, file_icon);
    errdefer palette.allocator.free(icon_copy);
    (try palette.entries.addOne(palette.allocator)).* = .{
        .label = path,
        .file_icon = icon_copy,
        .file_color = file_color,
        .vcs_status = vcs_status,
    };
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    const indicator = if (tui.get_buffer_manager()) |bm| tui.get_file_state_indicator(bm, entry.label) else "";
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.file_icon);
    try cbor.writeValue(writer, entry.file_color);
    try cbor.writeValue(writer, indicator);
    try cbor.writeValue(writer, entry.vcs_status);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    return tui.render_file_vcs_item_cbor(&button.plane, button.opts.label, button.active, selected, button.hover, theme);
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    var file_path: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}
