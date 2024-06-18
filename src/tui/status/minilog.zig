const std = @import("std");
const tp = @import("thespian");
const log = @import("log");

const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");
const mainview = @import("../mainview.zig");
const logview = @import("../logview.zig");

parent: Plane,
plane: Plane,
msg: std.ArrayList(u8),
msg_counter: usize = 0,
clear_timer: ?tp.Cancellable = null,
level: Level = .info,

const message_display_time_seconds = 2;
const error_display_time_seconds = 4;
const Self = @This();

const Level = enum {
    info,
    err,
};

pub fn create(a: std.mem.Allocator, parent: Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = .{
        .parent = parent,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .msg = std.ArrayList(u8).init(a),
    };
    logview.init(a);
    try tui.current().message_filters.add(MessageFilter.bind(self, receive_log));
    try log.subscribe();
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    if (self.clear_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.clear_timer = null;
    }
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
    const style_normal = theme.statusbar;
    const style_info: Widget.Theme.Style = .{ .fg = theme.statusbar.fg, .fs = theme.editor_information.fs };
    const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs };
    self.plane.set_base_style(" ", style_normal);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(if (self.level == .err) style_error else style_info);
    _ = self.plane.print(" {s} ", .{self.msg.items}) catch {};
    return false;
}

fn receive_log(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var clear_msg_num: usize = 0;
    if (try m.match(.{ "log", tp.more })) {
        logview.process_log(m) catch |e| return tp.exit_error(e);
        self.process_log(m) catch |e| return tp.exit_error(e);
        return true;
    } else if (try m.match(.{ "MINILOG", tp.extract(&clear_msg_num) })) {
        if (clear_msg_num == self.msg_counter)
            self.clear();
        return true;
    }
    return false;
}

fn process_log(self: *Self, m: tp.message) !void {
    var src: []const u8 = undefined;
    var context: []const u8 = undefined;
    var msg: []const u8 = undefined;
    if (try m.match(.{ "log", tp.extract(&src), tp.extract(&msg) })) {
        try self.set(msg, .info);
    } else if (try m.match(.{ "log", "error", tp.extract(&src), tp.extract(&context), "->", tp.extract(&msg) })) {
        if (std.mem.eql(u8, msg, "error.Stop"))
            return;
        try self.set(msg, .err);
    } else if (try m.match(.{ "log", tp.extract(&src), tp.more })) {
        self.level = .err;
        var s = std.json.writeStream(self.msg.writer(), .{});
        var iter: []const u8 = m.buf;
        try @import("cbor").JsonStream(@TypeOf(self.msg)).jsonWriteValue(&s, &iter);
        Widget.need_render();
        try self.update_clear_timer();
    }
}

fn update_clear_timer(self: *Self) !void {
    self.msg_counter += 1;
    const delay = std.time.us_per_s * @as(u64, if (self.level == .err) error_display_time_seconds else message_display_time_seconds);
    if (self.clear_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.clear_timer = null;
    }
    self.clear_timer = try tp.self_pid().delay_send_cancellable(self.msg.allocator, delay, .{ "MINILOG", self.msg_counter });
}

fn set(self: *Self, msg: []const u8, level: Level) !void {
    if (@intFromEnum(level) < @intFromEnum(self.level)) return;
    self.msg.clearRetainingCapacity();
    try self.msg.appendSlice(msg);
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
