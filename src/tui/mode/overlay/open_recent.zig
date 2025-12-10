const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const file_type_config = @import("file_type_config");
const root = @import("soft_root").root;

const Plane = @import("renderer").Plane;
const input = @import("input");
const keybind = @import("keybind");
const project_manager = @import("project_manager");
const command = @import("command");
const EventHandler = @import("EventHandler");
const BufferManager = @import("Buffer").Manager;

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
const Button = @import("../../Button.zig");
const InputBox = @import("../../InputBox.zig");
const Menu = @import("../../Menu.zig");
const Widget = @import("../../Widget.zig");
const ModalBackground = @import("../../ModalBackground.zig");

const Self = @This();
const max_recent_files: usize = 25;
const widget_type: Widget.Type = .palette;

allocator: std.mem.Allocator,
f: usize = 0,
modal: *ModalBackground.State(*Self),
menu: *MenuType,
inputbox: *InputBox.State(*Self),
logger: log.Logger,
query_pending: bool = false,
need_reset: bool = false,
need_select_first: bool = true,
longest: usize,
commands: Commands = undefined,
buffer_manager: ?*BufferManager,
split: enum { none, vertical } = .none,
total_items: usize = 0,
total_files_in_project: usize = 0,
quick_activate_enabled: bool = true,
restore_info: std.ArrayList([]const u8) = .empty,

const inputbox_label = "Search files by name";
const MenuType = Menu.Options(*Self).MenuType;
const ButtonType = MenuType.ButtonType;

pub fn create(allocator: std.mem.Allocator) !tui.Mode {
    return create_with_args(allocator, .{});
}

pub fn create_with_args(allocator: std.mem.Allocator, ctx: command.Context) !tui.Mode {
    const mv = tui.mainview() orelse return error.NotFound;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .modal = try ModalBackground.create(*Self, allocator, tui.mainview_widget(), .{ .ctx = self }),
        .menu = try Menu.create(*Self, allocator, tui.plane(), .{
            .ctx = self,
            .style = widget_type,
            .on_render = on_render_menu,
            .prepare_resize = prepare_resize_menu,
        }),
        .logger = log.logger(@typeName(Self)),
        .inputbox = (try self.menu.add_header(try InputBox.create(*Self, self.allocator, self.menu.menu.parent, .{
            .ctx = self,
            .label = inputbox_label,
            .padding = 2,
            .icon = "󰈞  ",
        }))).dynamic_cast(InputBox.State(*Self)) orelse unreachable,
        .buffer_manager = tui.get_buffer_manager(),
        .longest = inputbox_label.len,
    };
    try self.commands.init(self);
    try tui.message_filters().add(MessageFilter.bind(self, receive_project_manager));

    if (ctx.args.buf.len != 0) {
        try self.restore(ctx);
        self.quick_activate_enabled = false;
    } else {
        self.query_pending = true;
        try project_manager.request_recent_files(max_recent_files);
    }

    self.do_resize();
    try mv.floating_views.add(self.modal.widget());
    try mv.floating_views.add(self.menu.container_widget);
    var mode = try keybind.mode("overlay/palette", allocator, .{
        .insert_command = "overlay_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    mode.name = "󰈞 open recent";
    return mode;
}

pub fn deinit(self: *Self) void {
    self.save();
    self.clear_restore_info();
    self.commands.deinit();
    tui.message_filters().remove_ptr(self);
    if (tui.mainview()) |mv| {
        mv.floating_views.remove(self.menu.container_widget);
        mv.floating_views.remove(self.modal.widget());
    }
    self.logger.deinit();
    self.allocator.destroy(self);
}

fn clear_restore_info(self: *Self) void {
    for (self.restore_info.items) |item| self.allocator.free(item);
    self.restore_info.clearRetainingCapacity();
}

fn save(self: *Self) void {
    var data: std.Io.Writer.Allocating = .init(self.allocator);
    defer data.deinit();
    const writer = &data.writer;

    cbor.writeArrayHeader(writer, 4) catch return;
    cbor.writeValue(writer, self.inputbox.text.items) catch return;
    cbor.writeValue(writer, self.longest) catch return;
    cbor.writeValue(writer, self.menu.selected) catch return;
    cbor.writeArrayHeader(writer, self.restore_info.items.len) catch return;
    for (self.restore_info.items) |item| cbor.writeValue(writer, item) catch return;

    tui.set_last_palette(.open_recent, .{ .args = .{ .buf = data.written() } });
}

fn restore(self: *Self, ctx: command.Context) !void {
    var iter = ctx.args.buf;

    if ((cbor.decodeArrayHeader(&iter) catch 0) != 4) return;

    var input_: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &input_) catch return)) return;

    self.inputbox.text.shrinkRetainingCapacity(0);
    try self.inputbox.text.appendSlice(self.inputbox.allocator, input_);
    self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);

    if (!(cbor.matchValue(&iter, cbor.extract(&self.longest)) catch return)) return;

    var selected: ?usize = null;
    if (!(cbor.matchValue(&iter, cbor.extract(&selected)) catch return)) return;

    var len = cbor.decodeArrayHeader(&iter) catch 0;
    while (len > 0) : (len -= 0) {
        var item: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &item) catch break)) break;
        const data = try self.allocator.dupe(u8, item);
        errdefer self.allocator.free(data);
        try self.restore_item(data);
    }

    self.do_resize();

    if (selected) |idx| {
        var i = idx + 1;
        while (i > 0) : (i -= 1) self.menu.select_down();
    }
}

