const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const root = @import("root");

const Plane = @import("renderer").Plane;
const input = @import("input");
const keybind = @import("keybind");
const project_manager = @import("project_manager");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
const Button = @import("../../Button.zig");
const InputBox = @import("../../InputBox.zig");
const Menu = @import("../../Menu.zig");
const Widget = @import("../../Widget.zig");
const mainview = @import("../../mainview.zig");
const ModalBackground = @import("../../ModalBackground.zig");

const Self = @This();
const max_recent_files: usize = 25;

allocator: std.mem.Allocator,
f: usize = 0,
modal: *ModalBackground.State(*Self),
menu: *Menu.State(*Self),
inputbox: *InputBox.State(*Self),
logger: log.Logger,
query_pending: bool = false,
need_reset: bool = false,
need_select_first: bool = true,
longest: usize = 0,
commands: Commands = undefined,

pub fn create(allocator: std.mem.Allocator) !tui.Mode {
    const mv = tui.current().mainview.dynamic_cast(mainview) orelse return error.NotFound;
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .modal = try ModalBackground.create(*Self, allocator, tui.current().mainview, .{ .ctx = self }),
        .menu = try Menu.create(*Self, allocator, tui.current().mainview, .{
            .ctx = self,
            .on_render = on_render_menu,
            .on_resize = on_resize_menu,
        }),
        .logger = log.logger(@typeName(Self)),
        .inputbox = (try self.menu.add_header(try InputBox.create(*Self, self.allocator, self.menu.menu.parent, .{
            .ctx = self,
            .label = "Search files by name",
        }))).dynamic_cast(InputBox.State(*Self)) orelse unreachable,
    };
    try self.commands.init(self);
    try tui.current().message_filters.add(MessageFilter.bind(self, receive_project_manager));
    self.query_pending = true;
    try project_manager.request_recent_files(max_recent_files);
    self.menu.resize(.{ .y = 0, .x = self.menu_pos_x(), .w = max_menu_width() + 2 });
    try mv.floating_views.add(self.modal.widget());
    try mv.floating_views.add(self.menu.container_widget);
    return .{
        .input_handler = try keybind.mode.overlay.palette.create(allocator, .{
            .insert_command = "overlay_insert_bytes",
        }),
        .event_handler = EventHandler.to_owned(self),
        .name = "󰈞 open recent",
    };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    tui.current().message_filters.remove_ptr(self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv| {
        mv.floating_views.remove(self.menu.container_widget);
        mv.floating_views.remove(self.modal.widget());
    }
    self.logger.deinit();
    self.allocator.destroy(self);
}

inline fn menu_width(self: *Self) usize {
    return @min(self.longest, max_menu_width()) + 2;
}

inline fn menu_pos_x(self: *Self) usize {
    const screen_width = tui.current().screen().w;
    const width = self.menu_width();
    return if (screen_width <= width) 0 else (screen_width - width) / 2;
}

inline fn max_menu_width() usize {
    const width = tui.current().screen().w;
    return @max(15, width - (width / 5));
}

fn on_render_menu(_: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = theme.editor_widget;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_base;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        _ = button.plane.fill_width(" ", .{}) catch {};
        button.plane.home();
    }
    var file_path: []const u8 = undefined;
    var iter = button.opts.label; // label contains cbor, first the file name, then multiple match indexes
    if (!(cbor.matchString(&iter, &file_path) catch false))
        file_path = "#ERROR#";
    button.plane.set_style(style_keybind);
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}", .{pointer}) catch {};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var removed_prefix: usize = 0;
    const max_len = max_menu_width() - 2;
    button.plane.set_style(style_label);
    _ = button.plane.print("{s} ", .{
        if (file_path.len > max_len) root.shorten_path(&buf, file_path, &removed_prefix, max_len) else file_path,
    }) catch {};
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            const cell_idx = if (index < removed_prefix) 1 else index + 1 - removed_prefix;
            render_cell(&button.plane, 0, cell_idx, theme.editor_match) catch break;
        } else break;
    }
    return false;
}

fn render_cell(plane: *Plane, y: usize, x: usize, style: Widget.Theme.Style) !void {
    plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    cell.set_style(style);
    _ = plane.putc(&cell) catch {};
}

fn on_resize_menu(self: *Self, _: *Menu.State(*Self), _: Widget.Box) void {
    self.menu.resize(.{ .y = 0, .x = self.menu_pos_x(), .w = self.menu_width() });
}

fn menu_action_open_file(menu: **Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
    var file_path: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &file_path) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
}

