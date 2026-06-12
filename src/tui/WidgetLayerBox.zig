const std = @import("std");
const Allocator = std.mem.Allocator;

const tp = @import("thespian");

const renderer = @import("renderer");
const Plane = renderer.Plane;
const Layer = renderer.Layer;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

allocator: Allocator,
plane: Plane,
parent: Plane,
layer: *Layer,
inner: ?Widget = null,
box: Widget.Box = .{},
ctx: ?*anyopaque = null,
prepare_resize: ?*const fn (ctx: ?*anyopaque, self: *Self, box: Widget.Box) Widget.Box = null,
alpha: u8 = 0xFF,
z_index: Layer.Level = .overlay,
blend: Layer.Target.Blend = .default,

pub fn create(allocator: Allocator, parent: Plane, name: [:0]const u8) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const layer = try Layer.init(allocator, .{ .h = 1, .w = 1 });
    errdefer layer.deinit();
    const plane = try Plane.init(&(Widget.Box{}).opts(name), parent);
    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .parent = parent,
        .layer = layer,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.inner) |*w| w.deinit(self.allocator);
    self.plane.deinit();
    self.layer.deinit();
    allocator.destroy(self);
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn inner_plane(self: *Self) Plane {
    return self.layer.plane();
}

pub fn set(self: *Self, w: Widget) void {
    std.debug.assert(self.inner == null);
    self.inner = w;
}

pub fn layout(self: *Self) Widget.Layout {
    return if (self.inner) |w| w.layout() else .dynamic;
}

pub fn handle_resize(self: *Self, box_in: Widget.Box) void {
    const box = if (self.prepare_resize) |prepare| prepare(self.ctx, self, box_in) else box_in;
    self.box = box;
    self.plane.move_yx(@intCast(box.y), @intCast(box.x)) catch return;
    self.plane.resize_simple(@intCast(box.h), @intCast(box.w)) catch return;

    const cw = self.plane.cell_x();
    const ch = self.plane.cell_y();
    const w_cells: u16 = @intCast(box.w);
    const h_cells: u16 = @intCast(box.h);
    self.layer.resize(w_cells, h_cells, w_cells * cw, h_cells * ch) catch return;

    const ox, const oy = self.plane.global_origin_px();
    self.layer.surface.origin_px_x = ox;
    self.layer.surface.origin_px_y = oy;

    if (self.inner) |*w|
        w.resize(.{ .y = 0, .x = 0, .w = box.w, .h = box.h });
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    var more = false;
    if (self.inner) |*w| if (w.render(theme)) {
        more = true;
    };
    _ = tui.submit_layer(self.build_target());
    return more;
}

fn build_target(self: *Self) Layer.Target {
    const ox, const oy = self.plane.global_origin_px();
    const cw: i32 = self.plane.cell_x();
    const ch: i32 = self.plane.cell_y();
    return .{
        .src = self.layer,
        .dst = tui.plane().window,
        .x = @divFloor(ox, cw),
        .y = @divFloor(oy, ch),
        .xoffset = @intCast(@mod(ox, cw)),
        .yoffset = @intCast(@mod(oy, ch)),
        .alpha = self.alpha,
        .z_index = self.z_index,
        .blend = self.blend,
    };
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (self.inner) |*w| return w.send(from, m);
    return false;
}

pub fn update(self: *Self) void {
    if (self.inner) |*w| w.update();
}

pub fn get(self: *const Self, name_: []const u8) ?Widget {
    if (self.inner) |w| return w.get(name_);
    return null;
}

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (self.inner) |*w| return w.walk(ctx, f);
    return false;
}

pub fn focus(self: *Self) void {
    if (self.inner) |*w| w.focus();
}

pub fn unfocus(self: *Self) void {
    if (self.inner) |*w| w.unfocus();
}
