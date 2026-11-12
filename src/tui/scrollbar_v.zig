const Allocator = @import("std").mem.Allocator;
const clamp = @import("std").math.clamp;
const tp = @import("thespian");
const tracy = @import("tracy");

const Plane = @import("renderer").Plane;
const Layer = @import("renderer").Layer;
const build_options = @import("build_options");
const MouseEvent = @import("MouseEvent");
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const ScrollLayer = @import("ScrollLayer.zig");

allocator: Allocator,
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
hidden: bool = false,
precise: bool = false,
pixel_track: bool = false,
forward_scroll: bool = false,
track_layer: ?ScrollLayer = null,
frame_h: u32 = 0,
track_layer_id: ?Layer.Id = null,
style_factory: ?*const fn (self: *Self, theme: *const Widget.Theme) Widget.Theme.Style = null,

const Self = @This();

pub fn create(allocator: Allocator, parent: Plane, event_source: ?Widget, event_sink: EventHandler) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
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
    if (self.track_layer) |*l| l.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return .{ .static = if (self.hidden) 0 else 1 };
}

pub fn handle_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var size: u32 = 0;
    var view: u32 = 0;
    var pos: u32 = 0;
    if (try m.match(.{ "E", "view", tp.extract(&size), tp.extract(&view), tp.extract(&pos) }))
        self.set(size, view, pos);
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var coord: MouseEvent.Coord = undefined;
    var btn: MouseEvent.Button = .none;
    const old_hover = self.hover;

    if (self.forward_scroll and (try m.match(.{ "scroll", tp.more }) or
        (try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.more }) and is_wheel(btn))))
    {
        self.event_sink.send(from, m) catch {};
        return true;
    }

    if (try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.left, tp.extract(&coord), tp.any })) {
        const cell = coord.to_cell(self.plane.mouse_geometry());
        self.active = true;
        self.update_max_ypx(cell.yoffset);
        self.click_at(cell.row, cell.yoffset);
        return true;
    } else if (try m.match(.{ MouseEvent.Type.release, MouseEvent.Button.left, tp.more })) {
        self.active = false;
        return true;
    } else if (try m.match(.{ MouseEvent.Type.drag, MouseEvent.Button.left, tp.extract(&coord), tp.any })) {
        const cell = coord.to_cell(self.plane.mouse_geometry());
        self.active = true;
        self.update_max_ypx(cell.yoffset);
        self.drag_to(cell.row, cell.yoffset);
        return true;
    } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
        tui.rdr().request_mouse_cursor(.default, self.hover);
        if (old_hover != self.hover)
            tui.need_render(@src());
        return true;
    }

    return false;
}

fn is_wheel(btn: MouseEvent.Button) bool {
    return switch (btn) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
        else => false,
    };
}

fn update_max_ypx(self: *Self, ypx_: i32) void {
    self.max_ypx = @max(self.max_ypx, ypx_);
}

fn y_coord_to_pos_scrn(self: *const Self, y_: i32, ypx_: i32) u32 {
    const max_ypx: f64 = @floatFromInt(self.max_ypx);
    const y: f64 = @floatFromInt(y_);
    const ypx: f64 = @floatFromInt(ypx_);

    const ratio = max_ypx / eighths_c;
    const pos_scrn_ = (y * eighths_c) + (ypx / ratio);
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
    const size_scrn: f64 = @floatFromInt(self.track_scrn());
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
        if (self.precise) return self.move_to_fraction(y, ypx);
        self.move_to(self.pos_scrn_to_virt(pos_scrn -| self.mouse_pos_scrn_offset));
    }
}

fn fraction_at(self: *const Self, y: i32, ypx: i32) f64 {
    const ch: f64 = @floatFromInt(@max(1, self.plane.cell_y()));
    const pointer: f64 = @as(f64, @floatFromInt(y)) * eighths_c + @as(f64, @floatFromInt(ypx)) * eighths_c / ch;
    const travel: f64 = @floatFromInt(self.size_scrn -| self.view_scrn);
    if (travel <= 0) return 0;
    const offset: f64 = @floatFromInt(self.mouse_pos_scrn_offset);
    return clamp((pointer - offset) / travel, 0, 1);
}

fn move_to_fraction(self: *Self, y: i32, ypx: i32) void {
    const fraction = self.fraction_at(y, ypx);
    const max_virt: f64 = @floatFromInt(self.size_virt -| self.view_virt);
    self.set(self.size_virt, self.view_virt, @intFromFloat(fraction * max_virt));
    _ = self.event_sink.msg(.{ "scroll_to_fraction", fraction }) catch {};
}

