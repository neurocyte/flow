const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const zeit = @import("zeit");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");
const fonts = @import("../fonts.zig");

const DigitStyle = fonts.DigitStyle;

allocator: std.mem.Allocator,
plane: Plane,
tick_timer: ?tp.Cancellable = null,
on_event: ?EventHandler,
tz: zeit.timezone.TimeZone,
style: ?DigitStyle,

const Self = @This();

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler, arg: ?[]const u8) @import("widget.zig").CreateError!Widget {
    const style: ?DigitStyle = if (arg) |style| std.meta.stringToEnum(DigitStyle, style) orelse null else null;

    var env = std.process.getEnvMap(allocator) catch |e| {
        std.log.err("clock: std.process.getEnvMap failed with {any}", .{e});
        return error.WidgetInitFailed;
    };
    defer env.deinit();
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .on_event = event_handler,
        .tz = zeit.local(allocator, &env) catch |e| {
            std.log.err("clock: zeit.local failed with {any}", .{e});
            return error.WidgetInitFailed;
        },
        .style = style,
    };
    try tui.message_filters().add(MessageFilter.bind(self, receive_tick));
    self.update_tick_timer(.init);
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    tui.message_filters().remove_ptr(self);
    if (self.tick_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.tick_timer = null;
    }
    self.tz.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var btn: u32 = 0;
    if (try m.match(.{ "D", tp.any, tp.extract(&btn), tp.more })) {
        if (self.on_event) |h| h.send(from, m) catch {};
        return true;
    }
    return false;
}

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = 5 };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(theme.statusbar);
    self.plane.fill(" ");
    self.plane.home();

    const now = zeit.instant(.{ .timezone = &self.tz }) catch return false;
    const dt = now.time();

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    std.fmt.format(writer, "{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute }) catch {};

    const value_str = fbs.getWritten();
    for (value_str, 0..) |_, i| _ = self.plane.putstr(fonts.get_digit_ascii(value_str[i .. i + 1], self.style orelse .ascii)) catch {};
    return false;
}

fn receive_tick(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (try cbor.match(m.buf, .{"CLOCK"})) {
        tui.need_render(@src());
        self.update_tick_timer(.ticked);
        return true;
    }
    return false;
}

fn update_tick_timer(self: *Self, event: enum { init, ticked }) void {
    if (self.tick_timer) |*t| {
        if (event != .ticked) t.cancel() catch {};
        t.deinit();
        self.tick_timer = null;
    }
    const current = zeit.instant(.{ .timezone = &self.tz }) catch return;
    var next = current.time();
    next.minute += 1;
    next.second = 0;
    next.millisecond = 0;
    next.microsecond = 0;
    next.nanosecond = 0;
    const delay_us: u64 = @intCast(@divTrunc(next.instant().timestamp - current.timestamp, std.time.ns_per_us));
    self.tick_timer = tp.self_pid().delay_send_cancellable(self.allocator, "clock.tick_timer", delay_us, .{"CLOCK"}) catch null;
}
