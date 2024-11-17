const tp = @import("thespian");
const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");

pub fn create(_: @import("std").mem.Allocator, _: anytype) !EventHandler {
    return EventHandler.static(@This());
}

pub fn receive(_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var event: input.Event = undefined;
    var keypress: input.Key = undefined;
    var modifiers: input.Mods = undefined;
    if (try m.match(.{ "I", tp.extract(&event), tp.extract(&keypress), tp.any, tp.string, tp.extract(&modifiers) }))
        try map_event(event, keypress, modifiers);
    return false;
}

fn map_event(event: input.Event, keypress: input.Key, modifiers: input.Mods) tp.result {
    switch (event) {
        input.event.press => try map_press(keypress, modifiers),
        input.event.repeat => try map_press(keypress, modifiers),
        input.event.release => try map_release(keypress),
        else => {},
    }
}

fn map_press(keypress: input.Key, modifiers: input.Mods) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        input.mod.ctrl => switch (keynormal) {
            'Q' => command.executeName("quit", .{}),
            'U' => command.executeName("mini_mode_reset", .{}),
            'G' => command.executeName("mini_mode_cancel", .{}),
            'C' => command.executeName("mini_mode_cancel", .{}),
            'L' => command.executeName("scroll_view_center_cycle", .{}),
            input.key.space => command.executeName("mini_mode_cancel", .{}),
            else => {},
        },
        0 => switch (keypress) {
            input.key.left_control, input.key.right_control => command.executeName("enable_fast_scroll", .{}),
            input.key.left_alt, input.key.right_alt => command.executeName("enable_fast_scroll", .{}),
            input.key.escape => command.executeName("mini_mode_cancel", .{}),
            input.key.enter => command.executeName("exit_mini_mode", .{}),
            input.key.backspace => command.executeName("mini_mode_delete_backwards", .{}),
            '0'...'9' => command.executeName("mini_mode_insert_code_point", command.fmt(.{keypress})),
            else => {},
        },
        else => {},
    };
}

fn map_release(keypress: input.Key) tp.result {
    return switch (keypress) {
        input.key.left_control, input.key.right_control => command.executeName("disable_fast_scroll", .{}),
        input.key.left_alt, input.key.right_alt => command.executeName("disable_fast_scroll", .{}),
        else => {},
    };
}
