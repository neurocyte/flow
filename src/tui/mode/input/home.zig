const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");
const root = @import("root");

const tui = @import("../../tui.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");

const Self = @This();

a: std.mem.Allocator,
f: usize = 0,

pub fn create(a: std.mem.Allocator) !tui.Mode {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
    };
    return .{
        .handler = EventHandler.to_owned(self),
        .name = root.application_logo ++ root.application_name,
        .description = "home",
    };
}

pub fn deinit(self: *Self) void {
    self.a.destroy(self);
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
            'F' => self.sheeran(),
            'J' => self.cmd("toggle_logview", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("quit", .{}),
            'O' => self.cmd("enter_open_file_mode", .{}),
            '/' => self.cmd("open_help", .{}),
            else => {},
        },
        nc.mod.CTRL | nc.mod.SHIFT => switch (keynormal) {
            'Q' => self.cmd("quit_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'F' => self.cmd("enter_find_in_files_mode", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            '/' => self.cmd("open_help", .{}),
            else => {},
        },
        nc.mod.ALT => switch (keynormal) {
            'L' => self.cmd("toggle_logview", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            nc.key.LEFT => self.cmd("jump_back", .{}),
            nc.key.RIGHT => self.cmd("jump_forward", .{}),
            else => {},
        },
        0 => switch (keypress) {
            nc.key.F01 => self.cmd("open_help", .{}),
            nc.key.F06 => self.cmd("open_config", .{}),
            nc.key.F09 => self.cmd("theme_prev", .{}),
            nc.key.F10 => self.cmd("theme_next", .{}),
            nc.key.F11 => self.cmd("toggle_logview", .{}),
            nc.key.F12 => self.cmd("toggle_inputview", .{}),
            else => {},
        },
        else => {},
    };
}

fn cmd(_: *Self, name_: []const u8, ctx: command.Context) tp.result {
    try command.executeName(name_, ctx);
}

fn cmd_async(_: *Self, name_: []const u8) tp.result {
    return tp.self_pid().send(.{ "cmd", name_ });
}

fn sheeran(self: *Self) void {
    self.f += 1;
    if (self.f >= 5) {
        self.f = 0;
        self.cmd("home_sheeran", .{}) catch {};
    }
}
