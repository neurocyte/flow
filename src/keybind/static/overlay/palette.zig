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
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn mapEvent(evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
    return switch (evtype) {
        event_type.PRESS => mapPress(keypress, egc, modifiers),
        event_type.REPEAT => mapPress(keypress, egc, modifiers),
        event_type.RELEASE => mapRelease(keypress, modifiers),
        else => {},
    };
}

fn mapPress(keypress: u32, egc: u32, modifiers: u32) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
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
            key.ESC => command.executeName("palette_menu_cancel", .{}),
            key.UP => command.executeName("palette_menu_up", .{}),
            key.DOWN => command.executeName("palette_menu_down", .{}),
            key.PGUP => command.executeName("palette_menu_pageup", .{}),
            key.PGDOWN => command.executeName("palette_menu_pagedown", .{}),
            key.ENTER => command.executeName("palette_menu_activate", .{}),
            key.BACKSPACE => command.executeName("overlay_delete_word_left", .{}),
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'E' => command.executeName("palette_menu_up", .{}), // open recent repeat key
            'R' => command.executeName("palette_menu_up", .{}), // open recent project repeat key
            'P' => command.executeName("palette_menu_down", .{}), // command palette repeat key
            'Q' => command.executeName("quit_without_saving", .{}),
            'W' => command.executeName("close_file_without_saving", .{}),
            'L' => command.executeName("overlay_toggle_panel", .{}),
            'I' => command.executeName("overlay_toggle_inputview", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'P' => command.executeName("palette_menu_down", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'P' => command.executeName("palette_menu_up", .{}),
            'L' => command.executeName("toggle_panel", .{}),
            'I' => command.executeName("toggle_inputview", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            else => if (!key.synthesized_p(keypress))
                command.executeName("overlay_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        0 => switch (keypress) {
            key.F09 => command.executeName("theme_prev", .{}),
            key.F10 => command.executeName("theme_next", .{}),
            key.F11 => command.executeName("toggle_panel", .{}),
            key.F12 => command.executeName("toggle_inputview", .{}),
            key.ESC => command.executeName("palette_menu_cancel", .{}),
            key.UP => command.executeName("palette_menu_up", .{}),
            key.DOWN => command.executeName("palette_menu_down", .{}),
            key.PGUP => command.executeName("palette_menu_pageup", .{}),
            key.PGDOWN => command.executeName("palette_menu_pagedown", .{}),
            key.ENTER => command.executeName("palette_menu_activate", .{}),
            key.BACKSPACE => command.executeName("overlay_delete_backwards", .{}),
            else => if (!key.synthesized_p(keypress))
                command.executeName("overlay_insert_code_point", command.fmt(.{egc}))
            else {},
        },
        else => {},
    };
}

fn mapRelease(keypress: u32, _: u32) !void {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => command.executeName("overlay_release_control", .{}),
        else => {},
    };
}
