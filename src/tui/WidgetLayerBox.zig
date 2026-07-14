const std = @import("std");
const Allocator = std.mem.Allocator;

const tp = @import("thespian");

const renderer = @import("renderer");
const Plane = renderer.Plane;
const Layer = renderer.Layer;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

pub const Placement = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

pub const Options = struct {
    name: [:0]const u8,
    placement: Placement = .top_left,
    // edge offsets, in cells, measured from the placement edges
    offset_x: u16 = 0,
    offset_y: u16 = 0,
};

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
radius: u16 = 0,
corners: Layer.Target.Corners = .all,
shadow: ?Layer.Target.Shadow = null,
placement: Placement = .top_left,
offset_x: u16 = 0,
offset_y: u16 = 0,
content_w: u16 = 0,
content_h: u16 = 0,
shift_x: i32 = 0,
shift_y: i32 = 0,
clip: ?Layer.Frame = null,

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
        .placement = options.placement,
        .offset_x = options.offset_x,
        .offset_y = options.offset_y,
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

    if (self.content_w != 0 and self.content_h != 0)
        return self.place_in_region(box);

    if (box.frame.is_set())
        return self.fill_frame(box);

    self.plane.move_yx(@intCast(box.y), @intCast(box.x)) catch return;
    self.plane.resize_simple(@intCast(box.h), @intCast(box.w)) catch return;

    const cw = self.plane.cell_x();
    const ch = self.plane.cell_y();
    const w_cells: u16 = @intCast(box.w);
    const h_cells: u16 = @intCast(box.h);
    const layer_w_pix: u16 = @as(u16, w_cells) * cw + box.extra_x;
    const layer_h_pix: u16 = @as(u16, h_cells) * ch + box.extra_y;
    self.layer.resize(w_cells, h_cells, layer_w_pix, layer_h_pix) catch return;

    const shift_x: i32 = switch (self.placement) {
        .top_left, .center_left, .bottom_left => 0,
        .top_center, .center, .bottom_center => @intCast(box.extra_x / 2),
        .top_right, .center_right, .bottom_right => @intCast(box.extra_x),
    };
    const shift_y: i32 = switch (self.placement) {
        .top_left, .top_center, .top_right => 0,
        .center_left, .center, .center_right => @intCast(box.extra_y / 2),
        .bottom_left, .bottom_center, .bottom_right => @intCast(box.extra_y),
    };
    const ox, const oy = self.plane.global_origin_px();

    self.shift_x = 0;
    self.shift_y = 0;
    self.layer.origin_px_x = ox + shift_x;
    self.layer.origin_px_y = oy + shift_y;
    self.layer.z_index = self.z_index;

    if (self.inner) |*w|
        w.resize(.{
            .y = 0,
            .x = 0,
            .w = box.w,
            .h = box.h,
            .extra_x = box.extra_x,
            .extra_y = box.extra_y,
        });
}

fn place_in_region(self: *Self, box: Widget.Box) void {
    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    const region = box.resolve_frame(cw, ch);
    self.clip = region;

    const content_w_px: i32 = @as(i32, self.content_w) * cw;
    const content_h_px: i32 = @as(i32, self.content_h) * ch;
    const off_x: i32 = @as(i32, self.offset_x) * cw;
    const off_y: i32 = @as(i32, self.offset_y) * ch;

    const px_x: i32 = switch (self.placement) {
        .top_left, .center_left, .bottom_left => region.x + off_x,
        .top_center, .center, .bottom_center => region.x + @divFloor(region.w - content_w_px, 2),
        .top_right, .center_right, .bottom_right => region.right() - content_w_px - off_x,
    };
    const px_y: i32 = switch (self.placement) {
        .top_left, .top_center, .top_right => region.y + off_y,
        .center_left, .center, .center_right => region.y + @divFloor(region.h - content_h_px, 2),
        .bottom_left, .bottom_center, .bottom_right => region.bottom() - content_h_px - off_y,
    };

    const x_cell: i32 = @divFloor(px_x, cw);
    const y_cell: i32 = @divFloor(px_y, ch);
    self.plane.move_yx(y_cell, x_cell) catch return;
    self.plane.resize_simple(self.content_h, self.content_w) catch return;
    self.layer.resize(self.content_w, self.content_h, @intCast(content_w_px), @intCast(content_h_px)) catch return;

    self.shift_x = px_x - x_cell * cw;
    self.shift_y = px_y - y_cell * ch;
    self.layer.origin_px_x = px_x;
    self.layer.origin_px_y = px_y;
    self.layer.z_index = self.z_index;

    if (self.inner) |*w|
        w.resize(.{ .y = 0, .x = 0, .w = self.content_w, .h = self.content_h });
}

fn fill_frame(self: *Self, box: Widget.Box) void {
    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    const frame = box.frame;

    const x_cell: i32 = @divFloor(frame.x, cw);
    const y_cell: i32 = @divFloor(frame.y, ch);
    self.plane.move_yx(y_cell, x_cell) catch return;
    self.plane.resize_simple(@intCast(box.h), @intCast(box.w)) catch return;
    self.layer.resize(@intCast(box.w), @intCast(box.h), @intCast(frame.w), @intCast(frame.h)) catch return;

    self.shift_x = frame.x - x_cell * cw;
    self.shift_y = frame.y - y_cell * ch;
    self.layer.origin_px_x = frame.x;
    self.layer.origin_px_y = frame.y;
    self.layer.z_index = self.z_index;

    if (self.inner) |*w|
        w.resize(.{
            .y = 0,
            .x = 0,
            .w = box.w,
            .h = box.h,
            .extra_x = box.extra_x,
            .extra_y = box.extra_y,
        });
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const target = self.build_target();
    const std_plane = tui.plane();
    const cw_root: i32 = std_plane.cell_x();
    const ch_root: i32 = std_plane.cell_y();
    self.layer.origin_px_x = target.x * cw_root + @as(i32, target.xoffset);
    self.layer.origin_px_y = target.y * ch_root + @as(i32, target.yoffset);

    var more = false;
    if (self.inner) |*w| if (w.render(theme)) {
        more = true;
    };
    _ = tui.submit_layer(target);
    return more;
}

fn build_target(self: *Self) Layer.Target {
    const ox, const oy = self.plane.global_origin_px();
    const cw: i32 = self.plane.cell_x();
    const ch: i32 = self.plane.cell_y();
    const px = ox + self.shift_x;
    const py = oy + self.shift_y;
    return .{
        .src = self.layer,
        .dst = tui.plane().window,
        .x = @divFloor(px, cw),
        .y = @divFloor(py, ch),
        .xoffset = @intCast(@mod(px, cw)),
        .yoffset = @intCast(@mod(py, ch)),
        .alpha = self.alpha,
        .z_index = self.z_index,
        .blend = self.blend,
        .radius = self.radius,
        .corners = self.corners,
        .shadow = self.shadow,
        .dst_w = if (self.content_w != 0) @intCast(@as(i32, self.content_w) * cw) else 0,
        .dst_h = if (self.content_h != 0) @intCast(@as(i32, self.content_h) * ch) else 0,
        .clip = self.clip,
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
