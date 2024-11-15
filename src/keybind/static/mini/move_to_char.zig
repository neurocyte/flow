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
    var egc: input.Key = undefined;
    var modifiers: input.Mods = undefined;
    if (try m.match(.{ "I", tp.extract(&event), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) }))
        try map_event(event, keypress, egc, modifiers);
    return false;
}

fn map_event(event: input.Event, keypress: input.Key, egc: input.Key, modifiers: input.Mods) tp.result {
    switch (event) {
        input.event.press => try map_press(keypress, egc, modifiers),
        else => {},
    }
}

fn map_press(keypress: input.Key, egc: input.Key, modifiers: input.Mods) tp.result {
    switch (keypress) {
        input.key.left_super, input.key.right_super => return,
        input.key.left_shift, input.key.right_shift => return,
        input.key.left_control, input.key.right_control => return,
        input.key.left_alt, input.key.right_alt => return,
        else => {},
    }
    return switch (modifiers) {
        input.mod.shift => if (!input.is_non_input_key(keypress))
            command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
        else
            command.executeName("mini_mode_cancel", .{}),
        0 => switch (keypress) {
            input.key.escape => command.executeName("mini_mode_cancel", .{}),
            input.key.enter => command.executeName("mini_mode_cancel", .{}),
            else => if (!input.is_non_input_key(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else
                command.executeName("mini_mode_cancel", .{}),
        },
        else => command.executeName("mini_mode_cancel", .{}),
    };
}
