const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Plane = @import("renderer").Plane;
const Layer = @import("renderer").Layer;
const tp = @import("thespian");
const root = @import("soft_root").root;
const MouseEvent = @import("MouseEvent");
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Panel = @import("Panel.zig");
const WidgetList = @import("WidgetList.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const ScrollAnimation = @import("ScrollAnimation.zig");
const Pos = ScrollAnimation.Pos;

const Self = @This();

y: Axis = .{},
x: Axis = .{},
sticky_end: bool = false,
pixel_offsets: bool = false,
scrollbar: ?*scrollbar_v = null,
overlay: ?Overlay = null,
synced_top: ?usize = null,

pub const Axis = struct {
    anim: ScrollAnimation = .{},
    content: usize = 0,
    view: usize = 0,
    box: usize = 0,
    view_px: usize = 0,
    box_px: usize = 0,
    cell_px: u16 = 1,
    px_rest: f32 = 0,

    fn max_pos(self: *const Axis) Pos {
        if (self.cell_px <= 1 or self.view_px == 0) return .at(self.content -| @max(1, self.view));
        const content_px = self.content * self.cell_px;
        return Pos.from_px(@intCast(content_px -| self.view_px), self.cell_px);
    }

    fn draw_cells(self: *const Axis) usize {
        if (self.cell_px <= 1 or self.view_px == 0) return @max(self.box, self.view);
        return (self.anim.pos.offset + self.view_px + self.cell_px - 1) / self.cell_px;
    }

    fn set_cell_px(self: *Axis, cell_px: u16) bool {
        if (self.cell_px == cell_px) return false;
        self.cell_px = cell_px;
        return true;
    }
};

const Overlay = struct {
    widget: Widget,
    allocator: Allocator,
    layer: ?*Layer = null,
    hide_at_us: i64 = 0,
    hide_timer: ?tp.Cancellable = null,
    in_use: bool = false,

    fn cancel_timer(self: *Overlay) void {
        var timer = self.hide_timer orelse return;
        timer.cancel() catch {};
        timer.deinit();
        self.hide_timer = null;
    }
};

/// self must not move after this, the scrollbar keeps a pointer to it
pub fn attach_scrollbar(self: *Self, allocator: Allocator, container: *WidgetList, parent: Plane) !void {
    if (!tui.config().show_scrollbars) return;
    const sb = try scrollbar_v.create(allocator, parent, null, EventHandler.bind(self, handle_scroll));
    errdefer sb.deinit(allocator);
    try container.add(sb);
    const scrollbar = sb.dynamic_cast(scrollbar_v).?;
    scrollbar.style_factory = scrollbar_v.panel_style;
    scrollbar.precise = self.pixel_offsets;
    scrollbar.pixel_track = self.pixel_offsets;
    scrollbar.hidden = !self.wants_bar();
    self.scrollbar = scrollbar;
}

/// a bar drawn over the last column of `content` while scrolling, owned by self
/// self must not move after this, the scrollbar keeps a pointer to it
pub fn attach_overlay(self: *Self, allocator: Allocator, content: Plane) !void {
    if (!tui.config().show_scrollbars) return;
    const sb = try scrollbar_v.create(allocator, content, null, EventHandler.bind(self, handle_scroll));
    const scrollbar = sb.dynamic_cast(scrollbar_v).?;
    scrollbar.style_factory = scrollbar_v.editor_style;
    scrollbar.precise = self.pixel_offsets;
    self.scrollbar = scrollbar;
    self.overlay = .{ .widget = sb, .allocator = allocator };
    if (build_options.gui and self.pixel_offsets) {
        const layer = try Layer.init(allocator, .{ .h = 1, .w = 1 });
        sb.plane.window.screen = &layer.screen;
        sb.plane.layer = layer;
        self.overlay.?.layer = layer;
    }
}

pub fn deinit(self: *Self) void {
    const overlay = if (self.overlay) |*overlay| overlay else return;
    overlay.cancel_timer();
    overlay.widget.deinit(overlay.allocator);
    if (overlay.layer) |layer| layer.deinit();
    self.overlay = null;
    self.scrollbar = null;
}

/// `box` is the owner's box, the bar covers its last column
pub fn resize_overlay(self: *Self, box: Widget.Box) void {
    const overlay = self.overlay orelse return;
    if (overlay.layer) |layer| {
        const root_plane = tui.plane();
        layer.resize(1, @intCast(box.h), @intCast(root_plane.cell_x()), @intCast(box.h * @as(usize, @intCast(root_plane.cell_y())))) catch return;
        return overlay.widget.resize(.{ .y = 0, .x = 0, .h = box.h, .w = 1 });
    }
    overlay.widget.resize(.{ .y = box.y, .x = box.x + box.w -| 1, .h = box.h, .w = 1 });
}

fn overlay_visible(self: *const Self) bool {
    const overlay = self.overlay orelse return false;
    const scrollbar = self.scrollbar orelse return false;
    if (!self.overflows()) return false;
    if (scrollbar.hover or scrollbar.active) return true;
    return root.get_now().toMicroseconds() < overlay.hide_at_us;
}

/// show the overlay bar and restart its hide delay
pub fn activity(self: *Self) void {
    const overlay = if (self.overlay) |*overlay| overlay else return;
    const delay_us: i64 = @intCast(tui.config().scrollbar_overlay_hide_delay * std.time.us_per_ms);
    overlay.hide_at_us = root.get_now().toMicroseconds() + delay_us;
    overlay.cancel_timer();
    // a little late, so the render that hides the bar comes after hide_at_us
    const send_after_us: u64 = @intCast(delay_us + std.time.us_per_ms);
    overlay.hide_timer = tp.self_pid().delay_send_cancellable(overlay.allocator, "scroller.hide", send_after_us, .{"render"}) catch null;
    tui.need_render(@src());
}

/// show the overlay bar on edge hover
pub fn overlay_edge_hover(self: *Self, coord: MouseEvent.Coord, owner: Plane) void {
    if (self.overlay == null or !self.overflows()) return;
    const geometry = owner.mouse_geometry();
    const cell = coord.to_cell(geometry);
    if (cell.col != @as(i32, @intCast(owner.dim_x())) - 1) return;
    const cell_width: u16 = @intCast(@max(1, geometry.cell_width));
    if (tui.rdr().pixel_mouse() and cell.xoffset < cell_width - cell_width / 4) return;
    self.activity();
    tui.refresh_hover(@src());
}

/// the owner draws its content first
pub fn render_overlay(self: *Self, theme: *const Widget.Theme, owner: *const Plane) bool {
    const overlay = if (self.overlay) |*overlay| overlay else return false;
    const scrollbar = self.scrollbar orelse return false;
    const in_use = scrollbar.hover or scrollbar.active;
    if (overlay.in_use and !in_use) self.activity();
    overlay.in_use = in_use;
    if (!self.overlay_visible()) return false;
    const more = overlay.widget.render(theme);
    if (overlay.layer) |layer| submit_overlay_layer(layer, owner);
    return more;
}

/// the bar over the last column of `owner`, above its content layer
fn submit_overlay_layer(layer: *Layer, owner: *const Plane) void {
    const root_plane = tui.plane();
    const cw: i32 = root_plane.cell_x();
    const ch: i32 = root_plane.cell_y();
    const ox, const oy = owner.global_origin_px();
    const x = ox + (@as(i32, @intCast(owner.dim_x())) - 1) * cw;
    const content_z: i32 = if (owner.layer) |l| @backingInt(l.z_index) + 1 else @backingInt(Layer.Level.main);
    layer.clip = .{ .x = x, .y = oy, .w = cw, .h = @as(i32, @intCast(owner.dim_y())) * ch };
    layer.z_index = @fromBackingInt(content_z + 1);
    _ = tui.submit_layer(.{
        .src = layer,
        .dst = root_plane.window,
        .x = @divFloor(x, cw),
        .y = @divFloor(oy, ch),
        .xoffset = @intCast(@mod(x, cw)),
        .yoffset = @intCast(@mod(oy, ch)),
        .z_index = layer.z_index,
        .blend = .replace,
        .clip = layer.clip,
    });
}

/// the top row for the owner of the position, rounded up while a row is cut off
pub fn take_owner_top_ceil(self: *Self) ?usize {
    const row = self.top() + @intFromBool(self.y.anim.pos.offset > 0);
    if (self.synced_top) |synced| if (synced == row) return null;
    self.synced_top = row;
    return row;
}

/// the owner walks this before itself, so the bar wins hit tests over the owner
pub fn walk_overlay(self: *Self, ctx: *anyopaque, f: Widget.WalkFn) bool {
    const overlay = self.overlay orelse return false;
    if (!self.overlay_visible()) return false;
    return overlay.widget.walk(ctx, f);
}

/// for a position owned elsewhere: follow `top` if the owner moved it
pub fn sync(self: *Self, owner_top: usize) void {
    if (self.synced_top) |synced| if (synced == owner_top) return;
    self.y.anim.jump_to(.at(@min(owner_top, self.max_top())));
    self.synced_top = owner_top;
}

/// for a position owned elsewhere: the top to apply after `update`, null if unchanged
pub fn take_owner_top(self: *Self) ?usize {
    const row = self.top();
    if (self.synced_top) |synced| if (synced == row) return null;
    self.synced_top = row;
    return row;
}

pub fn set_size(self: *Self, content_rows: usize, visible_rows: usize) void {
    const follow_end = self.at_end();
    self.y.content = content_rows;
    self.y.view = visible_rows;
    self.y.box = @max(self.y.box, visible_rows);
    self.reclamp(follow_end);
}

fn reclamp(self: *Self, follow_end: bool) void {
    if (follow_end)
        self.y.anim.retarget(self.y.max_pos())
    else
        self.y.anim.clamp(self.y.max_pos());
    self.set_bar_visible(self.wants_bar());
}

fn at_end(self: *const Self) bool {
    return self.sticky_end and self.y.anim.dest().order(self.y.max_pos()) != .lt;
}

pub fn set_content(self: *Self, content_rows: usize) void {
    self.set_size(content_rows, self.y.view);
}

pub fn set_view(self: *Self, box: Widget.Box, plane: *const Plane) void {
    const follow_end = self.at_end();
    const cw: usize = @intCast(@max(1, plane.cell_x()));
    const ch: usize = @intCast(@max(1, plane.cell_y()));
    self.y.view = box.full_rows(@intCast(ch));
    self.y.box = box.h;
    self.y.view_px = if (box.frame.is_set()) @intCast(@max(0, box.frame.h)) else box.h * ch;
    self.y.box_px = self.y.view_px;
    self.x.box_px = if (box.frame.is_set()) @intCast(@max(0, box.frame.w)) else box.w * cw;
    self.reclamp(follow_end);
}

pub fn set_cols(self: *Self, content_cols: usize, view_cols: usize) void {
    self.x.content = content_cols;
    self.x.view = view_cols;
    self.x.anim.clamp(self.x.max_pos());
}

pub fn left(self: *const Self) usize {
    return self.x.anim.pos.cell;
}

pub fn left_dest(self: *const Self) usize {
    return self.x.anim.dest().cell;
}

pub fn max_left(self: *const Self) usize {
    return self.x.max_pos().cell;
}

pub fn scrolled_left(self: *const Self) bool {
    return self.x.anim.pos.order(.{}) == .gt;
}

pub fn scrolled_right(self: *const Self) bool {
    return self.x.anim.pos.order(self.x.max_pos()) == .lt;
}

pub fn draw_cols(self: *const Self) usize {
    return self.x.view + @intFromBool(self.x.anim.pos.offset > 0);
}

pub fn jump_left_to(self: *Self, col: usize) void {
    self.x.anim.jump_to(Pos.at(col).min(self.x.max_pos()));
    tui.need_render(@src());
}

pub fn glide_left_to(self: *Self, col: usize) void {
    self.x.anim.glide_to(Pos.at(col).min(self.x.max_pos()), tui.scroll_animation_timing());
    tui.need_render(@src());
}

pub fn draw_rows(self: *const Self) usize {
    return self.y.draw_cells();
}

pub fn view_px(self: *const Self) struct { usize, usize } {
    return .{ self.x.box_px, self.y.box_px };
}

pub fn pos(self: *const Self) MouseEvent.Cell {
    return .{
        .col = @intCast(self.x.anim.pos.cell),
        .row = @intCast(self.y.anim.pos.cell),
        .xoffset = self.x.anim.pos.offset,
        .yoffset = self.y.anim.pos.offset,
    };
}

pub fn top(self: *const Self) usize {
    return self.y.anim.pos.cell;
}

pub fn dest(self: *const Self) usize {
    return self.y.anim.dest().cell;
}

pub fn view_rows(self: *const Self) usize {
    return self.y.view;
}

pub fn max_top(self: *const Self) usize {
    return self.y.max_pos().cell;
}

fn page_rows(self: *const Self) usize {
    return @max(1, self.y.view);
}

pub fn overflows(self: *const Self) bool {
    return self.y.content > self.y.view;
}

pub fn bar_cols(self: *const Self) usize {
    const scrollbar = self.scrollbar orelse return 0;
    return if (scrollbar.hidden) 0 else 1;
}

fn wants_bar(self: *const Self) bool {
    return self.overflows() and !self.stuck_to_end();
}

fn stuck_to_end(self: *const Self) bool {
    if (!self.sticky_end or self.y.anim.animating() or self.y.anim.pos.order(self.y.max_pos()) == .lt) return false;
    const scrollbar = self.scrollbar orelse return true;
    return !scrollbar.active;
}

fn set_bar_visible(self: *Self, visible: bool) void {
    const scrollbar = self.scrollbar orelse return;
    if (scrollbar.hidden != visible) return;
    scrollbar.hidden = !visible;
    tui.need_render(@src());
}

pub fn jump_to(self: *Self, row: usize) void {
    self.y.anim.jump_to(Pos.at(row).min(self.y.max_pos()));
    self.activity();
    tui.need_render(@src());
}

pub fn glide_to(self: *Self, dest_row: usize) void {
    self.y.anim.glide_to(Pos.at(dest_row).min(self.y.max_pos()), tui.scroll_animation_timing());
    self.activity();
    tui.need_render(@src());
}

pub fn scroll(self: *Self, action: Panel.ScrollAction) void {
    const rows = self.page_rows();
    const row = self.dest();
    switch (action) {
        .line_up => self.jump_to(row -| 1),
        .line_down => self.jump_to(row + 1),
        .half_page_up => self.glide_to(row -| @max(1, rows / 2)),
        .half_page_down => self.glide_to(row + @max(1, rows / 2)),
        .page_up => self.glide_to(row -| rows),
        .page_down => self.glide_to(row + rows),
        .top => self.jump_to(0),
        .bottom => self.jump_to(self.y.content),
        .left, .right, .line_start, .line_end => {},
    }
}

pub fn receive_mouse(self: *Self, m: tp.message) error{Exit}!bool {
    var event: MouseEvent.Scroll = undefined;
    if (try m.match(.{ "scroll", tp.extract(&event) })) return self.receive_scroll(event);
    var btn: MouseEvent.Button = .none;
    var mods: MouseEvent.Modifiers = .{};
    if (!try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.any, tp.extract(&mods) })) return false;
    const rows = self.page_rows();
    const step = if (tui.mouse_actions(mods).fast_scroll) rows else @min(rows, tui.config().scroll_step_vertical);
    switch (btn) {
        .wheel_up => self.glide_to(self.dest() -| step),
        .wheel_down => self.glide_to(self.dest() + step),
        else => return false,
    }
    return true;
}

