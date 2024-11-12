pub const mode = struct {
    pub const input = struct {
        pub const flow = @import("input/flow.zig");
        pub const home = @import("input/home.zig");
    };
    pub const overlay = struct {
        pub const palette = @import("overlay/palette.zig");
    };
    pub const mini = struct {
        pub const goto = @import("mini/goto.zig");
        pub const move_to_char = @import("mini/move_to_char.zig");
        pub const file_browser = @import("mini/file_browser.zig");
        pub const find_in_files = @import("mini/find_in_files.zig");
        pub const find = @import("mini/find.zig");
    };
};

pub const Mode = struct {
    input_handler: EventHandler,
    event_handler: ?EventHandler = null,

    name: []const u8 = "",
    line_numbers: enum { absolute, relative } = .absolute,
    keybind_hints: ?*const KeybindHints = null,
    cursor_shape: renderer.CursorShape = .block,

    pub fn deinit(self: *Mode) void {
        self.input_handler.deinit();
        if (self.event_handler) |eh| eh.deinit();
    }
};

pub const KeybindHints = std.static_string_map.StaticStringMap([]const u8);

const renderer = @import("renderer");
const EventHandler = @import("EventHandler");
const std = @import("std");
