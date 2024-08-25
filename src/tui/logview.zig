const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;
const Mutex = @import("std").Thread.Mutex;
const ArrayList = @import("std").ArrayList;

const tp = @import("thespian");
const log = @import("log");

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");

const escape = fmt.fmtSliceEscapeLower;

pub const name = @typeName(Self);

plane: Plane,

var persistent_buffer: ?Buffer = null;
var last_count: u64 = 0;

const Self = @This();

const Entry = struct {
    src: []u8,
    msg: []u8,
    time: i64,
    tdiff: i64,
    level: Level,
};
const Buffer = ArrayList(Entry);

const Level = enum {
    info,
    err,
};

pub fn create(a: Allocator, parent: Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = .{ .plane = try Plane.init(&(Widget.Box{}).opts(name), parent) };
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    a.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const style_normal = theme.panel;
    const style_info: Widget.Theme.Style = .{ .fg = theme.editor_information.fg, .fs = theme.editor_information.fs };
    const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs };
    self.plane.set_base_style(" ", style_normal);
    self.plane.erase();
    self.plane.home();
    const height = self.plane.dim_y();
    var first = true;
    const buffer = if (persistent_buffer) |*p| p else return false;
    const count = buffer.items.len;
    const begin_at = if (height > count) 0 else count - height;
    for (buffer.items[begin_at..]) |item| {
        if (first) first = false else _ = self.plane.putstr("\n") catch return false;
        self.output_tdiff(item.tdiff) catch return false;
        self.plane.set_style(if (item.level == .err) style_error else style_info);
        _ = self.plane.print("{s}: {s}", .{ escape(item.src), escape(item.msg) }) catch {};
        self.plane.set_style(style_normal);
    }
    if (last_count > 0)
        _ = self.plane.print(" ({})", .{last_count}) catch {};
    return false;
}

fn output_tdiff(self: *Self, tdiff: i64) !void {
    const msi = @divFloor(tdiff, time.us_per_ms);
    if (msi == 0) {
        const d: f64 = @floatFromInt(tdiff);
        const ms = d / time.us_per_ms;
        _ = try self.plane.print("{d:6.2} ▏", .{ms});
    } else {
        const ms: u64 = @intCast(msi);
        _ = try self.plane.print("{d:6} ▏", .{ms});
    }
}

pub fn process_log(m: tp.message) !void {
    var src: []const u8 = undefined;
    var context: []const u8 = undefined;
    var msg: []const u8 = undefined;
    const buffer = get_buffer();
    if (try m.match(.{ "log", tp.extract(&src), tp.extract(&msg) })) {
        try append(buffer, src, msg, .info);
    } else if (try m.match(.{ "log", "error", tp.extract(&src), tp.extract(&context), "->", tp.extract(&msg) })) {
        const err_stop = "error.Stop";
        if (eql(u8, msg, err_stop))
            return;
        if (msg.len >= err_stop.len + 1 and eql(u8, msg[0 .. err_stop.len + 1], err_stop ++ "\n"))
            return;
        try append_error(buffer, src, context, msg);
    } else if (try m.match(.{ "log", tp.extract(&src), tp.more })) {
        try append_json(buffer, src, m);
    }
}

fn append(buffer: *Buffer, src: []const u8, msg: []const u8, level: Level) !void {
    const ts = time.microTimestamp();
    const tdiff = if (buffer.getLastOrNull()) |last| ret: {
        if (eql(u8, msg, last.src) and eql(u8, msg, last.msg)) {
            last_count += 1;
            return;
        }
        break :ret ts - last.time;
    } else 0;
    last_count = 0;
    (try buffer.addOne()).* = .{
        .time = ts,
        .tdiff = tdiff,
        .src = try buffer.allocator.dupeZ(u8, src),
        .msg = try buffer.allocator.dupeZ(u8, msg),
        .level = level,
    };
}

fn append_error(buffer: *Buffer, src: []const u8, context: []const u8, msg_: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const msg = try fmt.bufPrint(&buf, "error in {s}: {s}", .{ context, msg_ });
    try append(buffer, src, msg, .err);
}

fn append_json(buffer: *Buffer, src: []const u8, m: tp.message) !void {
    var buf: [4096]u8 = undefined;
    const json = try m.to_json(&buf);
    try append(buffer, src, json, .err);
}

fn get_buffer() *Buffer {
    return if (persistent_buffer) |*p| p else @panic("logview.get_buffer called before init");
}

pub fn init(a: Allocator) void {
    if (persistent_buffer) |_| return;
    persistent_buffer = Buffer.init(a);
}
