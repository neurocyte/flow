const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Search files by name";
pub const name = "󰈞 open recent";
pub const description = "open recent";
pub const icon = "󰈞  ";

const max_recent_files: usize = 25;

pub const ValueType = struct {
    query_pending: bool = false,
    need_reset: bool = false,
    total_files_in_project: usize = 0,
    restore_pending: bool = false,
    restore_selected: ?usize = null,
    restore_info: std.ArrayList([]const u8) = .empty,
};
pub const defaultValue: ValueType = .{};

pub const Entry = struct { label: []const u8 };
pub fn add_menu_entry(_: *Type, _: *Entry, _: ?[]const usize) !void {}

pub fn load_entries_with_args(palette: *Type, ctx: command.Context) !usize {
    palette.longest = label.len;
    tui.message_filters().add(MessageFilter.bind(palette, receive_project_manager)) catch {};
    if (ctx.args.buf.len != 0) {
        try restore(palette, ctx);
        palette.quick_activate_enabled = false;
    }
    return 3;
}

pub fn deinit(palette: *Type) void {
    save(palette);
    clear_restore_info(palette);
    palette.value.restore_info.deinit(palette.allocator);
}

pub fn query(palette: *Type, query_text: []const u8) MessageFilter.Error!void {
    if (palette.value.restore_pending) {
        palette.value.restore_pending = false;
        finish_restore(palette);
        return;
    }
    palette.total_items = 0;
    if (palette.value.query_pending) return;
    palette.value.query_pending = true;
    clear_restore_info(palette);
    if (query_text.len == 0)
        try project_manager.request_recent_files(max_recent_files)
    else
        try project_manager.query_recent_files(max_recent_files, query_text);
}

pub fn update_count_hint(palette: *Type) void {
    palette.inputbox.hint.clearRetainingCapacity();
    palette.inputbox.hint.print(palette.inputbox.allocator, "{d}/{d}", .{ palette.total_items, palette.value.total_files_in_project }) catch {};
}

pub fn complete(palette: *Type, button_: ?*Type.ButtonType) !void {
    const pos = palette.inputbox.text.items.len;
    const button = button_ orelse return;
    var iter = button.opts.label;
    var file_path: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;

    if (std.mem.indexOfPos(u8, file_path, pos, &.{std.fs.path.sep})) |pos_| {
        palette.inputbox.text.shrinkRetainingCapacity(0);
        try palette.inputbox.text.appendSlice(palette.allocator, file_path[0..@min(pos_ + 1, file_path.len)]);
    }

    palette.inputbox.cursor = tui.egc_chunk_width(palette.inputbox.text.items, 0, 8);
    return palette.start_query(0);
}

pub fn cancel(palette: *Type, _: command.Context) !void {
    save(palette);
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    return tui.render_file_item_cbor(&button.plane, button.opts.label, button.active, selected, button.hover, theme);
}

fn receive_project_manager(palette: *Type, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (!(cbor.match(m.buf, .{ "PRJ", tp.more }) catch false)) return false;
    try process_project_manager(palette, m);
    return true;
}

fn process_project_manager(palette: *Type, m: tp.message) MessageFilter.Error!void {
    defer tui.reset_hover(@src());
    var file_name: []const u8 = undefined;
    var file_type: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var file_color: u24 = undefined;
    var matches: []const u8 = undefined;
    var query_: []const u8 = undefined;
    if (try cbor.match(m.buf, .{
        "PRJ",
        "recent",
        tp.extract(&palette.longest),
        tp.extract(&file_name),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
        tp.extract_cbor(&matches),
    })) {
        if (palette.value.need_reset) reset_results(palette);
        const indicator = if (tui.get_buffer_manager()) |bm| tui.get_file_state_indicator(bm, file_name) else "";
        try add_item(palette, file_name, file_icon, file_color, indicator, matches);
        tui.need_render(@src());
    } else if (try cbor.match(m.buf, .{
        "PRJ",
        "recent",
        tp.extract(&palette.longest),
        tp.extract(&file_name),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
    })) {
        if (palette.value.need_reset) reset_results(palette);
        const indicator = if (tui.get_buffer_manager()) |bm| tui.get_file_state_indicator(bm, file_name) else "";
        try add_item(palette, file_name, file_icon, file_color, indicator, null);
        tui.need_render(@src());
    } else if (try cbor.match(m.buf, .{ "PRJ", "recent_done", tp.extract(&palette.longest), tp.extract(&query_), tp.extract(&palette.value.total_files_in_project) })) {
        update_count_hint(palette);
        palette.value.query_pending = false;
        palette.value.need_reset = true;
        if (!std.mem.eql(u8, palette.inputbox.text.items, query_))
            try query(palette, palette.inputbox.text.items);
    } else if (try cbor.match(m.buf, .{ "PRJ", "open_done", tp.string, tp.extract(&palette.longest), tp.extract(&palette.value.total_files_in_project) })) {
        update_count_hint(palette);
        palette.value.query_pending = false;
        palette.value.need_reset = true;
        try query(palette, palette.inputbox.text.items);
    } else {
        palette.logger.err("receive", tp.unexpected(m));
    }
}

