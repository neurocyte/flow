const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const tp = @import("thespian");

const Plane = @import("renderer").Plane;

const Widget = @import("Widget.zig");
const Box = @import("Box.zig");

const Self = @This();

pub const Direction = Widget.Direction;
pub const Layout = Widget.Layout;

const WidgetState = struct {
    widget: Widget,
    layout: Layout = .dynamic,
};

plane: Plane,
parent: Plane,
allocator: Allocator,
widgets: ArrayList(WidgetState),
layout_: Layout,
direction: Direction,
box: ?Widget.Box = null,
ctx: ?*anyopaque = null,
on_render: *const fn (ctx: ?*anyopaque, theme: *const Widget.Theme) void = on_render_default,
after_render: *const fn (ctx: ?*anyopaque, theme: *const Widget.Theme) void = on_render_default,
on_resize: *const fn (ctx: ?*anyopaque, self: *Self, pos_: Widget.Box) void = on_resize_default,

pub fn createH(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout) !*Self {
    const self: *Self = try allocator.create(Self);
    self.* = try init(allocator, parent, name, .horizontal, layout_, Box{});
    self.plane.hide();
    return self;
}

pub fn createV(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout) !*Self {
    const self: *Self = try allocator.create(Self);
    self.* = try init(allocator, parent, name, .vertical, layout_, Box{});
    self.plane.hide();
    return self;
}

pub fn createBox(allocator: Allocator, parent: Plane, name: [:0]const u8, dir: Direction, layout_: Layout, box: Box) !*Self {
    const self: *Self = try allocator.create(Self);
    self.* = try init(allocator, parent, name, dir, layout_, box);
    self.plane.hide();
    return self;
}

fn init(allocator: Allocator, parent: Plane, name: [:0]const u8, dir: Direction, layout_: Layout, box: Box) !Self {
    return .{
        .plane = try Plane.init(&box.opts(name), parent),
        .parent = parent,
        .allocator = allocator,
        .widgets = ArrayList(WidgetState).init(allocator),
        .layout_ = layout_,
        .direction = dir,
    };
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return self.layout_;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.allocator);
    self.widgets.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn add(self: *Self, w_: Widget) !void {
    _ = try self.addP(w_);
}

pub fn addP(self: *Self, w_: Widget) !*Widget {
    var w: *WidgetState = try self.widgets.addOne();
    w.* = .{
        .widget = w_,
        .layout = w_.layout(),
    };
    return &w.widget;
}

pub fn remove(self: *Self, w: Widget) void {
    for (self.widgets.items, 0..) |p, i| if (p.widget.ptr == w.ptr)
        self.widgets.orderedRemove(i).widget.deinit(self.allocator);
}

pub fn remove_all(self: *Self) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.allocator);
    self.widgets.clearRetainingCapacity();
}

pub fn pop(self: *Self) ?Widget {
    return if (self.widgets.popOrNull()) |ws| ws.widget else null;
}

pub fn empty(self: *const Self) bool {
    return self.widgets.items.len == 0;
}

pub fn swap(self: *Self, n: usize, w: Widget) Widget {
    const old = self.widgets.items[n];
    self.widgets.items[n].widget = w;
    self.widgets.items[n].layout = w.layout();
    return old.widget;
}

pub fn delete(self: *Self, n: usize) void {
    self.widgets.orderedRemove(n).widget.deinit(self.allocator);
}

pub fn replace(self: *Self, n: usize, w: Widget) void {
    const old = self.swap(n, w);
    old.deinit(self.allocator);
}

pub fn send(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    for (self.widgets.items) |*w|
        if (try w.widget.send(from, m))
            return true;
    return false;
}

pub fn update(self: *Self) void {
    for (self.widgets.items) |*w|
        w.widget.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    for (self.widgets.items) |*w| if (!w.layout.eql(w.widget.layout())) {
        self.refresh_layout();
        break;
    };

    self.on_render(self.ctx, theme);

    var more = false;
    for (self.widgets.items) |*w|
        if (w.widget.render(theme)) {
            more = true;
        };

    self.after_render(self.ctx, theme);
    return more;
}

fn on_render_default(_: ?*anyopaque, _: *const Widget.Theme) void {}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "H", tp.more }))
        return false;

    for (self.widgets.items) |*w|
        if (try w.widget.send(from_, m))
            return true;
    return false;
}

fn get_size_a(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.h,
        .horizontal => &pos.w,
    };
}

fn get_size_b(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.w,
        .horizontal => &pos.h,
    };
}

fn get_loc_a(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.y,
        .horizontal => &pos.x,
    };
}

fn get_loc_b(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.x,
        .horizontal => &pos.y,
    };
}

fn refresh_layout(self: *Self) void {
    return if (self.box) |box| self.handle_resize(box);
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.on_resize(self.ctx, self, pos);
}

fn on_resize_default(_: ?*anyopaque, self: *Self, pos: Widget.Box) void {
    self.resize(pos);
}

pub fn resize(self: *Self, pos_: Widget.Box) void {
    self.box = pos_;
    var pos = pos_;
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    const total = self.get_size_a(&pos).*;
    var avail = total;
    var statics: usize = 0;
    var dynamics: usize = 0;
    for (self.widgets.items) |*w| {
        w.layout = w.widget.layout();
        switch (w.layout) {
            .dynamic => {
                dynamics += 1;
            },
            .static => |val| {
                statics += 1;
                avail = if (avail > val) avail - val else 0;
            },
        }
    }

    const dyn_size = avail / if (dynamics > 0) dynamics else 1;
    const rounded: usize = if (dyn_size * dynamics < avail) avail - dyn_size * dynamics else 0;
    var cur_loc: usize = self.get_loc_a(&pos).*;
    var first = true;

    for (self.widgets.items) |*w| {
        var w_pos: Box = .{};
        const size = switch (w.layout) {
            .dynamic => if (first) val: {
                first = false;
                break :val dyn_size + rounded;
            } else dyn_size,
            .static => |val| val,
        };
        self.get_size_a(&w_pos).* = size;
        self.get_loc_a(&w_pos).* = cur_loc;
        cur_loc += size;

        self.get_size_b(&w_pos).* = self.get_size_b(&pos).*;
        self.get_loc_b(&w_pos).* = self.get_loc_b(&pos).*;
        w.widget.resize(w_pos);
    }
}

pub fn get(self: *Self, name_: []const u8) ?*Widget {
    for (self.widgets.items) |*w|
        if (w.widget.get(name_)) |p|
            return p;
    return null;
}

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, self_w: *Widget) bool {
    for (self.widgets.items) |*w|
        if (w.widget.walk(ctx, f)) return true;
    return f(ctx, self_w);
}

pub fn hover(self: *Self) bool {
    for (self.widgets.items) |*w| if (w.widget.hover()) return true;
    return false;
}
