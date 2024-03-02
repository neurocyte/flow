const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");
const log = @import("log");

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");
const mainview = @import("../mainview.zig");

parent: nc.Plane,
plane: nc.Plane,
msg: std.ArrayList(u8),
is_error: bool = false,
clear_time: i64 = 0,

const message_display_time_seconds = 2;
const error_display_time_seconds = 4;
const Self = @This();

pub fn create(a: std.mem.Allocator, parent: nc.Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = .{
        .parent = parent,
        .plane = try nc.Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .msg = std.ArrayList(u8).init(a),
    };
    try tui.current().message_filters.add(MessageFilter.bind(self, log_receive));
    try log.subscribe();
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    self.msg.deinit();
    log.unsubscribe() catch {};
    tui.current().message_filters.remove_ptr(self);
    self.plane.deinit();
    a.destroy(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return .{ .static = if (self.msg.items.len > 0) self.msg.items.len + 2 else 1 };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    tui.set_base_style(&self.plane, " ", if (self.msg.items.len > 0) theme.sidebar else theme.statusbar);
    self.plane.erase();
    self.plane.home();
    if (self.is_error)
        tui.set_base_style(&self.plane, " ", theme.editor_error);
    _ = self.plane.print(" {s} ", .{self.msg.items}) catch return false;

    const curr_time = std.time.milliTimestamp();
    if (curr_time < self.clear_time)
        return true;

    if (self.msg.items.len > 0) self.clear();
    return false;
}

pub fn log_receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "log", tp.more })) {
        self.log_process(m) catch |e| return tp.exit_error(e);
        if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.logview_enabled)
            return false; // pass on log messages to logview
        return true;
    }
    return false;
}

pub fn log_process(self: *Self, m: tp.message) !void {
    var src: []const u8 = undefined;
    var context: []const u8 = undefined;
    var msg: []const u8 = undefined;
    if (try m.match(.{ "log", tp.extract(&src), tp.extract(&msg) })) {
        if (self.is_error) return;
        try self.set(msg, false);
    } else if (try m.match(.{ "log", "error", tp.extract(&src), tp.extract(&context), "->", tp.extract(&msg) })) {
        try self.set(msg, true);
    } else if (try m.match(.{ "log", tp.extract(&src), tp.more })) {
        self.is_error = true;
        var s = std.json.writeStream(self.msg.writer(), .{});
        var iter: []const u8 = m.buf;
        try @import("cbor").JsonStream(@TypeOf(self.msg)).jsonWriteValue(&s, &iter);
        self.update_clear_time();
        Widget.need_render();
    }
}

fn update_clear_time(self: *Self) void {
    const delay: i64 = std.time.ms_per_s * @as(i64, if (self.is_error) error_display_time_seconds else message_display_time_seconds);
    self.clear_time = std.time.milliTimestamp() + delay;
}

fn set(self: *Self, msg: []const u8, is_error: bool) !void {
    self.msg.clearRetainingCapacity();
    try self.msg.appendSlice(msg);
    self.is_error = is_error;
    self.update_clear_time();
    Widget.need_render();
}

fn clear(self: *Self) void {
    self.is_error = false;
    self.msg.clearRetainingCapacity();
    self.clear_time = 0;
    Widget.need_render();
}
