const std = @import("std");
const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;
const time = @import("std").time;
const cbor = @import("cbor");
const Allocator = @import("std").mem.Allocator;
const Mutex = @import("std").Thread.Mutex;
const ArrayList = @import("std").ArrayList;
const Plane = @import("renderer").Plane;

const tp = @import("thespian");
const log = @import("log");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");
const Menu = @import("Menu.zig");
const EventHandler = @import("EventHandler.zig");
const Button = @import("Button.zig");

const escape = fmt.fmtSliceEscapeLower;

pub const name = @typeName(Self);

const Self = @This();

allocator: std.mem.Allocator,
plane: Plane,
menu: *Menu.State(*Self),
logger: log.Logger,

items: usize = 0,
view_pos: usize = 0,
total_items: usize = 0,
entries: std.ArrayList(Entry) = undefined,

const Entry = struct {
    path: []const u8,
    begin_line: usize,
    begin_pos: usize,
    end_line: usize,
    end_pos: usize,
    lines: []const u8,
};

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .logger = log.logger(@typeName(Self)),
        .entries = std.ArrayList(Entry).init(allocator),
        .menu = try Menu.create(*Self, allocator, tui.current().mainview, .{
            .ctx = self,
            .on_render = handle_render_menu,
            // .on_resize = on_resize_menu,
            .on_scroll = EventHandler.bind(self, Self.handle_scroll),
        }),
    };
    (try self.entries.addOne()).* = .{ .path = "file_path_1.zig", .begin_line = 1, .begin_pos = 1, .end_line = 1, .end_pos = 10, .lines = "matching text" };
    (try self.entries.addOne()).* = .{ .path = "file_path_2.zig", .begin_line = 1, .begin_pos = 1, .end_line = 1, .end_pos = 10, .lines = "matching text" };
    (try self.entries.addOne()).* = .{ .path = "file_path_3.zig", .begin_line = 1, .begin_pos = 1, .end_line = 1, .end_pos = 10, .lines = "matching text" };
    try self.add_item(0);
    try self.add_item(1);
    try self.add_item(2);
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    a.destroy(self);
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.menu.resize(pos);
}

fn add_item(self: *Self, idx: usize) !void {
    var label = std.ArrayList(u8).init(self.allocator);
    defer label.deinit();
    const writer = label.writer();
    try cbor.writeValue(writer, idx);
    try self.menu.add_item_with_handler(label.items, handle_menu_action);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    return self.menu.render(theme);
}

fn handle_render_menu(self: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    // const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_base;
    button.plane.set_base_style(" ", style_base);
    button.plane.erase();
    button.plane.home();
    var idx: usize = undefined;
    var iter = button.opts.label; // label contains cbor, just the index
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch false)) {
        const json = cbor.toJsonAlloc(self.allocator, iter) catch return false;
        defer self.allocator.free(json);
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return false;
    }
    if (idx >= self.entries.items.len) {
        self.logger.print_err(name, "table entry index out of range: {d}/{d}", .{ idx, self.entries.items.len });
        return false;
    }
    const entry = &self.entries.items[idx];
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s} ", .{pointer}) catch {};
    button.plane.set_style(style_base);
    _ = button.plane.print("{s} ", .{entry.path}) catch {};
    return false;
}

fn render_cell(plane: *Plane, y: usize, x: usize, style: Widget.Theme.Style) !void {
    plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    cell.set_style(style);
    _ = plane.putc(&cell) catch {};
}

fn handle_scroll(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!void {
    _ = try m.match(.{ "scroll_to", tp.extract(&self.view_pos) });
}

fn handle_menu_action(menu: **Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
    const self = menu.*.opts.ctx;
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch return)) {
        const json = cbor.toJsonAlloc(self.allocator, button.opts.label) catch return;
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return;
    }
    if (idx >= self.entries.items.len) {
        self.logger.print_err(name, "table entry index out of range: {d}/{d}", .{ idx, self.entries.items.len });
        return;
    }
    const entry = &self.entries.items[idx];

    tp.self_pid().send(.{ "cmd", "navigate", .{
        .file = entry.path,
        .goto = .{
            entry.begin_line,
            entry.begin_pos,
            entry.begin_line,
            entry.begin_pos,
            entry.end_line,
            entry.end_pos,
        },
    } }) catch |e| self.logger.err("navigate", e);
}
