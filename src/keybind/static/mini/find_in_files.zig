const tp = @import("thespian");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command");
const EventHandler = @import("EventHandler");

const Allocator = @import("std").mem.Allocator;

const Mode = @import("../root.zig").Mode;

pub fn create(_: Allocator) !Mode {
    return .{ .handler = EventHandler.static(@This()) };
}

pub fn receive(_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn mapEvent(evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
    switch (evtype) {
        event_type.PRESS => try mapPress(keypress, egc, modifiers),
        event_type.REPEAT => try mapPress(keypress, egc, modifiers),
        event_type.RELEASE => try mapRelease(keypress, egc, modifiers),
        else => {},
    }
}

fn mapPress(keypress: u32, egc: u32, modifiers: u32) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'Q' => command.executeName("quit", .{}),
            'V' => command.executeName("system_paste", .{}),
            'U' => command.executeName("mini_mode_reset", .{}),
            'G' => command.executeName("exit_mini_mode", .{}),
            'C' => command.executeName("exit_mini_mode", .{}),
            'L' => command.executeName("scroll_view_center", .{}),
            'F' => command.executeName("goto_next_match", .{}),
            'N' => command.executeName("goto_next_match", .{}),
            'P' => command.executeName("goto_prev_match", .{}),
            'I' => command.executeName("mini_mode_insert_bytes", command.fmt(.{"\t"})),
            key.SPACE => command.executeName("exit_mini_mode", .{}),
            key.ENTER => command.executeName("mini_mode_insert_bytes", command.fmt(.{"\n"})),
            key.BACKSPACE => command.executeName("mini_mode_reset", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'V' => command.executeName("system_paste", .{}),
            'N' => command.executeName("goto_next_file", .{}),
            'P' => command.executeName("goto_prev_file", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'V' => command.executeName("system_paste", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            key.ENTER => command.executeName("goto_prev_match", .{}),
            key.F03 => command.executeName("goto_prev_match", .{}),
            else => if (!key.synthesized_p(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        0 => switch (keypress) {
            key.UP => command.executeName("select_prev_file", .{}),
            key.DOWN => command.executeName("select_next_file", .{}),
            key.F03 => command.executeName("goto_next_match", .{}),
            key.F15 => command.executeName("goto_prev_match", .{}),
            key.F09 => command.executeName("theme_prev", .{}),
            key.F10 => command.executeName("theme_next", .{}),
            key.ESC => command.executeName("exit_mini_mode", .{}),
            key.ENTER => command.executeName("mini_mode_select", .{}),
            key.BACKSPACE => command.executeName("mini_mode_delete_backwards", .{}),
            key.LCTRL, key.RCTRL => command.executeName("enable_fast_scroll", .{}),
            key.LALT, key.RALT => command.executeName("enable_fast_scroll", .{}),
            else => if (!key.synthesized_p(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        else => {},
    };
}

fn mapRelease(keypress: u32, _: u32, _: u32) !void {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => command.executeName("disable_fast_scroll", .{}),
        key.LALT, key.RALT => command.executeName("disable_fast_scroll", .{}),
        else => {},
    };
}
