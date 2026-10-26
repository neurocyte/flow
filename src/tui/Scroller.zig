const std = @import("std");
const Allocator = std.mem.Allocator;
const Plane = @import("renderer").Plane;
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

const Self = @This();

anim: ScrollAnimation = .{},
content_rows: usize = 0,
view_rows: usize = 0,
sticky_end: bool = false,
scrollbar: ?*scrollbar_v = null,
overlay: ?Overlay = null,
synced_top: ?usize = null,

const Overlay = struct {
    widget: Widget,
    allocator: Allocator,
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
    self.scrollbar = scrollbar;
    self.overlay = .{ .widget = sb, .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    const overlay = if (self.overlay) |*overlay| overlay else return;
    overlay.cancel_timer();
    overlay.widget.deinit(overlay.allocator);
    self.overlay = null;
    self.scrollbar = null;
}

/// `box` is the owner's box, the bar covers its last column
pub fn resize_overlay(self: *Self, box: Widget.Box) void {
    const overlay = self.overlay orelse return;
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
pub fn render_overlay(self: *Self, theme: *const Widget.Theme) bool {
    const overlay = if (self.overlay) |*overlay| overlay else return false;
    const scrollbar = self.scrollbar orelse return false;
    const in_use = scrollbar.hover or scrollbar.active;
    if (overlay.in_use and !in_use) self.activity();
    overlay.in_use = in_use;
    if (!self.overlay_visible()) return false;
    return overlay.widget.render(theme);
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
    self.anim.jump_to(@min(owner_top, self.max_top()));
    self.synced_top = owner_top;
}

/// for a position owned elsewhere: the top to apply after `update`, null if unchanged
pub fn take_owner_top(self: *Self) ?usize {
    const pos = self.anim.pos;
    if (self.synced_top) |synced| if (synced == pos) return null;
    self.synced_top = pos;
    return pos;
}

pub fn set_size(self: *Self, content_rows: usize, view_rows: usize) void {
    const follow_end = self.sticky_end and self.anim.dest >= self.max_top();
    self.content_rows = content_rows;
    self.view_rows = view_rows;
    if (!follow_end)
        self.anim.clamp(self.max_top())
    else if (self.anim.animating())
        self.anim.dest = self.max_top()
    else
        self.anim.jump_to(self.max_top());
    self.set_bar_visible(self.wants_bar());
}

pub fn top(self: *const Self) usize {
    return self.anim.pos;
}

pub fn max_top(self: *const Self) usize {
    return self.content_rows -| self.page_rows();
}

fn page_rows(self: *const Self) usize {
    return @max(1, self.view_rows);
}

pub fn overflows(self: *const Self) bool {
    return self.content_rows > self.view_rows;
}

pub fn bar_cols(self: *const Self) usize {
    const scrollbar = self.scrollbar orelse return 0;
    return if (scrollbar.hidden) 0 else 1;
}

fn wants_bar(self: *const Self) bool {
    return self.overflows() and !self.stuck_to_end();
}

fn stuck_to_end(self: *const Self) bool {
    if (!self.sticky_end or self.anim.animating() or self.anim.pos < self.max_top()) return false;
    const scrollbar = self.scrollbar orelse return true;
    return !scrollbar.active;
}

fn set_bar_visible(self: *Self, visible: bool) void {
    const scrollbar = self.scrollbar orelse return;
    if (scrollbar.hidden != visible) return;
    scrollbar.hidden = !visible;
    tui.need_render(@src());
}

pub fn jump_to(self: *Self, pos: usize) void {
    self.anim.jump_to(@min(self.max_top(), pos));
    self.activity();
    tui.need_render(@src());
}

pub fn glide_to(self: *Self, dest: usize) void {
    self.anim.glide_to(@min(self.max_top(), dest), tui.scroll_animation_timing());
    self.activity();
    tui.need_render(@src());
}

pub fn scroll(self: *Self, action: Panel.ScrollAction) void {
    const rows = self.page_rows();
    const dest = self.anim.dest;
    switch (action) {
        .line_up => self.jump_to(dest -| 1),
        .line_down => self.jump_to(dest + 1),
        .half_page_up => self.glide_to(dest -| @max(1, rows / 2)),
        .half_page_down => self.glide_to(dest + @max(1, rows / 2)),
        .page_up => self.glide_to(dest -| rows),
        .page_down => self.glide_to(dest + rows),
        .top => self.jump_to(0),
        .bottom => self.jump_to(self.max_top()),
    }
}

pub fn receive_mouse(self: *Self, m: tp.message) error{Exit}!bool {
    var btn: MouseEvent.Button = .none;
    if (!try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.more })) return false;
    const rows = self.page_rows();
    const step = if (tui.fast_scroll()) rows else @min(rows, tui.config().scroll_step_vertical);
    switch (btn) {
        .wheel_up => self.glide_to(self.anim.dest -| step),
        .wheel_down => self.glide_to(self.anim.dest + step),
        else => return false,
    }
    return true;
}

fn handle_scroll(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var pos: usize = 0;
    if (try m.match(.{ "scroll_to", tp.extract(&pos) }))
        self.jump_to(pos);
}

pub fn update(self: *Self) void {
    self.anim.advance();
    self.set_bar_visible(self.wants_bar());
}

pub fn render(self: *Self) bool {
    if (self.scrollbar) |scrollbar|
        scrollbar.set(@intCast(self.content_rows), @intCast(self.view_rows), @intCast(self.anim.pos));
    return self.anim.animating();
}
