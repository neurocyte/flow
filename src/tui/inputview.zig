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
const command = @import("command");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");

pub const name = "inputview";

allocator: Allocator,
parent: Plane,
plane: Plane,
last_count: u64 = 0,
buffer: Buffer,

const Self = @This();
const widget_type: Widget.Type = .panel;

const Entry = struct {
    time: i64,
    tdiff: i64,
    json: [:0]u8,
};
const Buffer = ArrayList(Entry);

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Widget {
    var n = try Plane.init(&(Widget.Box{}).opts_vscroll(@typeName(Self)), parent);
    errdefer n.deinit();
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent,
        .plane = n,
        .buffer = .empty,
    };
    try tui.input_listeners().add(EventHandler.bind(self, listen));
    container.ctx = self;
    try container.add(Widget.to(self));
    return container.widget();
}

pub fn deinit(self: *Self, allocator: Allocator) void {
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
        _ = try self.plane.print("{d:6.2} ▏", .{ms});
    } else {
        const ms: u64 = @intCast(msi);
        _ = try self.plane.print("{d:6} ▏", .{ms});
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

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}
