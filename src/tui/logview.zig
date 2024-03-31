const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;
const Mutex = @import("std").Thread.Mutex;

const nc = @import("notcurses");
const tp = @import("thespian");
const log = @import("log");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");

const escape = fmt.fmtSliceEscapeLower;
const A = nc.Align;

pub const name = @typeName(Self);

plane: nc.Plane,
lastbuf_src: [128]u8 = undefined,
lastbuf_msg: [log.max_log_message]u8 = undefined,
last_src: []u8 = "",
last_msg: []u8 = "",
last_count: u64 = 0,
last_time: i64 = 0,
last_tdiff: i64 = 0,

const Self = @This();

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = init(parent) catch |e| return tp.exit_error(e);
    try tui.current().message_filters.add(MessageFilter.bind(self, log_receive));
    return Widget.to(self);
}

fn init(parent: nc.Plane) !Self {
    var n = try nc.Plane.init(&(Widget.Box{}).opts_vscroll(name), parent);
    errdefer n.deinit();
    return .{
        .plane = n,
        .last_time = time.microTimestamp(),
    };
}

pub fn deinit(self: *Self, a: Allocator) void {
    tui.current().message_filters.remove_ptr(self);
    self.plane.deinit();
    a.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    tui.set_base_style(&self.plane, " ", theme.panel);
    return false;
}

pub fn log_receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "log", tp.more })) {
        self.log_process(m) catch |e| return tp.exit_error(e);
        return true;
    }
    return false;
}

pub fn log_process(self: *Self, m: tp.message) !void {
    var src: []const u8 = undefined;
    var context: []const u8 = undefined;
    var msg: []const u8 = undefined;
    if (try m.match(.{ "log", tp.extract(&src), tp.extract(&msg) })) {
        try self.output(src, msg);
    } else if (try m.match(.{ "log", "error", tp.extract(&src), tp.extract(&context), "->", tp.extract(&msg) })) {
        try self.output_error(src, context, msg);
    } else if (try m.match(.{ "log", tp.extract(&src), tp.more })) {
        try self.output_json(src, m);
    }
}

fn output_tdiff(self: *Self, tdiff: i64) !void {
    const msi = @divFloor(tdiff, time.us_per_ms);
    if (msi == 0) {
        const d: f64 = @floatFromInt(tdiff);
        const ms = d / time.us_per_ms;
        _ = try self.plane.print("\n{d:6.2} ▏", .{ms});
    } else {
        const ms: u64 = @intCast(msi);
        _ = try self.plane.print("\n{d:6} ▏", .{ms});
    }
}

fn output_new(self: *Self, src: []const u8, msg: []const u8) !void {
    const ts = time.microTimestamp();
    const tdiff = ts - self.last_time;
    self.last_count = 0;
    self.last_src = self.lastbuf_src[0..src.len];
    self.last_msg = self.lastbuf_msg[0..msg.len];
    @memcpy(self.last_src, src);
    @memcpy(self.last_msg, msg);
    try self.output_tdiff(tdiff);
    _ = try self.plane.print("{s}: {s}", .{ escape(src), escape(msg) });
    self.last_time = ts;
    self.last_tdiff = tdiff;
}

fn output_repeat(self: *Self, src: []const u8, msg: []const u8) !void {
    _ = src;
    self.last_count += 1;
    try self.plane.cursor_move_rel(-1, 0);
    try self.output_tdiff(self.last_tdiff);
    _ = try self.plane.print("{s} ({})", .{ escape(msg), self.last_count });
}

fn output(self: *Self, src: []const u8, msg: []const u8) !void {
    return if (eql(u8, msg, self.last_src) and eql(u8, msg, self.last_msg))
        self.output_repeat(src, msg)
    else
        self.output_new(src, msg);
}

fn output_error(self: *Self, src: []const u8, context: []const u8, msg_: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const msg = try fmt.bufPrint(&buf, "error in {s}: {s}", .{ context, msg_ });
    try self.output(src, msg);
}

fn output_json(self: *Self, src: []const u8, m: tp.message) !void {
    var buf: [4096]u8 = undefined;
    const json = try m.to_json(&buf);
    try self.output(src, json);
}
