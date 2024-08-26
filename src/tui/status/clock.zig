const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const zeit = @import("zeit");

const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");
const mainview = @import("../mainview.zig");
const logview = @import("../logview.zig");

allocator: std.mem.Allocator,
plane: Plane,
tick_timer: ?tp.Cancellable = null,
on_event: ?Widget.EventHandler,
tz: zeit.timezone.TimeZone,

const message_display_time_seconds = 2;
const error_display_time_seconds = 4;
const Self = @This();

const Level = enum {
    info,
    err,
};

pub fn create(a: std.mem.Allocator, parent: Plane, event_handler: ?Widget.EventHandler) @import("widget.zig").CreateError!Widget {
    var env = std.process.getEnvMap(a) catch |e| return tp.exit_error(e, @errorReturnTrace());
    defer env.deinit();
    const self: *Self = try a.create(Self);
    self.* = .{
        .allocator = a,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .on_event = event_handler,
        .tz = zeit.local(a, &env) catch |e| return tp.exit_error(e, @errorReturnTrace()),
    };
    try tui.current().message_filters.add(MessageFilter.bind(self, receive_tick));
    self.update_tick_timer();
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    tui.current().message_filters.remove_ptr(self);
    if (self.tick_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.tick_timer = null;
    }
    self.tz.deinit();
    self.plane.deinit();
    a.destroy(self);
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

    const now = zeit.instant(.{}) catch return false;
    const now_local = now.in(&self.tz);
    const dt = now_local.time();
    _ = self.plane.print("{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute }) catch {};
    return false;
}

fn receive_tick(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{"CLOCK"})) {
        tui.need_render();
        self.update_tick_timer();
        return true;
    }
    return false;
}

fn update_tick_timer(self: *Self) void {
    const current_time: usize = @intCast(std.time.milliTimestamp());
    const ms_delay_until_tick = current_time % std.time.ms_per_s;
    const s_delay_until_tick = current_time % std.time.ms_per_min;
    const delay = s_delay_until_tick + ms_delay_until_tick;
    if (self.tick_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.tick_timer = null;
    }
    self.tick_timer = tp.self_pid().delay_send_cancellable(self.allocator, delay, .{"CLOCK"}) catch null;
}
