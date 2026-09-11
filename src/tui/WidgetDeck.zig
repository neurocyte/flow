const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

allocator: Allocator,
plane: Plane,
widgets: std.ArrayList(Widget) = .empty,
active_: ?usize = null,
widget_type: Widget.Type,
deco_box: Widget.Box = .{},
sized: bool = false,

pub fn create(allocator: Allocator, parent: Plane, name: [:0]const u8, widget_type: Widget.Type) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .widget_type = widget_type,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (self.widgets.items) |w| w.deinit(self.allocator);
    self.widgets.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn count(self: *const Self) usize {
    return self.widgets.items.len;
}

pub fn get_at(self: *const Self, n: usize) ?Widget {
    return if (n < self.widgets.items.len) self.widgets.items[n] else null;
}

pub fn active_index(self: *const Self) ?usize {
    return self.active_;
}

pub fn active(self: *const Self) ?Widget {
    return if (self.active_) |n| self.get_at(n) else null;
}

pub fn add(self: *Self, w: Widget) error{OutOfMemory}!void {
    return self.insert(self.widgets.items.len, w);
}

pub fn insert(self: *Self, n: usize, w: Widget) error{OutOfMemory}!void {
    try self.widgets.insert(self.allocator, n, w);
    if (self.active_) |a| if (a >= n) {
        self.active_ = a + 1;
    };
    if (self.sized) self.resize_child(w);
}

pub fn remove(self: *Self, n: usize) void {
    if (self.detach(n)) |w| w.deinit(self.allocator);
}

pub fn detach(self: *Self, n: usize) ?Widget {
    if (n >= self.widgets.items.len) return null;
    const w = self.widgets.orderedRemove(n);
    if (self.active_) |a| {
        if (a == n) {
            self.active_ = if (self.widgets.items.len == 0) null else @min(n, self.widgets.items.len - 1);
            send_hover(w, false);
        } else if (a > n) self.active_ = a - 1;
    }
    tui.need_render(@src());
    return w; // ownership passed to caller
}

pub fn set_active(self: *Self, n: usize) void {
    if (n >= self.widgets.items.len) return;
    if (self.active_) |a| if (a == n) return;
    if (self.active()) |prev| send_hover(prev, false);
    self.active_ = n;
    tui.refresh_hover(@src());
    tui.need_render(@src());
}

fn send_hover(w: Widget, hover: bool) void {
    _ = w.msg(.{ "H", hover }) catch {};
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const widget_style = tui.get_widget_style(self.widget_type);
    widget_style.render_decoration(self.deco_box, self.widget_type, &self.plane, theme);
    const w = self.active() orelse return false;
    return w.render(theme);
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "H", tp.more }))
        return false;
    const w = self.active() orelse return false;
    return w.send(from, m);
}

pub fn update(self: *Self) void {
    for (self.widgets.items) |w| w.update();
}

pub fn handle_resize(self: *Self, box: Widget.Box) void {
    self.deco_box = box;
    self.sized = true;
    self.plane.move_yx(@intCast(box.y), @intCast(box.x)) catch return;
    self.plane.resize_simple(@intCast(box.h), @intCast(box.w)) catch return;
    for (self.widgets.items) |w| self.resize_child(w);
}

fn client_box(self: *const Self) Widget.Box {
    const padding = tui.get_widget_style(self.widget_type).padding;
    var box = self.deco_box.to_client_box(padding);
    if (self.deco_box.frame.is_set()) {
        const cw: i32 = self.plane.cell_x();
        const ch: i32 = self.plane.cell_y();
        box.frame = self.deco_box.frame.inset(
            @as(i32, padding.left) * cw,
            @as(i32, padding.top) * ch,
            @as(i32, padding.right) * cw,
            @as(i32, padding.bottom) * ch,
        );
    }
    return box;
}

fn resize_child(self: *Self, w: Widget) void {
    w.plane.layer = self.plane.layer;
    w.plane.window.screen = self.plane.window.screen;
    w.resize(self.client_box());
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (f(walk_ctx, Widget.to(self), .begin)) return true;
    if (self.active()) |w| if (w.walk(walk_ctx, f)) return true;
    return f(walk_ctx, Widget.to(self), .end);
}

pub fn focus(self: *Self) void {
    if (self.active()) |w| w.focus();
}

pub fn unfocus(self: *Self) void {
    if (self.active()) |w| w.unfocus();
}
