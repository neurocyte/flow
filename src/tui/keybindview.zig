const eql = @import("std").mem.eql;
const time = @import("std").time;
const root = @import("soft_root").root;
const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const Writer = @import("std").Io.Writer;
const hexEscape = @import("std").ascii.hexEscape;

const tp = @import("thespian");
const cbor = @import("cbor");

const Plane = @import("renderer").Plane;
const input = @import("input");
const command = @import("command");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const Scroller = @import("Scroller.zig");
const MessageFilter = @import("MessageFilter.zig");

pub const name = "keybindview";

allocator: Allocator,
parent: Plane,
plane: Plane,
buffer: Buffer,
panel_input: PanelInput,
scroller: Scroller = .{ .sticky_end = true },

const Self = @This();

const Entry = struct {
    time: i64,
    tdiff: i64,
    msg: []const u8,
};
const Buffer = ArrayList(Entry);

pub const panel_tag = "keybind";
pub const panel_singleton = true;

pub fn panel_title(_: *Self) []const u8 {
    return "Keybinds";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "󰌆";
}

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    const container = try WidgetList.createH(allocator, parent, "keybindview.container", .dynamic);
    errdefer container.deinit(allocator);
    var n = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), container.plane);
    errdefer n.deinit();
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent,
        .plane = n,
        .buffer = .empty,
        .panel_input = try PanelInput.init(allocator, "log"),
    };
    try container.add(Widget.to(self));
    try self.scroller.attach_scrollbar(allocator, container);
    try tui.message_filters().add(MessageFilter.bind(self, keybind_match));
    tui.enable_match_events();
    return Panel.to_hosted(self, container.widget());
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.panel_input.deinit(Widget.to(self));
    tui.disable_match_events();
    tui.message_filters().remove_ptr(self);
    for (self.buffer.items) |item|
        self.allocator.free(item.msg);
    self.buffer.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn update(self: *Self) void {
    self.scroller.set_size(self.buffer.items.len, self.plane.dim_y());
    self.scroller.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const more = self.scroller.render();
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    const height = self.plane.dim_y();
    var first = true;
    const count = self.buffer.items.len;
    const begin_at = @min(self.scroller.top(), count -| height);
    for (self.buffer.items[begin_at..@min(count, begin_at + height)]) |item| {
        if (first) first = false else _ = self.plane.putstr("\n") catch return more;
        self.output_tdiff(item.tdiff) catch return more;
        _ = self.plane.putstr(item.msg) catch return more;
    }
    return more;
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

fn keybind_match(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var namespace: []const u8 = undefined;
    var section: []const u8 = undefined;
    var key_event: []const u8 = undefined;
    var cmds: []const u8 = undefined;
    var insert_cmd: []const u8 = undefined;
    var bytes: []const u8 = undefined;

    var source_mode: []const u8 = undefined;
    var source_file: []const u8 = undefined;
    var source_line: usize = undefined;

    if (m.match(.{ "K", tp.extract(&namespace), tp.extract(&section), tp.extract(&key_event), tp.extract_cbor(&cmds), tp.extract(&source_mode), tp.extract(&source_file), tp.extract(&source_line) }) catch false) {
        var result: Writer.Allocating = .init(self.allocator);
        defer result.deinit();
        const writer = &result.writer;

        writer.print("{s}:{s} {s} => ", .{ namespace, section, key_event }) catch return true;
        cbor.toJsonWriter(cmds, writer, .{}) catch return true;
        if (source_mode.len == 0)
            writer.writeAll(" (global)") catch return true
        else if (source_file.len == 0)
            writer.print(" ({s})", .{source_mode}) catch return true
        else
            writer.print(" ({s} {s}:{d})", .{ source_mode, source_file, source_line }) catch return true;

        self.append(result.toOwnedSlice() catch return true);
        return true;
    } else if (m.match(.{ "N", tp.extract(&namespace), tp.extract(&section), tp.extract(&insert_cmd), tp.extract(&bytes) }) catch false) {
        var result: Writer.Allocating = .init(self.allocator);
        defer result.deinit();
        result.writer.print("{s}:{s} insert => [\"{s}\", \"{f}\"] ", .{ namespace, section, insert_cmd, hexEscape(bytes, .lower) }) catch return true;
        self.append(result.toOwnedSlice() catch return true);
        return true;
    }
    return false;
}

pub fn append(self: *Self, msg: []const u8) void {
    const ts = root.get_now().toMicroseconds();
    const tdiff = if (self.buffer.items.len > 0) ts -| self.buffer.items[self.buffer.items.len - 1].time else 0;
    (self.buffer.addOne(self.allocator) catch return).* = .{
        .time = ts,
        .tdiff = tdiff,
        .msg = msg,
    };
}

pub fn focus(self: *Self) void {
    self.panel_input.focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    self.panel_input.unfocus(Widget.to(self));
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try self.scroller.receive_mouse(m)) return true;
    if (try PanelInput.receive_context_menu(self, m)) return true;
    return self.panel_input.receive(from, m);
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    self.scroller.scroll(action);
}

pub fn panel_copy(self: *Self) void {
    var text: Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    for (self.buffer.items) |item| text.writer.print("{s}\n", .{item.msg}) catch return;
    PanelInput.copy_to_clipboard(text.written());
}

pub fn panel_clear(self: *Self) void {
    for (self.buffer.items) |item| self.allocator.free(item.msg);
    self.buffer.clearRetainingCapacity();
    tui.need_render(@src());
}
