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

    if (try m.match(.{ "I", tp.extract(&event), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        map_event(event, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn map_event(event: input.Event, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    switch (event) {
        input.event.press => try map_press(keypress, egc, modifiers),
        input.event.repeat => try map_press(keypress, egc, modifiers),
        else => {},
    }
}

fn map_press(keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        input.mod.ctrl => switch (keynormal) {
            'Q' => command.executeName("quit", .{}),
            'V' => command.executeName("system_paste", .{}),
            'U' => command.executeName("mini_mode_reset", .{}),
            'G' => command.executeName("mini_mode_cancel", .{}),
            'C' => command.executeName("mini_mode_cancel", .{}),
            'L' => command.executeName("scroll_view_center", .{}),
            'I' => command.executeName("mini_mode_insert_bytes", command.fmt(.{"\t"})),
            input.key.space => command.executeName("mini_mode_cancel", .{}),
            input.key.backspace => command.executeName("mini_mode_delete_to_previous_path_segment", .{}),
            else => {},
        },
        input.mod.alt => switch (keynormal) {
            'V' => command.executeName("system_paste", .{}),
            else => {},
        },
        input.mod.alt | input.mod.shift => switch (keynormal) {
            'V' => command.executeName("system_paste", .{}),
            else => {},
        },
        input.mod.shift => switch (keypress) {
            input.key.tab => command.executeName("mini_mode_reverse_complete_file", .{}),
            else => if (!input.is_non_input_key(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        0 => switch (keypress) {
            input.key.up => command.executeName("mini_mode_reverse_complete_file", .{}),
            input.key.down => command.executeName("mini_mode_try_complete_file", .{}),
            input.key.right => command.executeName("mini_mode_try_complete_file_forward", .{}),
            input.key.left => command.executeName("mini_mode_delete_to_previous_path_segment", .{}),
            input.key.tab => command.executeName("mini_mode_try_complete_file", .{}),
            input.key.escape => command.executeName("mini_mode_cancel", .{}),
            input.key.enter => command.executeName("mini_mode_select", .{}),
            input.key.backspace => command.executeName("mini_mode_delete_backwards", .{}),
            else => if (!input.is_non_input_key(keypress))
                command.executeName("mini_mode_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        else => {},
    };
}