fn add_item(self: *Self, file_name: []const u8, matches: ?[]const u8) !void {
    var label = std.ArrayList(u8).init(self.allocator);
    defer label.deinit();
    const writer = label.writer();
    try cbor.writeValue(writer, file_name);
    if (matches) |cb| _ = try writer.write(cb);
    try self.menu.add_item_with_handler(label.items, menu_action_open_file);
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
    var matches: []const u8 = undefined;
    var query: []const u8 = undefined;
    if (try cbor.match(m.buf, .{ "PRJ", "recent", tp.extract(&self.longest), tp.extract(&file_name), tp.extract_cbor(&matches) })) {
        if (self.need_reset) self.reset_results();
        try self.add_item(file_name, matches);
        self.menu.resize(.{ .y = 0, .x = self.menu_pos_x(), .w = self.menu_width() });
        if (self.need_select_first) {
            self.menu.select_down();
            self.need_select_first = false;
        }
        tui.need_render();
    } else if (try cbor.match(m.buf, .{ "PRJ", "recent", tp.extract(&self.longest), tp.extract(&file_name) })) {
        if (self.need_reset) self.reset_results();
        try self.add_item(file_name, null);
        self.menu.resize(.{ .y = 0, .x = self.menu_pos_x(), .w = self.menu_width() });
        if (self.need_select_first) {
            self.menu.select_down();
            self.need_select_first = false;
        }
        tui.need_render();
    } else if (try cbor.match(m.buf, .{ "PRJ", "recent_done", tp.extract(&self.longest), tp.extract(&query) })) {
        self.query_pending = false;
        self.need_reset = true;
        if (!std.mem.eql(u8, self.inputbox.text.items, query))
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

fn start_query(self: *Self) MessageFilter.Error!void {
    if (self.query_pending) return;
    self.query_pending = true;
    try project_manager.query_recent_files(max_recent_files, self.inputbox.text.items);
}

fn delete_word(self: *Self) !void {
    if (std.mem.lastIndexOfAny(u8, self.inputbox.text.items, "/\\. -_")) |pos| {
        self.inputbox.text.shrinkRetainingCapacity(pos);
    } else {
        self.inputbox.text.shrinkRetainingCapacity(0);
    }
    self.inputbox.cursor = self.inputbox.text.items.len;
    return self.start_query();
}

fn delete_code_point(self: *Self) !void {
    if (self.inputbox.text.items.len > 0) {
        self.inputbox.text.shrinkRetainingCapacity(self.inputbox.text.items.len - 1);
        self.inputbox.cursor = self.inputbox.text.items.len;
    }
    return self.start_query();
}

fn insert_code_point(self: *Self, c: u32) !void {
    var buf: [6]u8 = undefined;
    const bytes = try input.ucs32_to_utf8(&[_]u32{c}, &buf);
    try self.inputbox.text.appendSlice(buf[0..bytes]);
    self.inputbox.cursor = self.inputbox.text.items.len;
    return self.start_query();
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    try self.inputbox.text.appendSlice(bytes);
    self.inputbox.cursor = self.inputbox.text.items.len;
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
    const Result = command.Result;

    pub fn palette_menu_down(self: *Self, _: Ctx) Result {
        self.menu.select_down();
    }
    pub const palette_menu_down_meta = .{ .interactive = false };

    pub fn palette_menu_up(self: *Self, _: Ctx) Result {
        self.menu.select_up();
    }
    pub const palette_menu_up_meta = .{ .interactive = false };

    pub fn palette_menu_activate(self: *Self, _: Ctx) Result {
        self.menu.activate_selected();
    }
    pub const palette_menu_activate_meta = .{ .interactive = false };

    pub fn palette_menu_cancel(self: *Self, _: Ctx) Result {
        try self.cmd("exit_overlay_mode", .{});
    }
    pub const palette_menu_cancel_meta = .{ .interactive = false };

    pub fn overlay_delete_word_left(self: *Self, _: Ctx) Result {
        self.delete_word() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_delete_word_left_meta = .{ .description = "Delete word to the left" };

    pub fn overlay_delete_backwards(self: *Self, _: Ctx) Result {
        self.delete_code_point() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_delete_backwards_meta = .{ .description = "Delete backwards" };

    pub fn overlay_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidArgument;
        self.insert_code_point(egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_insert_code_point_meta = .{ .interactive = false };

    pub fn overlay_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidArgument;
        self.insert_bytes(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const overlay_insert_bytes_meta = .{ .interactive = false };

    pub fn overlay_release_control(self: *Self, _: Ctx) Result {
        if (self.menu.selected orelse 0 > 0) return self.cmd("palette_menu_activate", .{});
    }
    pub const overlay_release_control_meta = .{ .interactive = false };

    pub fn overlay_toggle_panel(self: *Self, _: Ctx) Result {
        return self.cmd_async("toggle_panel");
    }
    pub const overlay_toggle_panel_meta = .{ .interactive = false };

    pub fn overlay_toggle_inputview(self: *Self, _: Ctx) Result {
        return self.cmd_async("toggle_inputview");
    }
    pub const overlay_toggle_inputview_meta = .{ .interactive = false };
};
