const tp = @import("thespian");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command");
const EventHandler = @import("EventHandler");

const Allocator = @import("std").mem.Allocator;

pub fn create(_: Allocator) EventHandler {
    return EventHandler.static(@This());
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
            'G' => command.executeName("mini_mode_cancel", .{}),
            'C' => command.executeName("mini_mode_cancel", .{}),
            'L' => command.executeName("scroll_view_center", .{}),
            'I' => command.executeName("mini_mode_insert_bytes", command.fmt(.{"\t"})),
            key.SPACE => command.executeName("mini_mode_cancel", .{}),
            key.BACKSPACE => command.executeName("mini_mode_delete_to_previous_path_segment", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'V' => command.executeName("system_paste", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'V' => command.executeName("system_paste", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            key.TAB => command.executeName("mini_mode_reverse_complete_file", .{}),
            else => if (!key.synthesized_p(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        0 => switch (keypress) {
            key.UP => command.executeName("mini_mode_reverse_complete_file", .{}),
            key.DOWN => command.executeName("mini_mode_try_complete_file", .{}),
            key.RIGHT => command.executeName("mini_mode_try_complete_file_forward", .{}),
            key.LEFT => command.executeName("mini_mode_delete_to_previous_path_segment", .{}),
            key.TAB => command.executeName("mini_mode_try_complete_file", .{}),
            key.ESC => command.executeName("mini_mode_cancel", .{}),
            key.ENTER => command.executeName("mini_mode_select", .{}),
            key.BACKSPACE => command.executeName("mini_mode_delete_backwards", .{}),
            else => if (!key.synthesized_p(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        else => {},
    };
}
