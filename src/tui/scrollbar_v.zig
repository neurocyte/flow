const Allocator = @import("std").mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");

const Widget = @import("Widget.zig");
const EventHandler = @import("EventHandler.zig");
const tui = @import("tui.zig");

plane: nc.Plane,
pos_scrn: u32 = 0,
view_scrn: u32 = 8,
size_scrn: u32 = 8,

pos_virt: u32 = 0,
view_virt: u32 = 1,
size_virt: u32 = 1,

max_ypx: i32 = 8,

parent: Widget,
hover: bool = false,
active: bool = false,

const Self = @This();

pub fn create(a: Allocator, parent: Widget, event_source: Widget) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(parent);
    try event_source.subscribe(EventHandler.bind(self, handle_event));
    return self.widget();
}

fn init(parent: Widget) !Self {
    return .{
        .plane = try nc.Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent.plane.*),
        .parent = parent,
    };
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    a.destroy(self);
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

    if (try m.match(.{ "B", nc.event_type.PRESS, nc.key.BUTTON1, tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) })) {
        self.active = true;
        self.move_to(y, ypx);
        return true;
    } else if (try m.match(.{ "B", nc.event_type.RELEASE, tp.more })) {
        self.active = false;
        return true;
    } else if (try m.match(.{ "D", nc.event_type.PRESS, nc.key.BUTTON1, tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) })) {
        self.active = true;
        self.move_to(y, ypx);
        return true;
    } else if (try m.match(.{ "B", nc.event_type.RELEASE, tp.more })) {
        self.active = false;
        return true;
    } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
        self.active = false;
        return true;
    }

    return false;
}

fn move_to(self: *Self, y_: i32, ypx_: i32) void {
    self.max_ypx = @max(self.max_ypx, ypx_);
    const max_ypx: f64 = @floatFromInt(self.max_ypx);
    const y: f64 = @floatFromInt(y_);
    const ypx: f64 = @floatFromInt(ypx_);
    const plane_y: f64 = @floatFromInt(self.plane.abs_y());
    const size_scrn: f64 = @floatFromInt(self.size_scrn);
    const view_scrn: f64 = @floatFromInt(self.view_scrn);

    const ratio = max_ypx / eighths_c;
    const pos_scrn: f64 = ((y - plane_y) * eighths_c) + (ypx / ratio) - (view_scrn / 2);
    const max_pos_scrn = size_scrn - view_scrn;
    const pos_scrn_clamped = @min(@max(0, pos_scrn), max_pos_scrn);
    const pos_virt = self.pos_scrn_to_virt(@intFromFloat(pos_scrn_clamped));

    self.set(self.size_virt, self.view_virt, pos_virt);
    _ = self.parent.msg(.{ "scroll_to", pos_virt }) catch {};
}

fn pos_scrn_to_virt(self: Self, pos_scrn_: u32) u32 {
    const size_virt: f64 = @floatFromInt(self.size_virt);
    const size_scrn: f64 = @floatFromInt(self.plane.dim_y() * eighths_c);
    const pos_scrn: f64 = @floatFromInt(pos_scrn_);
    const ratio = size_virt / size_scrn;
    return @intFromFloat(pos_scrn * ratio);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = "scrollbar_v render" });
    defer frame.deinit();
    tui.set_base_style(&self.plane, " ", if (self.active) theme.scrollbar_active else if (self.hover) theme.scrollbar_hover else theme.scrollbar);
    self.plane.erase();
    smooth_bar_at(self.plane, @intCast(self.pos_scrn), @intCast(self.view_scrn)) catch {};
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
const eighths_c: i32 = @intCast(eighths_b.len);

fn smooth_bar_at(plane: nc.Plane, pos_: i32, size_: i32) !void {
    const height: i32 = @intCast(plane.dim_y());
    var size = @max(size_, 8);
    const pos: i32 = @min(height * eighths_c - size, pos_);
    var pos_y = @as(c_int, @intCast(@divFloor(pos, eighths_c)));
    const blk = @mod(pos, eighths_c);
    const b = eighths_b[@intCast(blk)];
    plane.erase();
    plane.cursor_move_yx(pos_y, 0) catch return;
    _ = try plane.putstr(@ptrCast(b));
    size -= @as(u16, @intCast(eighths_c)) - @as(u16, @intCast(blk));
    while (size >= 8) {
        pos_y += 1;
        size -= 8;
        plane.cursor_move_yx(pos_y, 0) catch return;
        _ = try plane.putstr(@ptrCast(eighths_b[0]));
    }
    if (size > 0) {
        pos_y += 1;
        plane.cursor_move_yx(pos_y, 0) catch return;
        const t = eighths_t[size];
        _ = try plane.putstr(@ptrCast(t));
    }
}
