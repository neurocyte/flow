const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");

const Plane = @import("renderer").Plane;
const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");

const Widget = @import("../Widget.zig");
const tui = @import("../tui.zig");

plane: Plane,
mods: input.ModSet = .{},
hover: bool = false,

const Self = @This();

pub const width = 8;

pub fn create(allocator: Allocator, parent: Plane, _: ?EventHandler) @import("widget.zig").CreateError!Widget {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
    };
    try tui.input_listeners().add(EventHandler.bind(self, listen));
    return self.widget();
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    tui.input_listeners().remove_ptr(self);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = width };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(if (self.hover) theme.statusbar_hover else theme.statusbar);
    self.plane.fill(" ");
    self.plane.home();

    _ = self.plane.print(" {s}{s}{s} ", .{
        mode(self.mods.ctrl, "Ⓒ ", "🅒 "),
        mode(self.mods.shift, "Ⓢ ", "🅢 "),
        mode(self.mods.alt, "Ⓐ ", "🅐 "),
    }) catch {};
    return false;
}

inline fn mode(state: bool, off: [:0]const u8, on: [:0]const u8) [:0]const u8 {
    return if (state) on else off;
}

fn render_modifier(self: *Self, state: bool, off: [:0]const u8, on: [:0]const u8) void {
    _ = self.plane.putstr(if (state) on else off) catch {};
}

pub fn listen(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var mods: input.Mods = 0;
    if (try m.match(.{ "I", tp.any, tp.any, tp.any, tp.any, tp.extract(&mods), tp.more })) {
        self.mods = @bitCast(mods);
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.any, tp.any, tp.any })) {
        command.executeName("toggle_inputview", .{}) catch {};
        return true;
    }
    return try m.match(.{ "H", tp.extract(&self.hover) });
}
