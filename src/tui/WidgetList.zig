const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const nc = @import("notcurses");
const tp = @import("thespian");
const Widget = @import("Widget.zig");
const Box = @import("Box.zig");

const Self = @This();

pub const Direction = Widget.Direction;
pub const Layout = Widget.Layout;

const WidgetState = struct {
    widget: Widget,
    layout: Layout = .{},
};

plane: nc.Plane,
parent: nc.Plane,
a: Allocator,
widgets: ArrayList(WidgetState),
layout: Layout,
direction: Direction,
box: ?Widget.Box = null,

pub fn createH(a: Allocator, parent: Widget, name: [:0]const u8, layout_: Layout) !*Self {
    const self: *Self = try a.create(Self);
    self.* = try init(a, parent, name, .horizontal, layout_, Box{});
    self.plane.move_bottom();
    return self;
}

pub fn createV(a: Allocator, parent: Widget, name: [:0]const u8, layout_: Layout) !*Self {
    const self: *Self = try a.create(Self);
    self.* = try init(a, parent, name, .vertical, layout_, Box{});
    self.plane.move_bottom();
    return self;
}

pub fn createBox(a: Allocator, parent: Widget, name: [:0]const u8, dir: Direction, layout_: Layout, box: Box) !*Self {
    const self: *Self = try a.create(Self);
    self.* = try init(a, parent, name, dir, layout_, box);
    self.plane.move_bottom();
    return self;
}

fn init(a: Allocator, parent: Widget, name: [:0]const u8, dir: Direction, layout_: Layout, box: Box) !Self {
    return .{
        .plane = try nc.Plane.init(&box.opts(name), parent.plane.*),
        .parent = parent.plane.*,
        .a = a,
        .widgets = ArrayList(WidgetState).init(a),
        .layout = layout_,
        .direction = dir,
    };
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return self.layout;
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.a);
    self.widgets.deinit();
    self.plane.deinit();
    a.destroy(self);
}

pub fn add(self: *Self, w_: Widget) !void {
    _ = try self.addP(w_);
}

pub fn addP(self: *Self, w_: Widget) !*Widget {
    var w: *WidgetState = try self.widgets.addOne();
    w.widget = w_;
    w.layout = w_.layout();
    return &w.widget;
}

pub fn remove(self: *Self, w: Widget) void {
    for (self.widgets.items, 0..) |p, i| if (p.widget.ptr == w.ptr)
        self.widgets.orderedRemove(i).widget.deinit(self.a);
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

pub fn replace(self: *Self, n: usize, w: Widget) void {
    const old = self.swap(n, w);
    old.deinit(self.a);
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

    var more = false;
    for (self.widgets.items) |*w|
        if (w.widget.render(theme)) {
            more = true;
        };
    return more;
}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
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

pub fn resize(self: *Self, pos: Widget.Box) void {
    return self.handle_resize(pos);
}

fn refresh_layout(self: *Self) void {
    return if (self.box) |box| self.handle_resize(box);
}

pub fn handle_resize(self: *Self, pos_: Widget.Box) void {
    self.box = pos_;
    var pos = pos_;
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