inline fn menu_width(self: *Self) usize {
    return @max(@min(self.longest + 3, max_menu_width()) + 5, inputbox_label.len + 2);
}

inline fn menu_pos_x(self: *Self) usize {
    const screen_width = tui.screen().w;
    const width = self.menu_width();
    return if (screen_width <= width) 0 else (screen_width - width) / 2;
}

inline fn max_menu_width() usize {
    const width = tui.screen().w;
    return @max(15, width - (width / 5));
}

fn on_render_menu(_: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    return tui.render_file_item_cbor(&button.plane, button.opts.label, button.active, selected, button.hover, theme);
}

fn prepare_resize_menu(self: *Self, _: *MenuType, _: Widget.Box) Widget.Box {
    return self.prepare_resize();
}

fn prepare_resize(self: *Self) Widget.Box {
    const w = self.menu_width();
    const x = self.menu_pos_x();
    const h = self.menu.menu.widgets.items.len;
    return .{ .y = 0, .x = x, .w = w, .h = h };
}

fn do_resize(self: *Self) void {
    self.menu.resize(self.prepare_resize());
}

fn menu_action_open_file(menu: **MenuType, button: *ButtonType, _: Widget.Pos) void {
    menu.*.opts.ctx.save();
    var file_path: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
    const cmd_ = switch (menu.*.opts.ctx.split) {
        .none => "navigate",
        .vertical => "navigate_split_vertical",
    };
    tp.self_pid().send(.{ "cmd", cmd_, .{ .file = file_path } }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
}

fn add_item(
    self: *Self,
    file_name: []const u8,
    file_icon: []const u8,
    file_color: u24,
    indicator: []const u8,
    matches: ?[]const u8,
) !void {
    var label: std.Io.Writer.Allocating = .init(self.allocator);
    defer label.deinit();
    const writer = &label.writer;
    try cbor.writeValue(writer, file_name);
    try cbor.writeValue(writer, file_icon);
    try cbor.writeValue(writer, file_color);
    try cbor.writeValue(writer, indicator);
    if (matches) |cb| _ = try writer.write(cb) else try cbor.writeValue(writer, &[_]usize{});
    const data = try label.toOwnedSlice();
    errdefer self.allocator.free(data);
    try self.restore_item(data);
}

fn restore_item(
    self: *Self,
    label: []const u8,
) error{OutOfMemory}!void {
    self.total_items += 1;
    try self.menu.add_item_with_handler(label, menu_action_open_file);
    (try self.restore_info.addOne(self.allocator)).* = label;
}

fn receive_project_manager(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (cbor.match(m.buf, .{ "PRJ", tp.more }) catch false) {
        try self.process_project_manager(m);
        return true;
    }
    return false;
}

fn process_project_manager(self: *Self, m: tp.message) MessageFilter.Error!void {
    var file_name: []const u8 = undefined;
    var file_type: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var file_color: u24 = undefined;
    var matches: []const u8 = undefined;
    var query: []const u8 = undefined;
    if (try cbor.match(m.buf, .{
        "PRJ",
        "recent",
        tp.extract(&self.longest),
        tp.extract(&file_name),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
        tp.extract_cbor(&matches),
    })) {
        if (self.need_reset) self.reset_results();
        const indicator = if (self.buffer_manager) |bm| tui.get_file_state_indicator(bm, file_name) else "";
        try self.add_item(file_name, file_icon, file_color, indicator, matches);
        self.do_resize();
        if (self.need_select_first) {
            self.menu.select_down();
            self.need_select_first = false;
        }
        tui.need_render();
    } else if (try cbor.match(m.buf, .{
        "PRJ",
        "recent",
        tp.extract(&self.longest),
        tp.extract(&file_name),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
    })) {
        if (self.need_reset) self.reset_results();
        const indicator = if (self.buffer_manager) |bm| tui.get_file_state_indicator(bm, file_name) else "";
        try self.add_item(file_name, file_icon, file_color, indicator, null);
        self.do_resize();
        if (self.need_select_first) {
            self.menu.select_down();
            self.need_select_first = false;
        }
        tui.need_render();
    } else if (try cbor.match(m.buf, .{ "PRJ", "recent_done", tp.extract(&self.longest), tp.extract(&query), tp.extract(&self.total_files_in_project) })) {
        self.update_count_hint();
        self.query_pending = false;
        self.need_reset = true;
        if (!std.mem.eql(u8, self.inputbox.text.items, query))
            try self.start_query();
    } else if (try cbor.match(m.buf, .{ "PRJ", "open_done", tp.string, tp.extract(&self.longest), tp.extract(&self.total_files_in_project) })) {
        self.update_count_hint();
        self.query_pending = false;
        self.need_reset = true;
        try self.start_query();
    } else {
        self.logger.err("receive", tp.unexpected(m));
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var text: []const u8 = undefined;

    if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn reset_results(self: *Self) void {
    self.need_reset = false;
    self.menu.reset_items();
    self.menu.selected = null;
    self.need_select_first = true;
}

fn update_count_hint(self: *Self) void {
    self.inputbox.hint.clearRetainingCapacity();
    self.inputbox.hint.print(self.inputbox.allocator, "{d}/{d}", .{ self.total_items, self.total_files_in_project }) catch {};
}

fn start_query(self: *Self) MessageFilter.Error!void {
    self.total_items = 0;
    if (self.query_pending) return;
    self.query_pending = true;
    self.clear_restore_info();
    try project_manager.query_recent_files(max_recent_files, self.inputbox.text.items);
}

fn complete(self: *Self) !void {
    const pos = self.inputbox.text.items.len;
    const btn = self.menu.get_selected() orelse return;
    var iter = btn.opts.label;
    var file_path: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;

    if (std.mem.indexOfPos(u8, file_path, pos, &.{std.fs.path.sep})) |pos_| {
        self.inputbox.text.shrinkRetainingCapacity(0);
        try self.inputbox.text.appendSlice(self.allocator, file_path[0..@min(pos_ + 1, file_path.len)]);
    }

    self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
    return self.start_query();
}

fn delete_word(self: *Self) !void {
    if (std.mem.lastIndexOfAny(u8, self.inputbox.text.items, "/\\. -_")) |pos| {
        self.inputbox.text.shrinkRetainingCapacity(pos);
    } else {
        self.inputbox.text.shrinkRetainingCapacity(0);
    }
    self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
    return self.start_query();
}

fn delete_code_point(self: *Self) !void {
    if (self.inputbox.text.items.len > 0) {
        self.inputbox.text.shrinkRetainingCapacity(self.inputbox.text.items.len - tui.egc_last(self.inputbox.text.items).len);
        self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
    }
    return self.start_query();
}

fn insert_code_point(self: *Self, c: u32) !void {
    var buf: [6]u8 = undefined;
    const bytes = try input.ucs32_to_utf8(&[_]u32{c}, &buf);
    try self.inputbox.text.appendSlice(self.allocator, buf[0..bytes]);
    self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
    return self.start_query();
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    try self.inputbox.text.appendSlice(self.allocator, bytes);
    self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
    return self.start_query();
}

fn cmd(_: *Self, name_: []const u8, ctx: command.Context) tp.result {
    try command.executeName(name_, ctx);
}

fn msg(_: *Self, text: []const u8) tp.result {
    return tp.self_pid().send(.{ "log", "home", text });
}

fn cmd_async(_: *Self, name_: []const u8) tp.result {
    return tp.self_pid().send(.{ "cmd", name_ });
}

const Commands = command.Collection(cmds);
const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn palette_menu_down(self: *Self, _: Ctx) Result {
        self.menu.select_down();
    }
    pub const palette_menu_down_meta: Meta = .{};

    pub fn palette_menu_up(self: *Self, _: Ctx) Result {
        self.menu.select_up();
    }
    pub const palette_menu_up_meta: Meta = .{};

    pub fn palette_menu_pagedown(self: *Self, _: Ctx) Result {
        self.menu.select_last();
    }
    pub const palette_menu_pagedown_meta: Meta = .{};

    pub fn palette_menu_pageup(self: *Self, _: Ctx) Result {
        self.menu.select_first();
    }
    pub const palette_menu_pageup_meta: Meta = .{};

    pub fn palette_menu_bottom(self: *Self, _: Ctx) Result {
        self.menu.select_last();
    }
    pub const palette_menu_bottom_meta: Meta = .{};

    pub fn palette_menu_top(self: *Self, _: Ctx) Result {
        self.menu.select_first();
    }
    pub const palette_menu_top_meta: Meta = .{};

    pub fn palette_menu_complete(self: *Self, _: Ctx) Result {
        try self.complete();
    }
    pub const palette_menu_complete_meta: Meta = .{};

    pub fn palette_menu_activate(self: *Self, _: Ctx) Result {
        self.menu.activate_selected();
    }
    pub const palette_menu_activate_meta: Meta = .{};

    pub fn palette_menu_activate_alternate(self: *Self, _: Ctx) Result {
        self.split = .vertical;
        self.menu.activate_selected();
    }
    pub const palette_menu_activate_alternate_meta: Meta = .{};

    pub fn palette_menu_activate_quick(self: *Self, _: Ctx) Result {
        if (!self.quick_activate_enabled) return;
        if (self.menu.selected orelse 0 > 0) self.menu.activate_selected();
        self.quick_activate_enabled = false;
    }
    pub const palette_menu_activate_quick_meta: Meta = .{};

    pub fn palette_menu_cancel(self: *Self, _: Ctx) Result {
        self.save();
        try self.cmd("exit_overlay_mode", .{});
    }
    pub const palette_menu_cancel_meta: Meta = .{};

    pub fn overlay_delete_word_left(self: *Self, _: Ctx) Result {
        self.delete_word() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_delete_word_left_meta: Meta = .{ .description = "Delete word to the left" };

    pub fn overlay_delete_backwards(self: *Self, _: Ctx) Result {
        self.delete_code_point() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

    pub fn overlay_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidOpenRecentInsertCodePointArgument;
        self.insert_code_point(egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn overlay_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidOpenRecentInsertBytesArgument;
        self.insert_bytes(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn overlay_next_widget_style(self: *Self, _: Ctx) Result {
        tui.set_next_style(widget_type);
        self.do_resize();
        tui.need_render();
        try tui.save_config();
    }
    pub const overlay_next_widget_style_meta: Meta = .{};

    pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
        return overlay_insert_bytes(self, ctx);
    }
    pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
};
