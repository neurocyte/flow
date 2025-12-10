const eql = @import("std").mem.eql;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const Writer = @import("std").Io.Writer;

const tp = @import("thespian");
const cbor = @import("cbor");

const Plane = @import("renderer").Plane;
const EventHandler = @import("EventHandler");
const input = @import("input");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");

pub const name = "inputview";

allocator: Allocator,
parent: Plane,
plane: Plane,
last_count: u64 = 0,
buffer: Buffer,

const Self = @This();

const Entry = struct {
    time: i64,
    tdiff: i64,
    json: [:0]u8,
};
const Buffer = ArrayList(Entry);

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    var n = try Plane.init(&(Widget.Box{}).opts_vscroll(@typeName(Self)), parent);
    errdefer n.deinit();
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent,
        .plane = n,
        .buffer = .empty,
    };
    try tui.input_listeners().add(EventHandler.bind(self, listen));
    try tui.message_filters().add(MessageFilter.bind(self, keybind_match));
    tui.enable_match_events();
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    tui.disable_match_events();
    tui.message_filters().remove_ptr(self);
    tui.input_listeners().remove_ptr(self);
    for (self.buffer.items) |item|
        self.allocator.free(item.json);
    self.buffer.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    const height = self.plane.dim_y();
    var first = true;
    const count = self.buffer.items.len;
    const begin_at = if (height > count) 0 else count - height;
    for (self.buffer.items[begin_at..]) |item| {
        if (first) first = false else _ = self.plane.putstr("\n") catch return false;
        self.output_tdiff(item.tdiff) catch return false;
        _ = self.plane.putstr(item.json) catch return false;
    }
    if (self.last_count > 0)
        _ = self.plane.print(" ({})", .{self.last_count}) catch {};
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

fn append(self: *Self, json: []const u8) !void {
    const ts = time.microTimestamp();
    const tdiff = if (self.buffer.getLastOrNull()) |last| ret: {
        if (eql(u8, json, last.json)) {
            self.last_count += 1;
            return;
        }
        break :ret ts - last.time;
    } else 0;
    self.last_count = 0;
    (try self.buffer.addOne(self.allocator)).* = .{
        .time = ts,
        .tdiff = tdiff,
        .json = try self.allocator.dupeZ(u8, json),
    };
}

fn listen(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ "M", tp.more })) return;
    var buf: [4096]u8 = undefined;
    const json = m.to_json(&buf) catch |e| return tp.exit_error(e, @errorReturnTrace());
    var result: Writer.Allocating = .init(self.allocator);
    defer result.deinit();
    const writer = &result.writer;
    writer.writeAll(json) catch |e| return tp.exit_error(e, @errorReturnTrace());

    var event: input.Event = 0;
    var keypress: input.Key = 0;
    var keypress_shifted: input.Key = 0;
    var text: []const u8 = "";
    var modifiers: input.Mods = 0;
    if (try m.match(.{
        "I",
        tp.extract(&event),
        tp.extract(&keypress),
        tp.extract(&keypress_shifted),
        tp.extract(&text),
        tp.extract(&modifiers),
    })) {
        const key_event = input.KeyEvent.from_message(event, keypress, keypress_shifted, text, modifiers);
        writer.print(" -> {f}", .{key_event}) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    self.append(result.written()) catch |e| return tp.exit_error(e, @errorReturnTrace());
}

fn keybind_match(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var cmds: []const u8 = undefined;
    if (!(m.match(.{ "keybind_match", tp.extract_cbor(&cmds) }) catch false)) return false;

    var result: Writer.Allocating = .init(self.allocator);
    defer result.deinit();
    const writer = &result.writer;
    writer.writeAll("keybind -> ") catch return true;
    cbor.toJsonWriter(cmds, writer, .{}) catch return true;

    self.append(result.written()) catch return true;
    return true;
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}
