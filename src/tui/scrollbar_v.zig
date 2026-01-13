const Allocator = @import("std").mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");

const Plane = @import("renderer").Plane;
const input = @import("input");
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

plane: Plane,
pos_scrn: u32 = 0,
view_scrn: u32 = 8,
size_scrn: u32 = 8,
mouse_pos_scrn_offset: u32 = 0,

pos_virt: u32 = 0,
view_virt: u32 = 1,
size_virt: u32 = 1,

max_ypx: i32 = 8,

event_sink: EventHandler,
hover: bool = false,
active: bool = false,
style_factory: ?*const fn (self: *Self, theme: *const Widget.Theme) Widget.Theme.Style = null,

const Self = @This();

pub fn create(allocator: Allocator, parent: Plane, event_source: ?Widget, event_sink: EventHandler) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .event_sink = event_sink,
    };

    if (event_source) |source|
        try source.subscribe(EventHandler.bind(self, handle_event));
    return self.widget();
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = 1 };
}

pub fn handle_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var size: u32 = 0;
    var view: u32 = 0;
    var pos: u32 = 0;
    if (try m.match(.{ "E", "view", tp.extract(&size), tp.extract(&view), tp.extract(&pos) }))
        self.set(size, view, pos);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var y: i32 = undefined;
    var ypx: i32 = undefined;

    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) })) {
        self.active = true;
        self.update_max_ypx(ypx);
        self.click_at(y, ypx);
        return true;
    } else if (try m.match(.{ "B", input.event.release, @intFromEnum(input.mouse.BUTTON1), tp.more })) {
        self.active = false;
        return true;
    } else if (try m.match(.{ "D", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) })) {
        self.active = true;
        self.update_max_ypx(ypx);
        self.drag_to(y, ypx);
        return true;
    } else if (try m.match(.{ "B", input.event.release, @intFromEnum(input.mouse.BUTTON1), tp.more })) {
        self.active = false;
        return true;
    } else if (try m.match(.{ "D", input.event.release, @intFromEnum(input.mouse.BUTTON1), tp.more })) {
        self.active = false;
        return true;
    } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
        return true;
    }

    return false;
}

fn update_max_ypx(self: *Self, ypx_: i32) void {
    self.max_ypx = @max(self.max_ypx, ypx_);
}

fn y_coord_to_pos_scrn(self: *const Self, y_: i32, ypx_: i32) u32 {
    const max_ypx: f64 = @floatFromInt(self.max_ypx);
    const y: f64 = @floatFromInt(y_);
    const ypx: f64 = @floatFromInt(ypx_);
    const plane_y: f64 = @floatFromInt(self.plane.abs_y());

    const ratio = max_ypx / eighths_c;
    const pos_scrn_ = ((y - plane_y) * eighths_c) + (ypx / ratio);
    const pos_scrn: i32 = @intFromFloat(pos_scrn_);
    return @max(0, pos_scrn);
}

fn clamp_pos_scrn(self: *const Self, pos_scrn: u32) u32 {
    const max_pos_scrn = self.size_scrn -| self.view_scrn;
    return @min(pos_scrn, max_pos_scrn);
}

fn pos_scrn_to_virt(self: *const Self, pos_scrn_: u32) u32 {
    const pos_scrn: f64 = @floatFromInt(self.clamp_pos_scrn(pos_scrn_));
    const size_virt: f64 = @floatFromInt(self.size_virt);
    const size_scrn: f64 = @floatFromInt(self.plane.dim_y() * eighths_c);
    const ratio = size_virt / size_scrn;
    return @intFromFloat(pos_scrn * ratio);
}

fn is_pos_scrn_in_bar(self: *const Self, pos_scrn: u32) ?u32 {
    const max_pos_scrn = self.size_scrn -| self.view_scrn;
    const curr_pos_scrn = @min(self.pos_scrn, max_pos_scrn);
    return if (pos_scrn > curr_pos_scrn and pos_scrn <= curr_pos_scrn + self.view_scrn)
        curr_pos_scrn
    else
        null;
}