fn reset_results(palette: *Type) void {
    palette.value.need_reset = false;
    palette.items = 0;
    palette.total_items = 0;
    palette.menu.reset_items();
    palette.menu.selected = null;
}

fn add_item(
    palette: *Type,
    file_name: []const u8,
    file_icon: []const u8,
    file_color: u24,
    indicator: []const u8,
    matches: ?[]const u8,
) !void {
    var label_: std.Io.Writer.Allocating = .init(palette.allocator);
    defer label_.deinit();
    const writer = &label_.writer;
    try cbor.writeValue(writer, file_name);
    try cbor.writeValue(writer, file_icon);
    try cbor.writeValue(writer, file_color);
    try cbor.writeValue(writer, indicator);
    if (matches) |cb| _ = try writer.write(cb) else try cbor.writeValue(writer, &[_]usize{});
    const data = try label_.toOwnedSlice();
    errdefer palette.allocator.free(data);
    try store_item(palette, data);
}

fn store_item(palette: *Type, item: []const u8) !void {
    try palette.append_async_item(item, menu_action_open_file);
    (try palette.value.restore_info.addOne(palette.allocator)).* = item;
}

fn menu_action_open_file(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const palette = menu.*.opts.ctx;
    save(palette);
    var file_path: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| palette.logger.err(module_name, e);
    const cmd_ = switch (palette.activate) {
        .normal => "navigate",
        .alternate => "navigate_split_vertical",
    };
    tp.self_pid().send(.{ "cmd", cmd_, .{ .file = file_path } }) catch |e| palette.logger.err(module_name, e);
}

fn save(palette: *Type) void {
    var data: std.Io.Writer.Allocating = .init(palette.allocator);
    defer data.deinit();
    const writer = &data.writer;

    cbor.writeArrayHeader(writer, 4) catch return;
    cbor.writeValue(writer, palette.inputbox.text.items) catch return;
    cbor.writeValue(writer, palette.longest) catch return;
    cbor.writeValue(writer, palette.menu.selected) catch return;
    cbor.writeArrayHeader(writer, palette.value.restore_info.items.len) catch return;
    for (palette.value.restore_info.items) |item| cbor.writeValue(writer, item) catch return;

    tui.set_last_palette(.open_recent, .init(.{ .buf = data.written() }));
}

fn restore(palette: *Type, ctx: command.Context) !void {
    var iter = ctx.args.buf;

    if ((cbor.decodeArrayHeader(&iter) catch 0) != 4) return;

    var input_: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &input_) catch return)) return;

    palette.inputbox.text.shrinkRetainingCapacity(0);
    try palette.inputbox.text.appendSlice(palette.inputbox.allocator, input_);
    palette.inputbox.cursor = tui.egc_chunk_width(palette.inputbox.text.items, 0, 8);

    if (!(cbor.matchValue(&iter, cbor.extract(&palette.longest)) catch return)) return;

    var selected: ?usize = null;
    if (!(cbor.matchValue(&iter, cbor.extract(&selected)) catch return)) return;

    var len = cbor.decodeArrayHeader(&iter) catch 0;
    while (len > 0) : (len -= 1) {
        var item: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &item) catch break)) break;
        const data = try palette.allocator.dupe(u8, item);
        errdefer palette.allocator.free(data);
        try store_item(palette, data);
    }

    palette.value.restore_pending = true;
    palette.value.restore_selected = selected;
}

fn finish_restore(palette: *Type) void {
    palette.refresh_layout();
    if (palette.value.restore_selected) |idx| {
        palette.menu.select_first();
        var i = idx;
        while (i > 0) : (i -= 1) palette.menu.select_down();
    }
    palette.value.need_reset = true;
}

fn clear_restore_info(palette: *Type) void {
    for (palette.value.restore_info.items) |item| palette.allocator.free(item);
    palette.value.restore_info.clearRetainingCapacity();
}
