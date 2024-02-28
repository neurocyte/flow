const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");

const Widget = @import("../Widget.zig");
const command = @import("../command.zig");
const tui = @import("../tui.zig");
const EventHandler = @import("../EventHandler.zig");

parent: nc.Plane,
plane: nc.Plane,
ctrl: bool = false,
shift: bool = false,
alt: bool = false,
hover: bool = false,

const Self = @This();

pub const width = 5;

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(parent);
    try tui.current().input_listeners.add(EventHandler.bind(self, listen));
    return self.widget();
}

fn init(parent: nc.Plane) !Self {
    var n = try nc.Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent);
    errdefer n.deinit();
    return .{
        .parent = parent,
        .plane = n,
    };
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: Allocator) void {
    tui.current().input_listeners.remove_ptr(self);
    self.plane.deinit();
    a.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = width };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    tui.set_base_style(&self.plane, " ", if (self.hover) theme.statusbar_hover else theme.statusbar);
    self.plane.erase();
    self.plane.home();

    _ = self.plane.print("\u{2003}{s}{s}{s}\u{2003}", .{
        mode(self.ctrl, "Ⓒ", "🅒"),
        mode(self.shift, "Ⓢ", "🅢"),
        mode(self.alt, "Ⓐ", "🅐"),
    }) catch {};
    return false;
}

inline fn mode(state: bool, off: [:0]const u8, on: [:0]const u8) [:0]const u8 {
    return if (state) on else off;
}

fn render_modifier(self: *Self, state: bool, off: [:0]const u8, on: [:0]const u8) void {
    _ = self.plane.putstr(if (state) on else off) catch {};
}

fn set_modifiers(self: *Self, key: u32, mods: u32) void {
    const modifiers = switch (key) {
        nc.key.LCTRL, nc.key.RCTRL => mods ^ nc.mod.CTRL,
        nc.key.LSHIFT, nc.key.RSHIFT => mods ^ nc.mod.SHIFT,
        nc.key.LALT, nc.key.RALT => mods ^ nc.mod.ALT,
        else => mods,
    };

    self.ctrl = nc.isCtrl(modifiers);
    self.shift = nc.isShift(modifiers);
    self.alt = nc.isAlt(modifiers);
}

pub fn listen(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var key: u32 = 0;
    var mod: u32 = 0;
    if (try m.match(.{ "I", tp.any, tp.extract(&key), tp.any, tp.any, tp.extract(&mod), tp.more }))
        self.set_modifiers(key, mod);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "B", nc.event_type.PRESS, nc.key.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
        command.executeName("toggle_inputview", .{}) catch {};
        return true;
    }
    return try m.match(.{ "H", tp.extract(&self.hover) });
}
