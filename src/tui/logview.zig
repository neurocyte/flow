const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;
const array_list = @import("std").array_list;
const root = @import("soft_root").root;

const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");

const Plane = @import("renderer").Plane;

const Widget = @import("Widget.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const tui = @import("tui.zig");
const MessageFilter = @import("MessageFilter.zig");

const escape = @import("std").ascii.hexEscape;

pub const name = @typeName(Self);

plane: Plane,
panel_input: PanelInput,
top: ?usize = null,

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
const Buffer = array_list.Managed(Entry);

const Level = enum {
    info,
    err,
};

pub const panel_tag = "log";
pub const panel_singleton = true;

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .panel_input = try PanelInput.init(allocator, "log"),
    };
    return Panel.to(self);
}

pub fn panel_title(_: *Self) []const u8 {
    return "Log";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "";
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.panel_input.deinit(Widget.to(self));
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn focus(self: *Self) void {
    self.panel_input.focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    self.panel_input.unfocus(Widget.to(self));
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    return self.panel_input.receive(from, m);
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    const buffer = if (persistent_buffer) |*p| p else return;
    const height = self.plane.dim_y();
    const last_top = buffer.items.len -| height;
    const cur = self.top orelse last_top;
    const new: usize = switch (action) {
        .line_up => cur -| 1,
        .line_down => cur + 1,
        .page_up => cur -| height,
        .page_down => cur + height,
        .top => 0,
        .bottom => last_top,
    };
    self.top = if (new >= last_top) null else new;
    tui.need_render(@src());
}

pub fn panel_copy(_: *Self) void {
    const buffer = if (persistent_buffer) |*p| p else return;
    var text: @import("std").Io.Writer.Allocating = .init(buffer.allocator);
    defer text.deinit();
    for (buffer.items) |item| text.writer.print("{s}: {s}\n", .{ item.src, item.msg }) catch return;
    PanelInput.copy_to_clipboard(text.written());
}

pub fn panel_clear(self: *Self) void {
    const buffer = if (persistent_buffer) |*p| p else return;
    for (buffer.items) |item| {
        // free sentinel too
        buffer.allocator.free(item.src.ptr[0 .. item.src.len + 1]);
        buffer.allocator.free(item.msg.ptr[0 .. item.msg.len + 1]);
    }
    buffer.clearRetainingCapacity();
    last_count = 0;
    self.top = null;
    tui.need_render(@src());
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const style_normal = theme.panel;
    const style_info: Widget.Theme.Style = .{ .fg = theme.editor_information.fg, .fs = theme.editor_information.fs };
    const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs };
    self.plane.set_base_style(style_normal);
    self.plane.erase();
    self.plane.home();
    const height = self.plane.dim_y();
    var first = true;
    const buffer = if (persistent_buffer) |*p| p else return false;
    const count = buffer.items.len;
    const begin_at = if (self.top) |top| @min(top, count -| height) else count -| height;
    for (buffer.items[begin_at..@min(count, begin_at + height)]) |item| {
        if (first) first = false else _ = self.plane.putstr("\n") catch return false;
        self.output_tdiff(item.tdiff) catch return false;
        self.plane.set_style(if (item.level == .err) style_error else style_info);
        _ = self.plane.print("{f}: {f}", .{ escape(item.src, .lower), escape(item.msg, .lower) }) catch {};
        self.plane.set_style(style_normal);
    }
    if (last_count > 0)
        _ = self.plane.print(" ({})", .{last_count}) catch {};
    return false;
}

fn output_tdiff(self: *Self, tdiff: i64) !void {
    const msi = @divFloor(tdiff, time.us_per_ms);
    if (msi < 10) {
        const d: f64 = @floatFromInt(tdiff);
        const ms = d / time.us_per_ms;
        _ = try self.plane.print("{d:6.2} ▏", .{ms});
    } else {
        const ms: u64 = @intCast(msi);
        _ = try self.plane.print("{d:6} ▏", .{ms});
    }
}

pub fn process_log(m: tp.message) MessageFilter.Error!void {
    var src: []const u8 = undefined;
    var context: []const u8 = undefined;
    var msg: []const u8 = undefined;
    const buffer = get_buffer();
    if (try cbor.match(m.buf, .{ "log", tp.extract(&src), tp.extract(&msg) })) {
        try append(buffer, src, msg, .info);
    } else if (try cbor.match(m.buf, .{ "log", "error", tp.extract(&src), tp.extract(&context), "->", tp.extract(&msg) })) {
        const err_stop = "error.Stop";
        if (eql(u8, msg, err_stop))
            return;
        if (msg.len >= err_stop.len + 1 and eql(u8, msg[0 .. err_stop.len + 1], err_stop ++ "\n"))
            return;
        try append_error(buffer, src, context, msg);
    } else if (try cbor.match(m.buf, .{ "log", tp.extract(&src), tp.more })) {
        try append_json(buffer, src, m);
    }
}

fn append(buffer: *Buffer, src: []const u8, msg: []const u8, level: Level) !void {
    const ts = root.get_now().toMicroseconds();
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

fn append_error(buffer: *Buffer, src: []const u8, context: []const u8, msg_: []const u8) MessageFilter.Error!void {
    const std = @import("std");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var msg: std.Io.Writer.Allocating = .init(arena.allocator());
    defer msg.deinit();
    msg.writer.print("error in {s}: {s}", .{ context, msg_ }) catch {};
    try append(buffer, src, msg.written(), .err);
}

fn append_json(buffer: *Buffer, src: []const u8, m: tp.message) MessageFilter.Error!void {
    const std = @import("std");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sfa = std.heap.stackFallback(4096, arena.allocator());
    const msg = try cbor.toJsonAlloc(sfa.get(), m.buf);
    try append(buffer, src, msg, .err);
}

fn get_buffer() *Buffer {
    return if (persistent_buffer) |*p| p else @panic("logview.get_buffer called before init");
}

pub fn init(allocator: Allocator) void {
    if (persistent_buffer) |_| return;
    persistent_buffer = Buffer.init(allocator);
}
