const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const tp = @import("thespian");
const MouseEvent = @import("MouseEvent");
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
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

fn jump_to(self: *Self, pos: usize) void {
    self.anim.jump_to(@min(self.max_top(), pos));
    tui.need_render(@src());
}

fn glide_to(self: *Self, dest: usize) void {
    self.anim.glide_to(@min(self.max_top(), dest), tui.scroll_animation_timing());
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
