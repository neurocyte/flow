const eql = @import("std").mem.eql;
const time = @import("std").time;
const root = @import("soft_root").root;
const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const Writer = @import("std").Io.Writer;

const tp = @import("thespian");
const cbor = @import("cbor");
const MouseEvent = @import("MouseEvent");

const Plane = @import("renderer").Plane;
const EventHandler = @import("EventHandler");
const input = @import("input");
const command = @import("command");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");

pub const name = "inputview";

allocator: Allocator,
parent: Plane,
plane: Plane,
last_count: u64 = 0,
buffer: Buffer,
panel_input: PanelInput,

const Self = @This();

const Entry = struct {
    time: i64,
    tdiff: i64,
    json: [:0]u8,
};
const Buffer = ArrayList(Entry);

pub const panel_tag = "input";
pub const panel_singleton = true;

pub fn panel_title(_: *Self) []const u8 {
    return "Input";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "";
}

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    var n = try Plane.init(&(Widget.Box{}).opts_vscroll(@typeName(Self)), parent);
    errdefer n.deinit();
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent,
        .plane = n,
        .buffer = .empty,
        .panel_input = try PanelInput.init(allocator, "inputview"),
    };
    try tui.input_listeners().add(EventHandler.bind(self, listen));
    return Panel.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.panel_input.deinit(Widget.to(self));
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
    const ts = root.get_now().toMicroseconds();
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
    if (try m.match(.{ MouseEvent.Type.motion, tp.more })) return;
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
        tp.more,
    })) {
        const key_event = input.KeyEvent.from_message(event, keypress, keypress_shifted, text, modifiers);
        writer.print(" -> {f}", .{key_event}) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    self.append(result.written()) catch |e| return tp.exit_error(e, @errorReturnTrace());
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

pub fn panel_copy(self: *Self) void {
    var text: Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    for (self.buffer.items) |item| text.writer.print("{s}\n", .{item.json}) catch return;
    PanelInput.copy_to_clipboard(text.written());
}

pub fn panel_clear(self: *Self) void {
    for (self.buffer.items) |item| self.allocator.free(item.json);
    self.buffer.clearRetainingCapacity();
    self.last_count = 0;
    tui.need_render(@src());
}
