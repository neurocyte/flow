const tp = @import("thespian");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command");
const EventHandler = @import("EventHandler");

pub fn create(_: @import("std").mem.Allocator, _: anytype) !EventHandler {
    return EventHandler.static(@This());
}

pub fn receive(_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var modifiers: u32 = undefined;
    var egc: u32 = undefined;
    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) }))
        try mapEvent(evtype, keypress, egc, modifiers);
    return false;
}

fn mapEvent(evtype: u32, keypress: u32, egc: u32, modifiers: u32) tp.result {
    switch (evtype) {
        event_type.PRESS => try mapPress(keypress, egc, modifiers),
        else => {},
    }
}

fn mapPress(keypress: u32, egc: u32, modifiers: u32) tp.result {
    switch (keypress) {
        key.LSUPER, key.RSUPER => return,
        key.LSHIFT, key.RSHIFT => return,
        key.LCTRL, key.RCTRL => return,
        key.LALT, key.RALT => return,
        else => {},
    }
    return switch (modifiers) {
        mod.SHIFT => if (!key.synthesized_p(keypress))
            command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
        else
            command.executeName("mini_mode_cancel", .{}),
        0 => switch (keypress) {
            key.ESC => command.executeName("mini_mode_cancel", .{}),
            key.ENTER => command.executeName("mini_mode_cancel", .{}),
            else => if (!key.synthesized_p(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else
                command.executeName("mini_mode_cancel", .{}),
        },
        else => command.executeName("mini_mode_cancel", .{}),
    };
}
