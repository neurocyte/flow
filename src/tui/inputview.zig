const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;
const Mutex = @import("std").Thread.Mutex;

const tp = @import("thespian");

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const EventHandler = @import("EventHandler.zig");

pub const name = "inputview";

parent: Plane,
plane: Plane,
lastbuf: [4096]u8 = undefined,
last: []u8 = "",
last_count: u64 = 0,
last_time: i64 = 0,
last_tdiff: i64 = 0,

const Self = @This();

pub fn create(a: Allocator, parent: Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(parent);
    try tui.current().input_listeners.add(EventHandler.bind(self, listen));
    return Widget.to(self);
}

fn init(parent: Plane) !Self {
    var n = try Plane.init(&(Widget.Box{}).opts_vscroll(@typeName(Self)), parent);
    errdefer n.deinit();
    return .{
        .parent = parent,
        .plane = n,
        .last_time = time.microTimestamp(),
    };
}

pub fn deinit(self: *Self, a: Allocator) void {
    tui.current().input_listeners.remove_ptr(self);
    self.plane.deinit();
    a.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(" ", theme.panel);
    return false;
}

fn output_tdiff(self: *Self, tdiff: i64) !void {
    const msi = @divFloor(tdiff, time.us_per_ms);
    if (msi == 0) {
        const d: f64 = @floatFromInt(tdiff);
        const ms = d / time.us_per_ms;
        _ = try self.plane.print("{d:6.2}▎", .{ms});
    } else {
        const ms: u64 = @intCast(msi);
        _ = try self.plane.print("{d:6}▎", .{ms});
    }
}

fn output_new(self: *Self, json: []const u8) !void {
    if (self.plane.cursor_x() != 0)
        _ = try self.plane.putstr("\n");
    const ts = time.microTimestamp();
    const tdiff = ts - self.last_time;
    self.last_count = 0;
    self.last = self.lastbuf[0..json.len];
    @memcpy(self.last, json);
    try self.output_tdiff(tdiff);
    _ = try self.plane.print("{s}", .{json});
    self.last_time = ts;
    self.last_tdiff = tdiff;
}

fn output_repeat(self: *Self, json: []const u8) !void {
    if (self.plane.cursor_x() != 0)
        try self.plane.cursor_move_yx(-1, 0);
    self.last_count += 1;
    try self.output_tdiff(self.last_tdiff);
    _ = try self.plane.print("{s} ({})", .{ json, self.last_count });
}

fn output(self: *Self, json: []const u8) !void {
    return if (!eql(u8, json, self.last))
        self.output_new(json)
    else
        self.output_repeat(json);
}

pub fn listen(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ "M", tp.more })) return;
    var buf: [4096]u8 = undefined;
    const json = m.to_json(&buf) catch |e| return tp.exit_error(e);
    self.output(json) catch |e| return tp.exit_error(e);
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}
