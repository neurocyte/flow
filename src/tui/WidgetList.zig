const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const tp = @import("thespian");

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
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
layout_empty: bool = true,
direction: Direction,
deco_box: Widget.Box,
ctx: ?*anyopaque = null,
on_render: *const fn (ctx: ?*anyopaque, theme: *const Widget.Theme) void = on_render_default,
render_decoration: ?*const fn (self: *Self, theme: *const Widget.Theme, widget_style: *const Widget.Style) void = render_decoration_default,
after_render: *const fn (ctx: ?*anyopaque, theme: *const Widget.Theme) void = on_render_default,
prepare_resize: *const fn (ctx: ?*anyopaque, self: *Self, box: Widget.Box) Widget.Box = prepare_resize_default,
after_resize: *const fn (ctx: ?*anyopaque, self: *Self, box: Widget.Box) void = after_resize_default,
on_layout: *const fn (ctx: ?*anyopaque, self: *Self) Widget.Layout = on_layout_default,
widget_type: Widget.Type,

pub fn createH(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout) error{OutOfMemory}!*Self {
    return createHStyled(allocator, parent, name, layout_, .none);
}

pub fn createHStyled(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout, widget_type: Widget.Type) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = try init(allocator, parent, name, .horizontal, layout_, Box{}, widget_type);
    self.plane.hide();
    return self;
}

pub fn createV(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout) !*Self {
    return createVStyled(allocator, parent, name, layout_, .none);
}

pub fn createVStyled(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout, widget_type: Widget.Type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = try init(allocator, parent, name, .vertical, layout_, Box{}, widget_type);
    self.plane.hide();
    return self;
}

pub fn createBox(allocator: Allocator, parent: Plane, name: [:0]const u8, dir: Direction, layout_: Layout, box: Box) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = try init(allocator, parent, name, dir, layout_, box);
    self.plane.hide();
    return self;
}

fn init(allocator: Allocator, parent: Plane, name: [:0]const u8, dir: Direction, layout_: Layout, box_: Box, widget_type: Widget.Type) !Self {
    var self: Self = .{
        .plane = undefined,
        .parent = parent,
        .allocator = allocator,
        .widgets = .empty,
        .layout_ = layout_,
        .direction = dir,
        .widget_type = widget_type,
        .deco_box = undefined,
    };
    const padding = tui.get_widget_style(self.widget_type).padding;
    self.deco_box = self.from_client_box(box_, padding);
    self.plane = try Plane.init(&self.deco_box.opts(name), parent);
    return self;
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return self.on_layout(self.ctx, self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.allocator);
    self.widgets.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn add(self: *Self, w_: Widget) !void {
    _ = try self.addP(w_);
}

pub fn addP(self: *Self, w_: Widget) !*Widget {
    var w: *WidgetState = try self.widgets.addOne(self.allocator);
    w.* = .{
        .widget = w_,
        .layout = w_.layout(),
    };
    return &w.widget;
}

pub fn get(self: *Self, name_: []const u8) ?*Widget {
    for (self.widgets.items) |*w|
        if (w.widget.get(name_)) |p|
            return p;
    return null;
}

pub fn get_at(self: *const Self, n: usize) ?*Widget {
    return if (n < self.widgets.items.len) &self.widgets.items[n].widget else null;
}

pub fn remove(self: *Self, w: Widget) void {
    for (self.widgets.items, 0..) |p, i| if (p.widget.ptr == w.ptr) {
        self.widgets.orderedRemove(i).widget.deinit(self.allocator);
        return;
    };
}

pub fn remove_all(self: *Self) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.allocator);
    self.widgets.clearRetainingCapacity();
}

pub fn pop(self: *Self) ?Widget {
    return if (self.widgets.pop()) |ws| ws.widget else null;
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
    const widget_style = tui.get_widget_style(self.widget_type);
    const padding = widget_style.padding;
    for (self.widgets.items) |*w| if (!w.layout.eql(w.widget.layout())) {
        self.refresh_layout(padding);
        break;
    };

    self.on_render(self.ctx, theme);
    if (self.render_decoration) |render_decoration| render_decoration(self, theme, widget_style);

    const client_box = self.to_client_box(self.deco_box, padding);

    var more = false;
    for (self.widgets.items) |*w| {
        const widget_box = w.widget.box();
        if (client_box.y + client_box.h <= widget_box.y) break;
        if (client_box.x + client_box.w <= widget_box.x) break;
        if (w.widget.render(theme)) {
            more = true;
        }
    }

    self.after_render(self.ctx, theme);
    return more;
}

fn on_render_default(_: ?*anyopaque, _: *const Widget.Theme) void {}

