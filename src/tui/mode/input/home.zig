const std = @import("std");
const tp = @import("thespian");
const root = @import("root");

const key = @import("renderer").input.key;
const event_type = @import("renderer").input.event_type;
const mod = @import("renderer").input.modifier;

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
        .keybind_hints = &hints,
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
        event_type.PRESS => self.mapPress(keypress, modifiers),
        event_type.REPEAT => self.mapPress(keypress, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'F' => self.sheeran(),
            'J' => self.cmd("toggle_logview", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("quit", .{}),
            'O' => self.cmd("enter_open_file_mode", .{}),
            'E' => self.cmd("open_recent", .{}),
            'P' => self.cmd("open_command_palette", .{}),
            '/' => self.cmd("open_help", .{}),
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'F' => self.cmd("enter_find_in_files_mode", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            '/' => self.cmd("open_help", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'L' => self.cmd("toggle_logview", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            key.LEFT => self.cmd("jump_back", .{}),
            key.RIGHT => self.cmd("jump_forward", .{}),
            else => {},
        },
        0 => switch (keypress) {
            'h' => self.cmd("open_help", .{}),
            'o' => self.cmd("enter_open_file_mode", .{}),
            'e' => self.cmd("open_recent", .{}),
            'r' => self.msg("open recent project not implemented"),
            'p' => self.cmd("open_command_palette", .{}),
            'c' => self.cmd("open_config", .{}),
            'q' => self.cmd("quit", .{}),

            key.F01 => self.cmd("open_help", .{}),
            key.F06 => self.cmd("open_config", .{}),
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.F11 => self.cmd("toggle_logview", .{}),
            key.F12 => self.cmd("toggle_inputview", .{}),
            key.UP => self.cmd("home_menu_up", .{}),
            key.DOWN => self.cmd("home_menu_down", .{}),
            key.ENTER => self.cmd("home_menu_activate", .{}),
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

fn sheeran(self: *Self) void {
    self.f += 1;
    if (self.f >= 5) {
        self.f = 0;
        self.cmd("home_sheeran", .{}) catch {};
    }
}

const hints = tui.KeybindHints.initComptime(.{
    .{ "enter_find_in_files_mode", "C-S-f" },
    .{ "enter_open_file_mode", "o, C-o" },
    .{ "open_recent", "e, C-e" },
    .{ "open_command_palette", "p, C-S-p" },
    .{ "home_menu_activate", "enter" },
    .{ "home_menu_down", "down" },
    .{ "home_menu_up", "up" },
    .{ "jump_back", "A-left" },
    .{ "jump_forward", "A-right" },
    .{ "open_config", "c, F6" },
    .{ "open_help", "C-/, C-S-/" },
    .{ "open_help", "h, F1" },
    .{ "quit", "q, C-q, C-w" },
    .{ "quit_without_saving", "C-S-q" },
    .{ "restart", "C-S-r" },
    .{ "theme_next", "F10" },
    .{ "theme_prev", "F9" },
    .{ "toggle_inputview", "F12, A-i, C-S-i" },
    .{ "toggle_logview", "F11, C-j, A-l, C-S-l" },
});
