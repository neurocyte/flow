const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const tp = @import("thespian");
const root_mod = @import("soft_root").root;
const MouseEvent = @import("MouseEvent");

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
region_w_px: i32 = 0,
region_h_px: i32 = 0,
content_cells: usize = 0,
scroll_px: i32 = 0,
scroll_dest_px: i32 = 0,
animation_step: i32 = 0,
animation_lag: f64 = 0,
animation_last_time: i64 = 0,
drag_anchor_px: ?i32 = null,
drag_origin_px: i32 = 0,
user_scrolled: bool = false,
follow_token: u64 = 0,
fade_cells: u16 = 0,
fade_color: ?Widget.Theme.Color = null,
fade_layer: ?*Layer = null,
z_index: ?Layer.Level = null,
layout_override: ?Widget.Layout = null,
inset: Inset = .{},

pub const Inset = struct {
    head: usize = 0,
    tail: usize = 0,
};

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
    if (self.fade_layer) |fade| fade.deinit();
    allocator.destroy(self);
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn inner_plane(self: *Self) Plane {
    return self.layer.plane();
}

pub fn adopt(self: *Self, w: Widget) void {
    w.plane.window.screen = &self.layer.screen;
    w.plane.layer = self.layer;
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

pub fn region(self: *const Self) Layer.Frame {
    const ox, const oy = self.plane.global_origin_px();
    return .{ .x = ox, .y = oy, .w = self.region_w_px, .h = self.region_h_px };
}

fn viewport_px(self: *const Self) i32 {
    return switch (self.direction) {
        .horizontal => self.region_w_px,
        .vertical => self.region_h_px,
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
    const r = self.region();
    return switch (self.direction) {
        .horizontal => .{ r.x - self.scroll_px, r.y },
        .vertical => .{ r.x, r.y - self.scroll_px },
    };
}

pub fn handle_resize(self: *Self, box_: Widget.Box) void {
    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    const box = self.apply_inset(box_, cw, ch);
    self.box = box;
    self.plane.move_yx(@intCast(box.y), @intCast(box.x)) catch return;
    self.plane.resize_simple(@intCast(box.h), @intCast(box.w)) catch return;

    const size = box.resolve_frame(cw, ch);
    self.region_w_px = size.w;
    self.region_h_px = size.h;

    const viewport_cells = switch (self.direction) {
        .horizontal => box.w,
        .vertical => box.h,
    };
    self.content_cells = @max(self.content_size(), viewport_cells);

    self.layer.clip = self.region();
    self.layer.z_index = self.z();
    self.scroll_px = self.clamp_scroll(self.scroll_px);
    self.scroll_dest_px = self.clamp_scroll(self.scroll_dest_px);
    self.layout_inner();
}

fn apply_inset(self: *const Self, box_: Widget.Box, cw: i32, ch: i32) Widget.Box {
    var box = box_;
    const size = switch (self.direction) {
        .horizontal => &box.w,
        .vertical => &box.h,
    };
    const head = @min(self.inset.head, size.*);
    const tail = @min(self.inset.tail, size.* - head);
    size.* -= head + tail;
    switch (self.direction) {
        .horizontal => box.x += head,
        .vertical => box.y += head,
    }
    if (box.frame.is_set()) {
        const cell: i32 = switch (self.direction) {
            .horizontal => cw,
            .vertical => ch,
        };
        const head_px: i32 = @as(i32, @intCast(head)) * cell;
        const total_px: i32 = @as(i32, @intCast(head + tail)) * cell;
        switch (self.direction) {
            .horizontal => {
                box.frame.x += head_px;
                box.frame.w -= total_px;
            },
            .vertical => {
                box.frame.y += head_px;
                box.frame.h -= total_px;
            },
        }
    }
    return box;
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
        .horizontal => .{ self.content_px(), self.region_h_px },
        .vertical => .{ self.region_w_px, self.content_px() },
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

fn clamp_scroll(self: *const Self, px: i32) i32 {
    var v = std.math.clamp(px, 0, self.max_scroll_px());
    if (!build_options.gui) {
        const cell = self.cell_a();
        v = @divFloor(v, cell) * cell;
    }
    return v;
}

pub fn scroll_to_px(self: *Self, px: i32) void {
    const v = self.clamp_scroll(px);
    if (v == self.scroll_dest_px and v == self.scroll_px) return;
    self.scroll_dest_px = v;
    self.update_animation_step();
    tui.need_render(@src());
}

pub fn scroll_to_px_now(self: *Self, px: i32) void {
    const v = self.clamp_scroll(px);
    self.scroll_dest_px = v;
    if (v == self.scroll_px) return;
    self.scroll_px = v;
    self.layout_inner();
    tui.need_render(@src());
}

fn animation_lag_bounds() struct { f64, f64 } {
    const min_ms: f64 = @floatFromInt(tui.config().animation_min_lag);
    const max_ms: f64 = @floatFromInt(tui.config().animation_max_lag);
    return .{ @max(min_ms * 0.001, 0.001), @max(max_ms * 0.001, 0.001) };
}

fn update_animation_step(self: *Self) void {
    const now = root_mod.get_now().toMicroseconds();
    const min_lag, const max_lag = animation_lag_bounds();
    const elapsed: f64 = @as(f64, @floatFromInt(now - self.animation_last_time)) / std.time.us_per_s;
    self.animation_lag = @max(@min(elapsed, max_lag), min_lag);
    self.animation_last_time = now;

    const distance: f64 = @floatFromInt(@abs(self.scroll_dest_px - self.scroll_px));
    const frame_rate: f64 = @floatFromInt(@max(1, tui.config().frame_rate));
    const step_frames = @max(1.0, self.animation_lag * frame_rate);
    self.animation_step = @intFromFloat(@max(1.0, distance / step_frames));
}

fn update_scroll(self: *Self) bool {
    const dest = self.scroll_dest_px;
    if (self.scroll_px == dest) return false;
    const step = @max(1, self.animation_step);
    const next = if (self.scroll_px < dest)
        @min(dest, self.scroll_px + step)
    else
        @max(dest, self.scroll_px - step);
    self.scroll_px = next;
    self.layout_inner();
    return self.scroll_px != dest;
}

pub fn clipped_head(self: *const Self) bool {
    return self.scroll_px > 0;
}

pub fn clipped_tail(self: *const Self) bool {
    return self.scroll_px < self.max_scroll_px();
}

fn submit_fade(self: *Self, z_index: Layer.Level) void {
    if (self.fade_cells == 0) return;
    const color = self.fade_color orelse return;
    const head = self.clipped_head();
    const tail = self.clipped_tail();
    if (!head and !tail) return;

    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    const view = self.region();

    const across_px: i32 = switch (self.direction) {
        .horizontal => self.region_h_px,
        .vertical => self.region_w_px,
    };
    if (across_px <= 0) return;
    const w_px: u16 = @intCast(switch (self.direction) {
        .horizontal => cw,
        .vertical => across_px,
    });
    const h_px: u16 = @intCast(switch (self.direction) {
        .horizontal => across_px,
        .vertical => ch,
    });
    const across_cells: u16 = @intCast(@max(1, @divTrunc(across_px, switch (self.direction) {
        .horizontal => ch,
        .vertical => cw,
    })));

    const fade = self.fade_layer orelse blk: {
        const new = Layer.init(self.allocator, .{ .h = 1, .w = 1 }) catch return;
        self.fade_layer = new;
        break :blk new;
    };
    fade.resize(
        switch (self.direction) {
            .horizontal => 1,
            .vertical => across_cells,
        },
        switch (self.direction) {
            .horizontal => across_cells,
            .vertical => 1,
        },
        w_px,
        h_px,
    ) catch return;
    var plane = fade.plane();
    plane.set_base_style(.{ .bg = color });
    plane.erase();

    const steps: i32 = @intCast(self.fade_cells);
    var i: i32 = 0;
    while (i < steps) : (i += 1) {
        const alpha: u8 = @intCast(@divTrunc(255 * (steps - i), steps + 1));
        if (head) self.submit_sliver(fade, view, i, alpha, z_index, cw, ch);
        if (tail) self.submit_sliver(fade, view, -(i + 1), alpha, z_index, cw, ch);
    }
}

fn submit_sliver(self: *Self, fade: *Layer, view: Layer.Frame, slot: i32, alpha: u8, z_index: Layer.Level, cw: i32, ch: i32) void {
    const along_px: i32 = switch (self.direction) {
        .horizontal => if (slot >= 0) view.x + slot * cw else view.right() + slot * cw,
        .vertical => if (slot >= 0) view.y + slot * ch else view.bottom() + slot * ch,
    };
    const px: i32, const py: i32 = switch (self.direction) {
        .horizontal => .{ along_px, view.y },
        .vertical => .{ view.x, along_px },
    };
    _ = tui.submit_layer(.{
        .src = fade,
        .dst = tui.plane().window,
        .x = @divFloor(px, cw),
        .y = @divFloor(py, ch),
        .xoffset = @intCast(@mod(px, cw)),
        .yoffset = @intCast(@mod(py, ch)),
        .blend = .src_over,
        .alpha = alpha,
        .z_index = @enumFromInt(@intFromEnum(z_index) + 1),
        .clip = view,
    });
}

pub fn scroll_by_px(self: *Self, delta: i32) void {
    self.user_scrolled = true;
    self.scroll_to_px(self.scroll_px + delta);
}

pub fn is_drag_scrolling(self: *const Self) bool {
    return self.drag_anchor_px != null;
}

pub fn drag_scroll(self: *Self, coord: MouseEvent.Coord) void {
    const pos: i32 = switch (self.direction) {
        .horizontal => coord.x,
        .vertical => coord.y,
    };
    tui.rdr().request_mouse_cursor(switch (self.direction) {
        .horizontal => .@"ew-resize",
        .vertical => .@"ns-resize",
    }, true);
    const anchor = self.drag_anchor_px orelse {
        self.drag_anchor_px = pos;
        self.drag_origin_px = self.scroll_px;
        self.scroll_dest_px = self.scroll_px;
        return;
    };
    self.user_scrolled = true;
    self.scroll_to_px_now(self.drag_origin_px - (pos - anchor));
}

pub fn follow(self: *Self, token: u64, w: Widget) void {
    if (token != self.follow_token) {
        self.follow_token = token;
        self.user_scrolled = false;
    } else if (self.user_scrolled) return;
    self.scroll_into_view(w);
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
    const view = self.viewport_px();
    const from = self.scroll_dest_px;
    if (end - start >= view) return self.scroll_to_px(start);
    if (start < from) return self.scroll_to_px(start);
    if (end > from + view) return self.scroll_to_px(end - view);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (self.drag_anchor_px != null) {
        const source, const button = tui.get_drag_source();
        if (source == null or button != .middle) {
            self.drag_anchor_px = null;
            tui.reset_hover(@src());
            tui.refresh_hover(@src());
        }
    }

    const animating = self.update_scroll();

    const ox, const oy = self.origin_px();
    if (ox != self.layer.origin_px_x or oy != self.layer.origin_px_y) self.layout_inner();
    self.layer.clip = self.region();
    const z_index = self.z();
    self.layer.z_index = z_index;

    var more = animating;
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
    self.submit_fade(z_index);
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