fn drag_to(self: *Self, y: i32, ypx: i32) void {
    if (self.precise) return self.move_to_fraction(y, ypx);
    const pos_scrn = self.y_coord_to_pos_scrn(y, ypx) -| self.mouse_pos_scrn_offset;
    const pos_virt = self.pos_scrn_to_virt(pos_scrn);
    self.move_to(pos_virt);
}

fn move_to(self: *Self, pos_virt: u32) void {
    self.set(self.size_virt, self.view_virt, pos_virt);
    _ = self.event_sink.msg(.{ "scroll_to", pos_virt }) catch {};
}

pub fn panel_style(self: *Self, theme: *const Widget.Theme) Widget.Theme.Style {
    return self.style_on(theme, theme.panel);
}

pub fn editor_widget_style(self: *Self, theme: *const Widget.Theme) Widget.Theme.Style {
    return self.style_on(theme, theme.editor_widget);
}

pub fn editor_style(self: *Self, theme: *const Widget.Theme) Widget.Theme.Style {
    return self.style_on(theme, theme.editor);
}

fn style_on(self: *const Self, theme: *const Widget.Theme, background: Widget.Theme.Style) Widget.Theme.Style {
    const fg = if (self.active)
        theme.scrollbar_active.fg
    else if (self.hover)
        theme.scrollbar_hover.fg
    else
        theme.scrollbar.fg;
    return .{ .fg = fg, .bg = background.bg };
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
    if (self.use_track_layer()) {
        self.render_track_layer(style);
        return false;
    }
    if (self.bar_visible())
        smooth_bar_at(&self.plane, self.pos_scrn, self.view_scrn, self.size_scrn) catch {};
    return false;
}

fn bar_visible(self: *const Self) bool {
    return !(tui.config().scrollbar_auto_hide and self.size_scrn == self.view_scrn);
}

fn use_track_layer(self: *const Self) bool {
    return build_options.gui and self.pixel_track and !self.hidden;
}

fn track_px(self: *const Self) u32 {
    if (self.frame_h > 0) return self.frame_h;
    return @intCast(@max(0, self.plane.pixel_frame().h));
}

fn track_scrn(self: *const Self) u32 {
    if (!build_options.gui or !(self.precise or self.use_track_layer())) return self.plane.dim_y() * eighths_c;
    const ch: u32 = @max(1, self.plane.cell_y());
    return (self.track_px() * eighths_c + ch - 1) / ch;
}

fn render_track_layer(self: *Self, style: Widget.Theme.Style) void {
    if (self.track_layer == null)
        self.track_layer = ScrollLayer.init(self.allocator, &self.track_layer_id) catch return;
    const track_layer = &self.track_layer.?;
    const view = self.plane;
    defer self.plane = view;
    const ch: u32 = @max(1, view.cell_y());
    track_layer.prepare(&view, (self.track_px() + ch - 1) / ch, view.dim_x());
    self.plane = track_layer.plane;
    self.plane.set_base_style(style);
    self.plane.erase();
    if (self.bar_visible())
        smooth_bar_at(&self.plane, self.pos_scrn, self.view_scrn, self.size_scrn) catch {};
    track_layer.submit(&view, .{ .col = 0, .row = 0 }, .{ 0, self.track_px() }, .{});
}

pub fn set(self: *Self, size_virt_: u32, view_virt_: u32, pos_virt_: u32) void {
    self.pos_virt = pos_virt_;
    self.view_virt = view_virt_;
    self.size_virt = size_virt_;

    var size_virt: f64 = @floatFromInt(size_virt_);
    var view_virt: f64 = @floatFromInt(view_virt_);
    const pos_virt: f64 = @floatFromInt(pos_virt_);
    const size_scrn: f64 = @floatFromInt(self.track_scrn());
    if (size_virt == 0) size_virt = 1;
    if (view_virt_ == 0) view_virt = 1;
    if (view_virt > size_virt) view_virt = size_virt;

    const ratio = size_virt / size_scrn;

    const pos_scrn: u32 = @intFromFloat(@round(pos_virt / ratio));
    const end_scrn: u32 = @intFromFloat(@round(@min(size_virt, pos_virt + view_virt) / ratio));
    self.pos_scrn = pos_scrn;
    self.view_scrn = end_scrn -| pos_scrn;
    self.size_scrn = @intFromFloat(size_scrn);
}

const eighths_b = [_][]const u8{ "█", "▇", "▆", "▅", "▄", "▃", "▂", "▁" };
const eighths_t = [_][]const u8{ " ", "▔", "🮂", "🮃", "▀", "🮄", "🮅", "🮆" };
const eighths_c: u32 = eighths_b.len;

fn smooth_bar_at(plane: *Plane, pos_: u32, size_: u32, track_: u32) !void {
    const track = if (track_ > 0) track_ else plane.dim_y() * eighths_c;
    var size = @max(size_, 8);
    const pos = @min(track -| size, pos_);
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
