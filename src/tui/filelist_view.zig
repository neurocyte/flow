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

const command = @import("command.zig");
const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");
const Menu = @import("Menu.zig");
const EventHandler = @import("EventHandler.zig");
const Button = @import("Button.zig");

const escape = fmt.fmtSliceEscapeLower;

pub const name = @typeName(Self);

const Self = @This();
const Commands = command.Collection(cmds);

allocator: std.mem.Allocator,
plane: Plane,
menu: *Menu.State(*Self),
logger: log.Logger,
commands: Commands = undefined,

items: usize = 0,
view_pos: usize = 0,
view_rows: usize = 0,
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
            .on_scroll = EventHandler.bind(self, Self.handle_scroll),
        }),
    };
    try self.commands.init(self);
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    self.commands.deinit();
    a.destroy(self);
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.menu.resize(pos);
    self.view_rows = pos.h;
    self.update_scrollbar();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.menu.walk(walk_ctx, f) or f(walk_ctx, w);
}

pub fn add_item(self: *Self, entry_: Entry) !void {
    const idx = self.entries.items.len;
    const entry = (try self.entries.addOne());
    entry.* = entry_;
    entry.path = try self.allocator.dupe(u8, entry_.path);
    entry.lines = try self.allocator.dupe(u8, entry_.lines);
    var label = std.ArrayList(u8).init(self.allocator);
    defer label.deinit();
    const writer = label.writer();
    cbor.writeValue(writer, idx) catch return;
    self.menu.add_item_with_handler(label.items, handle_menu_action) catch return;
    self.menu.resize(Widget.Box.from(self.plane));
    self.update_scrollbar();
}

pub fn reset(self: *Self) void {
    for (self.entries.items) |entry| {
        self.allocator.free(entry.path);
        self.allocator.free(entry.lines);
    }
    self.entries.clearRetainingCapacity();
    self.menu.reset_items();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(" ", theme.panel);
    self.plane.erase();
    self.plane.home();
    return self.menu.render(theme);
}

fn handle_render_menu(self: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.panel;
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
        return false;
    }
    const entry = &self.entries.items[idx];
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s} ", .{pointer}) catch {};
    button.plane.set_style(style_base);
    _ = button.plane.print("{s}:{d}    {s}", .{ entry.path, entry.begin_line + 1, entry.lines }) catch {};
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

fn update_scrollbar(self: *Self) void {
    self.menu.scrollbar.?.set(@intCast(self.entries.items.len), @intCast(self.view_rows), @intCast(self.view_pos));
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
            entry.end_line + 1,
            entry.end_pos + 2,
            entry.begin_line,
            entry.begin_pos + 1,
            entry.end_line,
            entry.end_pos + 1,
        },
    } }) catch |e| self.logger.err("navigate", e);
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn goto_prev_file(self: *Self, _: Ctx) Result {
        self.menu.select_up();
        self.menu.activate_selected();
    }

    pub fn goto_next_file(self: *Self, _: Ctx) Result {
        self.menu.select_down();
        self.menu.activate_selected();
    }
};
