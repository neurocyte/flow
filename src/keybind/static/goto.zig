const tp = @import("thespian");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command");
const EventHandler = @import("EventHandler");

const Allocator = @import("std").mem.Allocator;
const fmt = @import("std").fmt;

const Mode = @import("root.zig").Mode;

pub fn create(_: Allocator) error{OutOfMemory}!Mode {
    return .{
        .handler = EventHandler.static(@This()),
    };
}

pub fn receive(_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var modifiers: u32 = undefined;
    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.any, tp.string, tp.extract(&modifiers) }))
        try mapEvent(evtype, keypress, modifiers);
    return false;
}

fn mapEvent(evtype: u32, keypress: u32, modifiers: u32) tp.result {
    switch (evtype) {
        event_type.PRESS => try mapPress(keypress, modifiers),
        event_type.REPEAT => try mapPress(keypress, modifiers),
        event_type.RELEASE => try mapRelease(keypress, modifiers),
        else => {},
    }
}

fn mapPress(keypress: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'Q' => command.executeName("quit", .{}),
            'U' => command.executeName("mini_mode_reset", .{}),
            'G' => command.executeName("mini_mode_cancel", .{}),
            'C' => command.executeName("mini_mode_cancel", .{}),
            'L' => command.executeName("scroll_view_center", .{}),
            key.SPACE => command.executeName("mini_mode_cancel", .{}),
            else => {},
        },
        0 => switch (keypress) {
            key.LCTRL, key.RCTRL => command.executeName("enable_fast_scroll", .{}),
            key.LALT, key.RALT => command.executeName("enable_fast_scroll", .{}),
            key.ESC => command.executeName("mini_mode_cancel", .{}),
            key.ENTER => command.executeName("exit_mini_mode", .{}),
            key.BACKSPACE => command.executeName("mini_mode_delete_backwards", .{}),
            '0'...'9' => command.executeName("mini_mode_insert_code_point", command.fmt(.{keypress})),
            else => {},
        },
        else => {},
    };
}

fn mapRelease(keypress: u32, _: u32) tp.result {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => command.executeName("disable_fast_scroll", .{}),
        key.LALT, key.RALT => command.executeName("disable_fast_scroll", .{}),
        else => {},
    };
}