fn receive_scroll(self: *Self, e: MouseEvent.Scroll) bool {
    const precise = switch (e.source) {
        .finger, .continuous => true,
        .unknown, .wheel => false,
    };
    const alt_scroll = e.axis == .y and tui.mouse_actions(e.mods).alt_scroll;
    if (e.axis == .x or alt_scroll) {
        if (!precise or !self.pixel_offsets or self.x.cell_px <= 1 or self.x.content <= self.x.view) return false;
        const delta = if (alt_scroll) e.amount.delta.y else e.amount.delta.x;
        self.scroll_by_px(.x, @as(f32, @floatFromInt(delta)) * tui.scroll_delta_scale());
        return true;
    }
    if (precise and self.pixel_offsets and self.y.cell_px > 1) {
        self.scroll_by_px(.y, @as(f32, @floatFromInt(e.amount.delta.y)) * tui.scroll_delta_scale());
        return true;
    }
    const steps = e.amount.step.y;
    if (steps == 0) return true;
    const rows = self.page_rows();
    const step = if (tui.mouse_actions(e.mods).fast_scroll) rows else @min(rows, tui.config().scroll_step_vertical);
    const distance = step * @abs(steps);
    self.glide_to(if (steps < 0) self.dest() -| distance else self.dest() + distance);
    return true;
}