fn render_decoration_default(self: *Self, theme: *const Widget.Theme, widget_style: *const Widget.Style) void {
    const style = Widget.Style.theme_style_from_type(self.widget_type, theme);
    const padding = widget_style.padding;
    const border = widget_style.border;
    const plane = &self.plane;
    const box = self.deco_box;

    plane.set_style(style);
    plane.fill(" ");

    if (padding.top > 0 and padding.left > 0) put_at_pos(plane, 0, 0, border.nw);
    if (padding.top > 0 and padding.right > 0) put_at_pos(plane, 0, box.w - 1, border.ne);
    if (padding.bottom > 0 and padding.left > 0 and box.h > 0) put_at_pos(plane, box.h - 1, 0, border.sw);
    if (padding.bottom > 0 and padding.right > 0 and box.h > 0) put_at_pos(plane, box.h - 1, box.w - 1, border.se);

    {
        const start: usize = if (padding.left > 0) 1 else 0;
        const end: usize = if (padding.right > 0 and box.w > 0) box.w - 1 else box.w;
        if (padding.top > 0) for (start..end) |x| put_at_pos(plane, 0, x, border.n);
        if (padding.bottom > 0) for (start..end) |x| put_at_pos(plane, box.h - 1, x, border.s);
    }

    {
        const start: usize = if (padding.top > 0) 1 else 0;
        const end: usize = if (padding.bottom > 0 and box.h > 0) box.h - 1 else box.h;
        if (padding.left > 0) for (start..end) |y| put_at_pos(plane, y, 0, border.w);
        if (padding.right > 0) for (start..end) |y| put_at_pos(plane, y, box.w - 1, border.e);
    }
}

inline fn put_at_pos(plane: *Plane, y: usize, x: usize, egc: []const u8) void {
    plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
    plane.putchar(egc);
}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "H", tp.more }))
        return false;

    for (self.widgets.items) |*w|
        if (try w.widget.send(from_, m))
            return true;
    return false;
}

fn get_size_a_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.h,
        .horizontal => pos.w,
    };
}

fn get_size_a(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.h,
        .horizontal => &pos.w,
    };
}

fn get_size_b_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.w,
        .horizontal => pos.h,
    };
}

fn get_size_b(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.w,
        .horizontal => &pos.h,
    };
}

fn get_loc_a_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.y,
        .horizontal => pos.x,
    };
}

fn get_loc_a(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.y,
        .horizontal => &pos.x,
    };
}

fn get_loc_b_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.x,
        .horizontal => pos.y,
    };
}

fn get_loc_b(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.x,
        .horizontal => &pos.y,
    };
}

fn refresh_layout(self: *Self, padding: Widget.Style.Margin) void {
    return self.handle_resize(self.to_client_box(self.deco_box, padding));
}

pub fn handle_resize(self: *Self, box: Widget.Box) void {
    const padding = tui.get_widget_style(self.widget_type).padding;
    const client_box_ = self.prepare_resize(self.ctx, self, self.to_client_box(box, padding));
    self.deco_box = self.from_client_box(client_box_, padding);
    self.do_resize(padding);
    self.after_resize(self.ctx, self, self.to_client_box(self.deco_box, padding));
}

pub inline fn to_client_box(_: *const Self, box_: Widget.Box, padding: Widget.Style.Margin) Widget.Box {
    const total_y_padding = padding.top + padding.bottom;
    const total_x_padding = padding.left + padding.right;
    var box = box_;
    box.y += padding.top;
    box.h -= if (box.h > total_y_padding) total_y_padding else box.h;
    box.x += padding.left;
    box.w -= if (box.w > total_x_padding) total_x_padding else box.w;
    return box;
}

inline fn from_client_box(_: *const Self, box_: Widget.Box, padding: Widget.Style.Margin) Widget.Box {
    const total_y_padding = padding.top + padding.bottom;
    const total_x_padding = padding.left + padding.right;
    const y = if (box_.y < padding.top) padding.top else box_.y;
    const x = if (box_.x < padding.left) padding.left else box_.x;
    var box = box_;
    box.y = y - padding.top;
    box.h += total_y_padding;
    box.x = x - padding.left;
    box.w += total_x_padding;
    return box;
}

fn prepare_resize_default(_: ?*anyopaque, _: *Self, box: Widget.Box) Widget.Box {
    return box;
}

fn after_resize_default(_: ?*anyopaque, _: *Self, _: Widget.Box) void {}

fn on_layout_default(_: ?*anyopaque, self: *Self) Widget.Layout {
    return self.layout_;
}

pub fn resize(self: *Self, box: Widget.Box) void {
    return self.handle_resize(box);
}

fn do_resize(self: *Self, padding: Widget.Style.Margin) void {
    const client_box = self.to_client_box(self.deco_box, padding);
    const deco_box = self.deco_box;
    self.plane.move_yx(@intCast(deco_box.y), @intCast(deco_box.x)) catch return;
    self.plane.resize_simple(@intCast(deco_box.h), @intCast(deco_box.w)) catch return;
    const total = self.get_size_a_const(&client_box);
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
    self.layout_empty = avail == total and dynamics == 0;

    const dyn_size = avail / if (dynamics > 0) dynamics else 1;
    const rounded: usize = if (dyn_size * dynamics < avail) avail - dyn_size * dynamics else 0;
    var cur_loc: usize = self.get_loc_a_const(&client_box);
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

        self.get_size_b(&w_pos).* = self.get_size_b_const(&client_box);
        self.get_loc_b(&w_pos).* = self.get_loc_b_const(&client_box);
        w.widget.resize(w_pos);
    }
}

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, self_w: *Widget) bool {
    for (self.widgets.items) |*w|
        if (w.widget.walk(ctx, f)) return true;
    return f(ctx, self_w);
}

pub fn focus(self: *Self) void {
    for (self.widgets.items) |*w| w.widget.focus();
}

pub fn unfocus(self: *Self) void {
    for (self.widgets.items) |*w| w.widget.unfocus();
}

pub fn hover(self: *Self) bool {
    for (self.widgets.items) |*w| if (w.widget.hover()) return true;
    return false;
}
