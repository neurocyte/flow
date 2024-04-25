const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");

const Plane = @import("renderer").Plane;
const key = @import("renderer").input.key;
const event_type = @import("renderer").input.event_type;
const utils = @import("renderer").input.utils;

const Widget = @import("../Widget.zig");
const command = @import("../command.zig");
const tui = @import("../tui.zig");
const EventHandler = @import("../EventHandler.zig");

plane: Plane,
ctrl: bool = false,
shift: bool = false,
alt: bool = false,
hover: bool = false,

const Self = @This();

pub const width = 5;

pub fn create(a: Allocator, parent: Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(parent);
    try tui.current().input_listeners.add(EventHandler.bind(self, listen));
    return self.widget();
}

fn init(parent: Plane) !Self {
    var n = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent);
    errdefer n.deinit();
    return .{
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
    self.plane.set_base_style(" ", if (self.hover) theme.statusbar_hover else theme.statusbar);
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

pub fn listen(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var mod: u32 = 0;
    if (try m.match(.{ "I", tp.any, tp.any, tp.any, tp.any, tp.extract(&mod), tp.more })) {
        self.ctrl = utils.isCtrl(mod);
        self.shift = utils.isShift(mod);
        self.alt = utils.isAlt(mod);
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "B", event_type.PRESS, key.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
        command.executeName("toggle_inputview", .{}) catch {};
        return true;
    }
    return try m.match(.{ "H", tp.extract(&self.hover) });
}