pub fn scroll_by_px(self: *Self, axis: MouseEvent.Scroll.Axis, delta: f32) void {
    const a = switch (axis) {
        .x => &self.x,
        .y => &self.y,
    };
    const total = delta + a.px_rest;
    const whole = @round(total);
    a.px_rest = total - whole;
    const max = a.max_pos().to_px(a.cell_px);
    const px = std.math.clamp(a.anim.pos.to_px(a.cell_px) + @as(i64, @intFromFloat(whole)), 0, max);
    a.anim.jump_to(Pos.from_px(px, a.cell_px));
    if (axis == .y) self.activity();
    tui.need_render(@src());
}

fn handle_scroll(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var row: usize = 0;
    var fraction: f64 = 0;
    if (try m.match(.{ "scroll_to", tp.extract(&row) })) {
        self.jump_to(row);
    } else if (try m.match(.{ "scroll_to_fraction", tp.extract(&fraction) })) {
        const cell_px = self.y.cell_px;
        const max: f64 = @floatFromInt(self.y.max_pos().to_px(cell_px));
        self.y.anim.jump_to(Pos.from_px(@intFromFloat(@round(std.math.clamp(fraction, 0, 1) * max)), cell_px));
        self.activity();
        tui.need_render(@src());
    }
}

pub fn update(self: *Self) void {
    const cell: @TypeOf(tui.scroll_cell_size()) = if (self.pixel_offsets) tui.scroll_cell_size() else .{ .w = 1, .h = 1 };
    if (self.y.set_cell_px(cell.h)) self.reclamp(self.at_end());
    _ = self.x.set_cell_px(cell.w);
    const now_us = root.get_now().toMicroseconds();
    self.y.anim.update(now_us, cell.h);
    self.x.anim.update(now_us, cell.w);
    self.set_bar_visible(self.wants_bar());
}

pub fn render(self: *Self) bool {
    if (self.scrollbar) |scrollbar|
        scrollbar.set(@intCast(self.y.content), @intCast(self.y.view), @intCast(self.top()));
    return self.y.anim.animating() or self.x.anim.animating();
}
