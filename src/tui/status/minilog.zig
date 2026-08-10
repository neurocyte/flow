const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const MouseEvent = @import("MouseEvent");
const log = @import("log");
const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");
const logview = @import("../logview.zig");

plane: Plane,
msg: std.Io.Writer.Allocating,
msg_counter: usize = 0,
clear_timer: ?tp.Cancellable = null,
level: Level = .info,
on_event: ?EventHandler,
overlay: ?*tui.WidgetLayerBox = null,

const message_display_time_seconds = 2;
const error_display_time_seconds = 4;
const Self = @This();

const Level = enum {
    info,
    err,
};

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler, _: ?[]const u8) @import("widget.zig").CreateError!Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .msg = .init(allocator),
        .on_event = event_handler,
    };
    logview.init(allocator);
    try tui.message_filters().add(MessageFilter.bind(self, receive_log));
    log.subscribe() catch return error.WidgetInitFailed;
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.overlay) |layer| layer.deinit(allocator);
    if (self.clear_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.clear_timer = null;
    }
    self.msg.deinit();
    log.unsubscribe() catch {};
    tui.message_filters().remove_ptr(self);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ MouseEvent.Type.drag, tp.more })) {
        if (self.on_event) |h| h.send(from, m) catch {};
        return true;
    }
    return false;
}

pub fn layout(self: *Self) Widget.Layout {
    if (self.msg.written().len == 0) return .{ .static = 1 };
    if (self.overlay_needed()) return .{ .static = 1 };
    return .{ .static = self.msg.written().len + 2 };
}

fn overlay_needed(self: *Self) bool {
    const msg = self.msg.written();
    if (msg.len == 0) return false;
    if (tui.mini_mode() != null) return true;
    const width = tui.egc_chunk_width(msg, 0, 8);
    return width > tui.screen().w / 3;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const style_normal = theme.statusbar;
    const style_info: Widget.Theme.Style = .{ .fg = theme.statusbar.fg, .fs = theme.editor_information.fs };
    const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs };
    const msg_style = if (self.level == .err) style_error else style_info;
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(style_normal);
    self.plane.fill(" ");
    self.plane.home();

    const msg = self.msg.written();
    if (!self.overlay_needed()) {
        self.plane.set_style(msg_style);
        _ = self.plane.print(" {s} ", .{msg}) catch {};
    } else {
        const needed = 1 + tui.egc_chunk_width(msg, 0, 8) + 1;
        self.render_overlay(theme, msg, msg_style, needed) catch {
            self.plane.set_style(msg_style);
            _ = self.plane.print(" {s} ", .{msg}) catch {};
        };
    }
    return false;
}

fn render_overlay(self: *Self, theme: *const Widget.Theme, msg: []const u8, msg_style: Widget.Theme.Style, needed: usize) !void {
    const screen = tui.screen();
    const cw: i32 = self.plane.cell_x();
    const ch: i32 = self.plane.cell_y();
    _, const py = self.plane.global_origin_px(); // status bar top, in pixels
    const overlay_y_px = py - ch; // one row above the status bar
    if (overlay_y_px < 0) return error.NoSpace;

    const screen_width_px: i32 = @as(i32, @intCast(screen.w)) * cw + screen.extra_x;
    const text_width_px: i32 = @as(i32, @intCast(needed)) * cw;
    const overlay_width_px = @min(text_width_px, screen_width_px);
    if (overlay_width_px <= 0) return error.NoSpace;
    const overlay_x_px = screen_width_px - overlay_width_px; // right aligned; 0 when clipped
    const w_cells: usize = @intCast(@max(1, @divFloor(overlay_width_px + cw - 1, cw)));

    const layer = self.overlay orelse blk: {
        const new_layer = try tui.WidgetLayerBox.create(self.msg.allocator, tui.plane(), .{ .name = "minilog.layer" });
        new_layer.shadow = .{ .edges = .{ .bottom = false, .right = false } };
        self.overlay = new_layer;
        break :blk new_layer;
    };
    layer.handle_resize(.{
        .w = w_cells,
        .h = 1,
        .frame = .{ .x = overlay_x_px, .y = overlay_y_px, .w = overlay_width_px, .h = ch },
    });

    var plane = layer.inner_plane();
    plane.set_base_style(theme.statusbar);
    plane.erase();
    plane.home();
    plane.set_style(theme.statusbar);
    plane.fill(" ");
    plane.home();
    plane.set_style(msg_style);
    _ = plane.print(" {s} ", .{msg}) catch {};
    if (text_width_px > overlay_width_px) {
        plane.cursor_move_yx(0, @intCast(w_cells -| 2));
        _ = plane.print("… ", .{}) catch {};
    }
    _ = layer.widget().render(theme);
}

