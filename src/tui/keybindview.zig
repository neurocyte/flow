const eql = @import("std").mem.eql;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const Writer = @import("std").Io.Writer;

const tp = @import("thespian");
const cbor = @import("cbor");

const Plane = @import("renderer").Plane;
const input = @import("input");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");

pub const name = "keybindview";

allocator: Allocator,
parent: Plane,
plane: Plane,
buffer: Buffer,

const Self = @This();

const Entry = struct {
    time: i64,
    tdiff: i64,
    msg: []const u8,
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
    try tui.message_filters().add(MessageFilter.bind(self, keybind_match));
    tui.enable_match_events();
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    tui.disable_match_events();
    tui.message_filters().remove_ptr(self);
    for (self.buffer.items) |item|
        self.allocator.free(item.msg);
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
        _ = self.plane.putstr(item.msg) catch return false;
    }
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

fn keybind_match(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var namespace: []const u8 = undefined;
    var section: []const u8 = undefined;
    var key_event: []const u8 = undefined;
    var cmds: []const u8 = undefined;
    if (!(m.match(.{ "K", tp.extract(&namespace), tp.extract(&section), tp.extract(&key_event), tp.extract_cbor(&cmds) }) catch false)) return false;

    var result: Writer.Allocating = .init(self.allocator);
    defer result.deinit();
    const writer = &result.writer;

    writer.print("{s}:{s} {s} -> ", .{ namespace, section, key_event }) catch return true;
    cbor.toJsonWriter(cmds, writer, .{}) catch return true;

    const ts = time.microTimestamp();
    const tdiff = if (self.buffer.items.len > 0) ts -| self.buffer.items[self.buffer.items.len - 1].time else 0;
    (try self.buffer.addOne(self.allocator)).* = .{
        .time = ts,
        .tdiff = tdiff,
        .msg = result.toOwnedSlice() catch return true,
    };
    return true;
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}
