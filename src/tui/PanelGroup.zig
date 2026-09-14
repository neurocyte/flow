const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const WidgetDeck = @import("WidgetDeck.zig");
const TabStrip = @import("TabStrip.zig");
const Tabs = @import("status/tabs.zig");
const Panel = @import("Panel.zig");

const Self = @This();

pub const Direction = enum { next, previous };

allocator: Allocator,
list: *WidgetList,
strip: TabStrip,
deck: *WidgetDeck,
panels: std.ArrayList(Panel) = .empty,
on_focus: ?Callback = null,
on_activate: ?Callback = null,

pub const Callback = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, group: *Self) void,
};

pub fn create(allocator: Allocator, parent: Plane, widget_type: Widget.Type, style: *const Tabs.Style) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const list = try WidgetList.createV(allocator, parent, "panel_group", .dynamic);
    errdefer list.deinit(allocator);

    const deck = try WidgetDeck.create(allocator, list.plane, "panel_deck", widget_type);
    errdefer deck.deinit(allocator);

    self.* = .{
        .allocator = allocator,
        .list = list,
        .strip = undefined,
        .deck = deck,
    };
    try self.strip.init(allocator, list.plane, style, .{
        .ctx = self,
        .count = strip_count,
        .info = strip_info,
        .focused = strip_focused,
        .on_select = strip_select,
        .on_close = strip_close,
    });
    errdefer self.strip.widget().deinit(allocator);

    try list.add(self.strip.widget());
    try list.add(deck.widget());
    list.ctx = self;
    list.on_render = on_render;
    list.on_deinit = on_deinit;
    return self;
}

pub fn widget(self: *Self) Widget {
    return self.list.widget();
}

pub fn panel_parent(self: *Self) Plane {
    return self.deck.plane;
}

fn on_deinit(ctx: ?*anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    self.panels.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn on_render(ctx: ?*anyopaque, _: *const Widget.Theme) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    self.strip.sync();
    if (self.is_focused()) if (self.on_focus) |cb| cb.f(cb.ctx, self);
}

pub fn count(self: *const Self) usize {
    return self.panels.items.len;
}

pub fn empty(self: *const Self) bool {
    return self.panels.items.len == 0;
}

pub fn get_at(self: *const Self, n: usize) ?Panel {
    return if (n < self.panels.items.len) self.panels.items[n] else null;
}

pub fn index_of(self: *const Self, id: Panel.Id) ?usize {
    for (self.panels.items, 0..) |p, i| if (p.id == id) return i;
    return null;
}

pub fn find(self: *const Self, id: Panel.Id) ?Panel {
    return self.get_at(self.index_of(id) orelse return null);
}

pub fn active(self: *const Self) ?Panel {
    return self.get_at(self.deck.active_index() orelse return null);
}

pub fn is_active(self: *const Self, id: Panel.Id) bool {
    return if (self.active()) |p| p.id == id else false;
}

pub fn is_focused(self: *const Self) bool {
    const p = self.active() orelse return false;
    return tui.is_keyboard_focus(p.widget);
}

fn singleton_count(self: *const Self) usize {
    var n: usize = 0;
    for (self.panels.items) |p| if (p.singleton()) {
        n += 1;
    };
    return n;
}

pub fn add(self: *Self, panel: Panel, activate_: bool) error{OutOfMemory}!void {
    const n = if (panel.singleton()) self.singleton_count() else self.panels.items.len;
    try self.panels.insert(self.allocator, n, panel);
    errdefer _ = self.panels.orderedRemove(n);
    try self.deck.insert(n, panel.widget);
    if (activate_ or self.deck.active_index() == null) self.set_active(n);
}

pub fn activate(self: *Self, id: Panel.Id) void {
    self.set_active(self.index_of(id) orelse return);
}

fn set_active(self: *Self, n: usize) void {
    self.deck.set_active(n);
    self.notify_active();
}

fn notify_active(self: *Self) void {
    if (self.active() == null) return;
    if (self.on_activate) |cb| cb.f(cb.ctx, self);
}

pub fn detach(self: *Self, id: Panel.Id) ?Panel {
    const n = self.index_of(id) orelse return null;
    const was_active = self.is_active(id);
    const panel = self.panels.orderedRemove(n);
    _ = self.deck.detach(n);
    if (was_active) self.notify_active();
    return panel; // ownership passes to the caller
}

pub fn remove(self: *Self, id: Panel.Id) void {
    const panel = self.detach(id) orelse return;
    const focused = tui.is_keyboard_focus(panel.widget);
    panel.widget.deinit(self.allocator);
    if (focused) tui.release_keyboard_focus(panel.widget);
}

fn strip_count(ctx: *anyopaque) usize {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.panels.items.len;
}

fn strip_info(ctx: *anyopaque, n: usize) TabStrip.TabInfo {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const p = self.panels.items[n];
    return .{
        .id = p.id,
        .label = p.title(),
        .icon = p.icon(),
        .active = self.deck.active_index() == n,
    };
}

fn strip_focused(ctx: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.is_focused();
}

fn strip_select(ctx: *anyopaque, id: TabStrip.Id) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.activate(id);
    if (self.active()) |p| if (p.id == id) p.widget.focus();
    tui.need_render(@src());
}

fn strip_close(_: *anyopaque, id: TabStrip.Id) void {
    tp.self_pid().send(.{ "cmd", "panel_tab_close", .{id} }) catch {};
}