fn receive_log(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var clear_msg_num: usize = 0;
    if (try cbor.match(m.buf, .{ "log", tp.more })) {
        try logview.process_log(m);
        try self.process_log(m);
        return true;
    } else if (try cbor.match(m.buf, .{ "message", tp.more })) {
        try self.process_message(m);
        return true;
    } else if (try cbor.match(m.buf, .{ "MINILOG", tp.extract(&clear_msg_num) })) {
        if (clear_msg_num == self.msg_counter)
            self.clear();
        return true;
    }
    return false;
}

fn process_log(self: *Self, m: tp.message) MessageFilter.Error!void {
    var src: []const u8 = undefined;
    var context: []const u8 = undefined;
    var msg: []const u8 = undefined;
    if (try cbor.match(m.buf, .{ "log", tp.extract(&src), tp.extract(&msg) })) {
        try self.set(msg, .info);
    } else if (try cbor.match(m.buf, .{ "log", "error", tp.extract(&src), tp.extract(&context), "->", tp.extract(&msg) })) {
        const err_stop = "error.Stop";
        if (std.mem.eql(u8, msg, err_stop))
            return;
        if (msg.len >= err_stop.len + 1 and std.mem.eql(u8, msg[0 .. err_stop.len + 1], err_stop ++ "\n"))
            return;
        try self.set(msg, .err);
    } else if (try cbor.match(m.buf, .{ "log", tp.extract(&src), tp.more })) {
        self.level = .err;
        var s: std.json.Stringify = .{ .writer = &self.msg.writer };
        var iter: []const u8 = m.buf;
        try @import("cbor").JsonWriter.jsonWriteValue(&s, &iter);
        Widget.need_render();
        try self.update_clear_timer();
    }
}

fn process_message(self: *Self, m: tp.message) MessageFilter.Error!void {
    var msg: []const u8 = undefined;
    if (try cbor.match(m.buf, .{ tp.string, tp.extract(&msg) }))
        try self.set(msg, .info);
}

fn update_clear_timer(self: *Self) !void {
    self.msg_counter += 1;
    const delay = std.time.us_per_s * @as(u64, if (self.level == .err) error_display_time_seconds else message_display_time_seconds);
    if (self.clear_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.clear_timer = null;
    }
    self.clear_timer = try tp.self_pid().delay_send_cancellable(self.msg.allocator, "minilog.clear_timer", delay, .{ "MINILOG", self.msg_counter });
}

fn set(self: *Self, msg: []const u8, level: Level) !void {
    if (@intFromEnum(level) < @intFromEnum(self.level)) return;
    self.msg.clearRetainingCapacity();
    var iter = std.mem.splitScalar(u8, msg, '\n');
    const line1 = iter.next() orelse msg;
    try self.msg.writer.writeAll(line1);
    self.level = level;
    Widget.need_render();
    try self.update_clear_timer();
}

fn clear(self: *Self) void {
    if (self.clear_timer) |*t| {
        t.deinit();
        self.clear_timer = null;
    }
    self.level = .info;
    self.msg.clearRetainingCapacity();
    Widget.need_render();
}
