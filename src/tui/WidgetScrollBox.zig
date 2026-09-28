const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const tp = @import("thespian");

const renderer = @import("renderer");
const Plane = renderer.Plane;
const Layer = renderer.Layer;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");

const Self = @This();

pub const Options = struct {
    name: [:0]const u8,
    direction: Widget.Direction = .horizontal,
};

allocator: Allocator,
plane: Plane,
parent: Plane,
layer: *Layer,
inner: ?Widget = null,
direction: Widget.Direction,
box: Widget.Box = .{},
region: Layer.Frame = .{},
content_cells: usize = 0,
scroll_px: i32 = 0,
z_index: ?Layer.Level = null,
layout_override: ?Widget.Layout = null,

pub fn create(allocator: Allocator, parent: Plane, options: Options) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const layer = try Layer.init(allocator, .{ .h = 1, .w = 1 });
    errdefer layer.deinit();
    const plane = try Plane.init(&(Widget.Box{}).opts(options.name), parent);
    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .parent = parent,
        .layer = layer,
        .direction = options.direction,
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
    if (self.layout_override) |layout_| return layout_;
    return if (self.inner) |w| w.layout() else .dynamic;
}

fn cell_a(self: *const Self) i32 {
    const root = tui.plane();
    return switch (self.direction) {
        .horizontal => root.cell_x(),
        .vertical => root.cell_y(),
    };
}

fn z(self: *const Self) Layer.Level {
    if (self.z_index) |level| return level;
    return if (self.plane.layer) |parent_layer|
        @enumFromInt(@intFromEnum(parent_layer.z_index) + 1)
    else
        .main;
}

fn viewport_px(self: *const Self) i32 {
    return switch (self.direction) {
        .horizontal => self.region.w,
        .vertical => self.region.h,
    };
}

fn content_px(self: *const Self) i32 {
    return @as(i32, @intCast(self.content_cells)) * self.cell_a();
}

pub fn max_scroll_px(self: *const Self) i32 {
    return @max(0, self.content_px() - self.viewport_px());
}

fn content_size(self: *Self) usize {
    const w = self.inner orelse return 0;
    if (w.dynamic_cast(WidgetList)) |list| return list.natural_size_a();
    return switch (w.layout()) {
        .static => |val| val,
        .dynamic => 0,
    };
}

fn origin_px(self: *const Self) struct { i32, i32 } {
    return switch (self.direction) {
        .horizontal => .{ self.region.x - self.scroll_px, self.region.y },
        .vertical => .{ self.region.x, self.region.y - self.scroll_px },
    };
}

pub fn handle_resize(self: *Self, box: Widget.Box) void {
    self.box = box;
    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    self.region = box.resolve_frame(cw, ch);

    const viewport_cells = switch (self.direction) {
        .horizontal => box.w,
        .vertical => box.h,
    };
    self.content_cells = @max(self.content_size(), viewport_cells);

    self.plane.move_yx(@intCast(box.y), @intCast(box.x)) catch return;
    self.plane.resize_simple(@intCast(box.h), @intCast(box.w)) catch return;

    self.layer.clip = self.region;
    self.layer.z_index = self.z();
    self.scroll_px = std.math.clamp(self.scroll_px, 0, self.max_scroll_px());
    self.layout_inner();
}

fn layout_inner(self: *Self) void {
    const ox, const oy = self.origin_px();
    self.layer.origin_px_x = ox;
    self.layer.origin_px_y = oy;

    const perp_cells = switch (self.direction) {
        .horizontal => self.box.h,
        .vertical => self.box.w,
    };
    const w_cells: usize, const h_cells: usize = switch (self.direction) {
        .horizontal => .{ self.content_cells, perp_cells },
        .vertical => .{ perp_cells, self.content_cells },
    };
    const w_px: i32, const h_px: i32 = switch (self.direction) {
        .horizontal => .{ self.content_px(), self.region.h },
        .vertical => .{ self.region.w, self.content_px() },
    };
    self.layer.resize(
        @intCast(w_cells),
        @intCast(h_cells),
        @intCast(@max(0, w_px)),
        @intCast(@max(0, h_px)),
    ) catch return;

    var inner_box: Widget.Box = .{ .y = 0, .x = 0, .w = w_cells, .h = h_cells };
    switch (self.direction) {
        .horizontal => inner_box.extra_y = self.box.extra_y,
        .vertical => inner_box.extra_x = self.box.extra_x,
    }
    if (self.inner) |*w| w.resize(inner_box);
}

pub fn scroll_to_px(self: *Self, px: i32) void {
    var v = std.math.clamp(px, 0, self.max_scroll_px());
    if (!build_options.gui) {
        const cell = self.cell_a();
        v = @divFloor(v, cell) * cell;
    }
    if (v == self.scroll_px) return;
    self.scroll_px = v;
    self.layout_inner();
    tui.need_render(@src());
}

pub fn scroll_by_px(self: *Self, delta: i32) void {
    self.scroll_to_px(self.scroll_px + delta);
}

pub fn scroll_cells(self: *const Self) i32 {
    return @divFloor(self.scroll_px, self.cell_a());
}

pub fn scroll_into_view(self: *Self, w: Widget) void {
    const cell = self.cell_a();
    const start_cells: i32, const len_cells: i32 = switch (self.direction) {
        .horizontal => .{ w.plane.abs_x(), w.plane.dim_x() },
        .vertical => .{ w.plane.abs_y(), w.plane.dim_y() },
    };
    const start = start_cells * cell;
    const end = start + len_cells * cell;
    if (start < self.scroll_px) return self.scroll_to_px(start);
    const view = self.viewport_px();
    if (end > self.scroll_px + view) return self.scroll_to_px(end - view);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const ox, const oy = self.origin_px();
    const z_index = self.z();
    self.layer.origin_px_x = ox;
    self.layer.origin_px_y = oy;
    self.layer.z_index = z_index;

    var more = false;
    if (self.inner) |*w| if (w.render(theme)) {
        more = true;
    };

    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    _ = tui.submit_layer(.{
        .src = self.layer,
        .dst = root.window,
        .x = @divFloor(ox, cw),
        .y = @divFloor(oy, ch),
        .xoffset = @intCast(@mod(ox, cw)),
        .yoffset = @intCast(@mod(oy, ch)),
        .z_index = z_index,
        .blend = .replace,
        .clip = self.layer.clip,
    });
    return more;
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
    if (f(ctx, Widget.to(self), .begin)) return true;
    if (self.inner) |*w| if (w.walk(ctx, f)) return true;
    return f(ctx, Widget.to(self), .end);
}

pub fn focus(self: *Self) void {
    if (self.inner) |*w| w.focus();
}

pub fn unfocus(self: *Self) void {
    if (self.inner) |*w| w.unfocus();
}

pub fn hover(self: *Self) bool {
    return if (self.inner) |*w| w.hover() else false;
}
