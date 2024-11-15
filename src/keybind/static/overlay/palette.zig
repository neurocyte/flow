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
    return switch (event) {
        input.event.press => map_press(keypress, egc, modifiers),
        input.event.repeat => map_press(keypress, egc, modifiers),
        input.event.release => map_release(keypress),
        else => {},
    };
}

fn map_press(keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        input.mod.ctrl => switch (keynormal) {
            'J' => command.executeName("toggle_panel", .{}),
            'Q' => command.executeName("quit", .{}),
            'W' => command.executeName("close_file", .{}),
            'P' => command.executeName("palette_menu_up", .{}),
            'N' => command.executeName("palette_menu_down", .{}),
            'E' => command.executeName("palette_menu_down", .{}), // open recent repeat key
            'R' => command.executeName("palette_menu_down", .{}), // open recent project repeat key
            'T' => command.executeName("palette_menu_down", .{}), // select theme repeat key
            'V' => command.executeName("system_paste", .{}),
            'C' => command.executeName("palette_menu_cancel", .{}),
            'G' => command.executeName("palette_menu_cancel", .{}),
            input.key.escape => command.executeName("palette_menu_cancel", .{}),
            input.key.up => command.executeName("palette_menu_up", .{}),
            input.key.down => command.executeName("palette_menu_down", .{}),
            input.key.page_up => command.executeName("palette_menu_pageup", .{}),
            input.key.page_down => command.executeName("palette_menu_pagedown", .{}),
            input.key.enter => command.executeName("palette_menu_activate", .{}),
            input.key.backspace => command.executeName("overlay_delete_word_left", .{}),
            else => {},
        },
        input.mod.ctrl | input.mod.shift => switch (keynormal) {
            'E' => command.executeName("palette_menu_up", .{}), // open recent repeat key
            'R' => command.executeName("palette_menu_up", .{}), // open recent project repeat key
            'P' => command.executeName("palette_menu_down", .{}), // command palette repeat key
            'Q' => command.executeName("quit_without_saving", .{}),
            'W' => command.executeName("close_file_without_saving", .{}),
            'L' => command.executeName("overlay_toggle_panel", .{}),
            'I' => command.executeName("overlay_toggle_inputview", .{}),
            else => {},
        },
        input.mod.alt | input.mod.shift => switch (keynormal) {
            'P' => command.executeName("palette_menu_down", .{}),
            else => {},
        },
        input.mod.alt => switch (keynormal) {
            'P' => command.executeName("palette_menu_up", .{}),
            'L' => command.executeName("toggle_panel", .{}),
            'I' => command.executeName("toggle_inputview", .{}),
            else => {},
        },
        input.mod.shift => switch (keypress) {
            else => if (!input.is_non_input_key(keypress))
                command.executeName("overlay_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        0 => switch (keypress) {
            input.key.f9 => command.executeName("theme_prev", .{}),
            input.key.f10 => command.executeName("theme_next", .{}),
            input.key.f11 => command.executeName("toggle_panel", .{}),
            input.key.f12 => command.executeName("toggle_inputview", .{}),
            input.key.escape => command.executeName("palette_menu_cancel", .{}),
            input.key.up => command.executeName("palette_menu_up", .{}),
            input.key.down => command.executeName("palette_menu_down", .{}),
            input.key.page_up => command.executeName("palette_menu_pageup", .{}),
            input.key.page_down => command.executeName("palette_menu_pagedown", .{}),
            input.key.enter => command.executeName("palette_menu_activate", .{}),
            input.key.backspace => command.executeName("overlay_delete_backwards", .{}),
            else => if (!input.is_non_input_key(keypress))
                command.executeName("overlay_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        else => {},
    };
}

fn map_release(keypress: input.Key) !void {
    return switch (keypress) {
        input.key.left_control, input.key.right_control => command.executeName("overlay_release_control", .{}),
        else => {},
    };
}
