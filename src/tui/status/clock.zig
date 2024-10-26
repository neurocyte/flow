const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const zeit = @import("zeit");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");

allocator: std.mem.Allocator,
plane: Plane,
tick_timer: ?tp.Cancellable = null,
on_event: ?EventHandler,
tz: zeit.timezone.TimeZone,

const Self = @This();

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler) @import("widget.zig").CreateError!Widget {
    var env = std.process.getEnvMap(allocator) catch |e| return tp.exit_error(e, @errorReturnTrace());
    defer env.deinit();
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .on_event = event_handler,
        .tz = zeit.local(allocator, &env) catch |e| return tp.exit_error(e, @errorReturnTrace()),
    };
    try tui.current().message_filters.add(MessageFilter.bind(self, receive_tick));
    self.update_tick_timer(.init);
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    tui.current().message_filters.remove_ptr(self);
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
    self.plane.set_base_style(" ", theme.statusbar);
    self.plane.erase();
    self.plane.home();

    const now = zeit.instant(.{ .timezone = &self.tz }) catch return false;
    const dt = now.time();
    _ = self.plane.print("{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute }) catch {};
    return false;
}

fn receive_tick(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (try cbor.match(m.buf, .{"CLOCK"})) {
        tui.need_render();
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