fn click_at(self: *Self, y: i32, ypx: i32) void {
    const pos_scrn = self.y_coord_to_pos_scrn(y, ypx);
    if (self.is_pos_scrn_in_bar(pos_scrn)) |curr_pos_scrn| {
        self.mouse_pos_scrn_offset = pos_scrn -| curr_pos_scrn;
    } else {
        self.mouse_pos_scrn_offset = self.view_scrn / 2;
        self.move_to(self.pos_scrn_to_virt(pos_scrn -| self.mouse_pos_scrn_offset));
    }
}

fn drag_to(self: *Self, y: i32, ypx: i32) void {
    const pos_scrn = self.y_coord_to_pos_scrn(y, ypx) -| self.mouse_pos_scrn_offset;
    const pos_virt = self.pos_scrn_to_virt(pos_scrn);
    self.move_to(pos_virt);
}

fn move_to(self: *Self, pos_virt: u32) void {
    self.set(self.size_virt, self.view_virt, pos_virt);
    _ = self.event_sink.msg(.{ "scroll_to", pos_virt }) catch {};
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const style = if (self.style_factory) |f|
        f(self, theme)
    else if (self.active)
        theme.scrollbar_active
    else if (self.hover)
        theme.scrollbar_hover
    else
        theme.scrollbar;
    const frame = tracy.initZone(@src(), .{ .name = "scrollbar_v render" });
    defer frame.deinit();
    self.plane.set_base_style(style);
    self.plane.erase();
    if (!(tui.config().scrollbar_auto_hide and self.size_scrn == self.view_scrn))
        smooth_bar_at(&self.plane, self.pos_scrn, self.view_scrn) catch {};
    return false;
}

pub fn set(self: *Self, size_virt_: u32, view_virt_: u32, pos_virt_: u32) void {
    self.pos_virt = pos_virt_;
    self.view_virt = view_virt_;
    self.size_virt = size_virt_;

    var size_virt: f64 = @floatFromInt(size_virt_);
    var view_virt: f64 = @floatFromInt(view_virt_);
    const pos_virt: f64 = @floatFromInt(pos_virt_);
    const size_scrn: f64 = @floatFromInt(self.plane.dim_y() * eighths_c);
    if (size_virt == 0) size_virt = 1;
    if (view_virt_ == 0) view_virt = 1;
    if (view_virt > size_virt) view_virt = size_virt;

    const ratio = size_virt / size_scrn;

    self.pos_scrn = @intFromFloat(pos_virt / ratio);
    self.view_scrn = @intFromFloat(view_virt / ratio);
    self.size_scrn = @intFromFloat(size_scrn);
}

const eighths_b = [_][]const u8{ "█", "▇", "▆", "▅", "▄", "▃", "▂", "▁" };
const eighths_t = [_][]const u8{ " ", "▔", "🮂", "🮃", "▀", "🮄", "🮅", "🮆" };
const eighths_c: u32 = eighths_b.len;

fn smooth_bar_at(plane: *Plane, pos_: u32, size_: u32) !void {
    const height: u32 = plane.dim_y();
    var size = @max(size_, 8);
    const pos = @min(height * eighths_c -| size, pos_);
    var pos_y: c_int = @intCast(@divFloor(pos, eighths_c));
    const blk = @mod(pos, eighths_c);
    const b = eighths_b[blk];
    plane.erase();
    plane.cursor_move_yx(pos_y, 0);
    _ = try plane.putstr(@ptrCast(b));
    size -= eighths_c -| blk;
    while (size >= 8) {
        pos_y += 1;
        size -= 8;
        plane.cursor_move_yx(pos_y, 0);
        _ = try plane.putstr(@ptrCast(eighths_b[0]));
    }
    if (size > 0) {
        pos_y += 1;
        plane.cursor_move_yx(pos_y, 0);
        const t = eighths_t[size];
        _ = try plane.putstr(@ptrCast(t));
    }
}
