const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");
const root = @import("root");

const tui = @import("../../tui.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const Button = @import("../../Button.zig");
const Menu = @import("../../Menu.zig");
const mainview = @import("../../mainview.zig");

const Self = @This();

a: std.mem.Allocator,
f: usize = 0,
menu: *Menu.State(*Self),

pub fn create(a: std.mem.Allocator) !tui.Mode {
    const mv = if (tui.current().mainview.dynamic_cast(mainview)) |mv_| mv_ else return error.NotFound;
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .menu = try Menu.create(*Self, a, tui.current().mainview, .{ .ctx = self }),
    };
    try self.menu.add_item_with_handler("open help", menu_action_help);
    self.menu.resize(.{ .y = 0, .x = 25, .w = 32 });
    try mv.floating_views.add(self.menu.menu_widget);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "󰈞 open recent",
        .description = "open recent",
    };
}

pub fn deinit(self: *Self) void {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv|
        mv.floating_views.remove(self.menu.menu_widget);
    self.a.destroy(self);
}

fn menu_action_help(_: *Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
    command.executeName("open_help", .{}) catch {};
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var modifiers: u32 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.any, tp.string, tp.extract(&modifiers) })) {
        try self.mapEvent(evtype, keypress, modifiers);
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, modifiers: u32) tp.result {
    return switch (evtype) {
        nc.event_type.PRESS => self.mapPress(keypress, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        nc.mod.CTRL => switch (keynormal) {
            'J' => self.cmd("toggle_logview", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            else => {},
        },
        nc.mod.CTRL | nc.mod.SHIFT => switch (keynormal) {
            'Q' => self.cmd("quit_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            else => {},
        },
        nc.mod.ALT => switch (keynormal) {
            'L' => self.cmd("toggle_logview", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            else => {},
        },
        0 => switch (keypress) {
            nc.key.F09 => self.cmd("theme_prev", .{}),
            nc.key.F10 => self.cmd("theme_next", .{}),
            nc.key.F11 => self.cmd("toggle_logview", .{}),
            nc.key.F12 => self.cmd("toggle_inputview", .{}),
            nc.key.ESC => self.cmd("exit_overlay_mode", .{}),
            nc.key.ENTER => self.cmd("exit_overlay_mode", .{}),
            else => {},
        },
        else => {},
    };
}

fn cmd(_: *Self, name_: []const u8, ctx: command.Context) tp.result {
    try command.executeName(name_, ctx);
}

fn msg(_: *Self, text: []const u8) tp.result {
    return tp.self_pid().send(.{ "log", "home", text });
}

fn cmd_async(_: *Self, name_: []const u8) tp.result {
    return tp.self_pid().send(.{ "cmd", name_ });
}
