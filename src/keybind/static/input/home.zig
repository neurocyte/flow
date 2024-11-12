const std = @import("std");
const tp = @import("thespian");
const key = @import("renderer").input.key;
const event_type = @import("renderer").input.event_type;
const mod = @import("renderer").input.modifier;
const command = @import("command");
const EventHandler = @import("EventHandler");
const keybind = @import("../keybind.zig");

const Self = @This();

allocator: std.mem.Allocator,
f: usize = 0,
leader: ?struct { keypress: u32, modifiers: u32 } = null,

pub fn create(allocator: std.mem.Allocator) !EventHandler {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
    };
    return EventHandler.to_owned(self);
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
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
    if (self.leader) |_| return self.mapFollower(keynormal, modifiers);
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'F' => self.sheeran(),
            'J' => self.cmd("toggle_panel", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("quit", .{}),
            'O' => self.cmd("open_file", .{}),
            'E' => self.cmd("open_recent", .{}),
            'R' => self.cmd("open_recent_project", .{}),
            'P' => self.cmd("open_command_palette", .{}),
            '/' => self.cmd("open_help", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'F' => self.cmd("find_in_files", .{}),
            'L' => self.cmd_async("toggle_panel"),
            '/' => self.cmd("open_help", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'N' => self.cmd("goto_next_file_or_diagnostic", .{}),
            'P' => self.cmd("goto_prev_file_or_diagnostic", .{}),
            'L' => self.cmd("toggle_panel", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            'X' => self.cmd("open_command_palette", .{}),
            key.LEFT => self.cmd("jump_back", .{}),
            key.RIGHT => self.cmd("jump_forward", .{}),
            else => {},
        },
        0 => switch (keypress) {
            key.F02 => self.cmd("toggle_input_mode", .{}),
            'h' => self.cmd("open_help", .{}),
            'o' => self.cmd("open_file", .{}),
            'e' => self.cmd("open_recent", .{}),
            'r' => self.cmd("open_recent_project", .{}),
            'p' => self.cmd("open_command_palette", .{}),
            'c' => self.cmd("open_config", .{}),
            't' => self.cmd("change_theme", .{}),
            'q' => self.cmd("quit", .{}),

            key.F01 => self.cmd("open_help", .{}),
            key.F06 => self.cmd("open_config", .{}),
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.F11 => self.cmd("toggle_panel", .{}),
            key.F12 => self.cmd("toggle_inputview", .{}),
            key.UP => self.cmd("home_menu_up", .{}),
            key.DOWN => self.cmd("home_menu_down", .{}),
            key.ENTER => self.cmd("home_menu_activate", .{}),
            else => {},
        },
        else => {},
    };
}

fn mapFollower(self: *Self, keypress: u32, modifiers: u32) !void {
    defer self.leader = null;
    const ldr = if (self.leader) |leader| leader else return;
    return switch (ldr.modifiers) {
        mod.CTRL => switch (ldr.keypress) {
            'K' => switch (modifiers) {
                mod.CTRL => switch (keypress) {
                    'T' => self.cmd("change_theme", .{}),
                    else => {},
                },
                else => {},
            },
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

pub const hints = keybind.KeybindHints.initComptime(.{
    .{ "find_in_files", "C-S-f" },
    .{ "open_file", "o, C-o" },
    .{ "open_recent", "e, C-e" },
    .{ "open_recent_project", "r, C-r" },
    .{ "open_command_palette", "p, C-S-p, S-A-p, A-x" },
    .{ "home_menu_activate", "enter" },
    .{ "home_menu_down", "down" },
    .{ "home_menu_up", "up" },
    .{ "jump_back", "A-left" },
    .{ "jump_forward", "A-right" },
    .{ "open_config", "c, F6" },
    .{ "open_help", "h, F1, C-/, C-S-/" },
    .{ "quit", "q, C-q, C-w" },
    .{ "quit_without_saving", "C-S-q" },
    .{ "restart", "C-S-r" },
    .{ "change_theme", "t, C-k C-t" },
    .{ "theme_next", "F10" },
    .{ "theme_prev", "F9" },
    .{ "toggle_input_mode", "F2" },
    .{ "toggle_inputview", "F12, A-i" },
    .{ "toggle_panel", "F11, C-j, A-l, C-S-l" },
    .{ "goto_next_file_or_diagnostic", "A-n" },
    .{ "goto_prev_file_or_diagnostic", "A-p" },
});
