const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;

const tp = @import("thespian");
const Widget = @import("Widget.zig");

const Self = @This();

allocator: Allocator,
widgets: ArrayList(Widget),

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .widgets = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.widgets.items) |*widget|
        widget.deinit(self.allocator);
    self.widgets.deinit(self.allocator);
}

pub fn add(self: *Self, widget: Widget) !void {
    (try self.widgets.addOne(self.allocator)).* = widget;
}

pub fn swap(self: *Self, n: usize, widget: Widget) Widget {
    const old = self.widgets.items[n];
    self.widgets.items[n] = widget;
    return old;
}

pub fn replace(self: *Self, n: usize, widget: Widget) void {
    const old = self.swapWidget(n, widget);
    old.deinit(self.a);
}

pub fn remove(self: *Self, w: Widget) void {
    for (self.widgets.items, 0..) |p, i| if (p.ptr == w.ptr)
        self.widgets.orderedRemove(i).deinit(self.allocator);
}

pub fn delete(self: *Self, name: []const u8) bool {
    for (self.widgets.items, 0..) |*widget, i| {
        var buf: [64]u8 = undefined;
        const wname = widget.name(&buf);
        if (eql(u8, wname, name)) {
            self.widgets.orderedRemove(i).deinit(self.a);
            return true;
        }
    }
    return false;
}

pub fn find(self: *Self, name: []const u8) ?*Widget {
    for (self.widgets.items) |*widget| {
        var buf: [64]u8 = undefined;
        const wname = widget.name(&buf);
        if (eql(u8, wname, name))
            return widget;
    }
    return null;
}

pub fn send(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    for (self.widgets.items) |*widget|
        if (try widget.send(from, m))
            return true;
    return false;
}

pub fn update(self: *Self) void {
    for (self.widgets.items) |*widget| widget.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    var more = false;
    for (self.widgets.items) |*widget|
        if (widget.render(theme)) {
            more = true;
        };
    return more;
}

pub fn resize(self: *Self, pos: Widget.Box) void {
    for (self.widgets.items) |*widget|
        widget.resize(pos);
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    const len = self.widgets.items.len;
    for (0..len) |i| {
        const n = len - i - 1;
        const w = &self.widgets.items[n];
        if (w.walk(walk_ctx, f)) return true;
    }
    return false;
}
