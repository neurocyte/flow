const tp = @import("thespian");
const root = @import("root");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;

const tui = @import("../../../tui.zig");
const command = @import("../../../command.zig");
const EventHandler = @import("../../../EventHandler.zig");

const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const json = @import("std").json;
const eql = @import("std").mem.eql;

const Self = @This();
const input_buffer_size = 1024;

a: Allocator,
input: ArrayList(u8),
last_cmd: []const u8 = "",
leader: ?struct { keypress: u32, modifiers: u32 } = null,
count: usize = 0,

pub fn create(a: Allocator) !tui.Mode {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .input = try ArrayList(u8).initCapacity(a, input_buffer_size),
    };
    return .{
        .handler = EventHandler.to_owned(self),
        .name = root.application_logo ++ "VISUAL",
        .description = "vim",
        .line_numbers = if (tui.current().config.vim_visual_gutter_line_numbers_relative) .relative else .absolute,
    };
}

pub fn deinit(self: *Self) void {
    self.input.deinit();
    self.a.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;
    var text: []const u8 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        try self.mapEvent(evtype, keypress, egc, modifiers);
    } else if (try m.match(.{"F"})) {
        try self.flush_input();
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        try self.flush_input();
        try self.insert_bytes(text);
        try self.flush_input();
    }
    return false;
}

pub fn add_keybind() void {}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) tp.result {
    return switch (evtype) {
        event_type.PRESS => self.mapPress(keypress, egc, modifiers),
        event_type.REPEAT => self.mapPress(keypress, egc, modifiers),
        event_type.RELEASE => self.mapRelease(keypress, egc, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    if (self.leader) |_| return self.mapFollower(keynormal, egc, modifiers);
    switch (keypress) {
        key.LCTRL, key.RCTRL => return self.cmd("enable_fast_scroll", .{}),
        key.LALT, key.RALT => return self.cmd("enable_jump_mode", .{}),
        else => {},
    }
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'E' => self.cmd("enter_overlay_mode", command.fmt(.{"open_recent"})),
            'U' => self.cmd("move_scroll_page_up", .{}),
            'D' => self.cmd("move_scroll_page_down", .{}),
            'R' => self.cmd("redo", .{}),
            'O' => self.cmd("jump_back", .{}),
            'I' => self.cmd("jump_forward", .{}),

            'J' => self.cmd("toggle_logview", .{}),
            'Z' => self.cmd("undo", .{}),
            'Y' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            'S' => self.cmd("save_file", .{}),
            'L' => self.cmd_cycle3("scroll_view_center", "scroll_view_top", "scroll_view_bottom", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'B' => self.cmd("enter_move_to_char_mode", command.fmt(.{false})),
            'T' => self.cmd("enter_move_to_char_mode", command.fmt(.{true})),
            'X' => self.cmd("cut", .{}),
            'C' => self.cmd("copy", .{}),
            'V' => self.cmd("system_paste", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'F' => self.cmd("enter_find_mode", .{}),
            'G' => self.cmd("enter_goto_mode", .{}),
            'A' => self.cmd("select_all", .{}),
            '/' => self.cmd("toggle_comment", .{}),
            key.ENTER => self.cmd("smart_insert_line_after", .{}),
            key.SPACE => self.cmd("selections_reverse", .{}),
            key.END => self.cmd("select_buffer_end", .{}),
            key.HOME => self.cmd("select_buffer_begin", .{}),
            key.UP => self.cmd("select_scroll_up", .{}),
            key.DOWN => self.cmd("select_scroll_down", .{}),
            key.PGUP => self.cmd("select_scroll_page_up", .{}),
            key.PGDOWN => self.cmd("select_scroll_page_down", .{}),
            key.LEFT => self.cmd("select_word_left", .{}),
            key.RIGHT => self.cmd("select_word_right", .{}),
            key.BACKSPACE => self.cmd("delete_word_left", .{}),
            key.DEL => self.cmd("delete_word_right", .{}),
            key.F05 => self.cmd("toggle_inspector_view", .{}),
            key.F10 => self.cmd("toggle_whitespace", .{}), // aka F34
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("enter_overlay_mode", command.fmt(.{"command_palette"})),
            'D' => self.cmd("dupe_down", .{}),
            'Z' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'W' => self.cmd("close_file_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'F' => self.cmd("enter_find_in_files_mode", .{}),
            'L' => self.cmd_async("add_cursor_all_matches"),
            'I' => self.cmd_async("toggle_inspector_view"),
            '/' => self.cmd("log_widgets", .{}),
            key.ENTER => self.cmd("smart_insert_line_before", .{}),
            key.END => self.cmd("select_buffer_end", .{}),
            key.HOME => self.cmd("select_buffer_begin", .{}),
            key.UP => self.cmd("select_scroll_up", .{}),
            key.DOWN => self.cmd("select_scroll_down", .{}),
            key.LEFT => self.cmd("select_word_left", .{}),
            key.RIGHT => self.cmd("select_word_right", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'J' => self.cmd("join_next_line", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'U' => self.cmd("to_upper", .{}),
            'L' => self.cmd("to_lower", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            'B' => self.cmd("select_word_left", .{}),
            'F' => self.cmd("select_word_right", .{}),
            'S' => self.cmd("filter", command.fmt(.{"sort"})),
            'V' => self.cmd("paste", .{}),
            key.LEFT => self.cmd("jump_back", .{}),
            key.RIGHT => self.cmd("jump_forward", .{}),
            key.UP => self.cmd("pull_up", .{}),
            key.DOWN => self.cmd("pull_down", .{}),
            key.ENTER => self.cmd("insert_line", .{}),
            key.F10 => self.cmd("gutter_mode_next", .{}), // aka F58
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'D' => self.cmd("dupe_up", .{}),
            'F' => self.cmd("filter", command.fmt(.{ "zig", "fmt", "--stdin" })),
            'S' => self.cmd("filter", command.fmt(.{ "sort", "-u" })),
            'V' => self.cmd("paste", .{}),
            'I' => self.cmd("add_cursors_to_line_ends", .{}),
            key.LEFT => self.cmd("move_scroll_left", .{}),
            key.RIGHT => self.cmd("move_scroll_right", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            key.F03 => self.cmd("goto_prev_match", .{}),
            key.LEFT => self.cmd("select_left", .{}),
            key.RIGHT => self.cmd("select_right", .{}),
            key.UP => self.cmd("select_up", .{}),
            key.DOWN => self.cmd("select_down", .{}),
            key.HOME => self.cmd("smart_select_begin", .{}),
            key.END => self.cmd("select_end", .{}),
            key.PGUP => self.cmd("select_page_up", .{}),
            key.PGDOWN => self.cmd("select_page_down", .{}),
            key.ENTER => self.cmd("smart_insert_line_before", .{}),
            key.BACKSPACE => self.cmd("delete_backward", .{}),
            key.TAB => self.cmd("unindent", .{}),

            ';' => self.cmd("enter_overlay_mode", command.fmt(.{"command_palette"})),
            'N' => self.cmd("goto_prev_match", .{}),
            'A' => self.seq(.{ "move_end", "enter_mode" }, command.fmt(.{"vim/insert"})),
            '4' => self.cmd("select_end", .{}),
            'G' => if (self.count == 0)
                self.cmd("move_buffer_end", .{})
            else {
                const count = self.count;
                try self.cmd("move_buffer_begin", .{});
                self.count = count - 1;
                if (self.count > 0)
                    try self.cmd_count("move_down", .{});
            },

            'O' => self.seq(.{ "smart_insert_line_before", "enter_mode" }, command.fmt(.{"vim/insert"})),

            else => {},
        },
        0 => switch (keypress) {
            key.F02 => self.cmd("toggle_input_mode", .{}),
            key.F03 => self.cmd("goto_next_match", .{}),
            key.F15 => self.cmd("goto_prev_match", .{}), // S-F3
            key.F05 => self.cmd("toggle_inspector_view", .{}), // C-F5
            key.F06 => self.cmd("dump_current_line_tree", .{}),
            key.F07 => self.cmd("dump_current_line", .{}),
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.F11 => self.cmd("toggle_logview", .{}),
            key.F12 => self.cmd("goto_definition", .{}),
            key.F34 => self.cmd("toggle_whitespace", .{}), // C-F10
            key.F58 => self.cmd("gutter_mode_next", .{}), // A-F10
            key.ESC => self.seq(.{ "cancel", "enter_mode" }, command.fmt(.{"vim/normal"})),
            key.ENTER => self.cmd("smart_insert_line", .{}),
            key.DEL => self.cmd("delete_forward", .{}),
            key.BACKSPACE => self.cmd("delete_backward", .{}),

            ':' => self.cmd("enter_overlay_mode", command.fmt(.{"command_palette"})),
            'i' => self.cmd("enter_mode", command.fmt(.{"vim/insert"})),
            'a' => self.seq(.{ "move_right", "enter_mode" }, command.fmt(.{"vim/insert"})),
            'v' => self.cmd("enter_mode", command.fmt(.{"vim/visual"})),

            '/' => self.cmd("enter_find_mode", .{}),
            'n' => self.cmd("goto_next_match", .{}),

            'h' => self.cmd_count("select_left", .{}),
            'j' => self.cmd_count("select_down", .{}),
            'k' => self.cmd_count("select_up", .{}),
            'l' => self.cmd_count("select_right", .{}),
            ' ' => self.cmd_count("select_right", .{}),

            'b' => self.cmd_count("select_word_left", .{}),
            'w' => self.cmd_count("select_word_right_vim", .{}),
            'e' => self.cmd_count("select_word_right", .{}),

            '$' => self.cmd_count("select_end", .{}),
            '0' => self.cmd_count("select_begin", .{}),

            '1' => self.add_count(1),
            '2' => self.add_count(2),
            '3' => self.add_count(3),
            '4' => self.add_count(4),
            '5' => self.add_count(5),
            '6' => self.add_count(6),
            '7' => self.add_count(7),
            '8' => self.add_count(8),
            '9' => self.add_count(9),

            'u' => self.cmd("undo", .{}),

            'd' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'r' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'c' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'z' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'g' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },

            'x' => self.cmd("cut", .{}),
            'y' => self.cmd("copy", .{}),
            'p' => self.cmd("paste", .{}),
            'o' => self.seq(.{ "insert_line_after", "enter_mode" }, command.fmt(.{"vim/insert"})),

            key.LEFT => self.cmd("select_left", .{}),
            key.RIGHT => self.cmd("select_right", .{}),
            key.UP => self.cmd("select_up", .{}),
            key.DOWN => self.cmd("select_down", .{}),
            key.HOME => self.cmd("smart_select_begin", .{}),
            key.END => self.cmd("select_end", .{}),
            key.PGUP => self.cmd("select_page_up", .{}),
            key.PGDOWN => self.cmd("select_page_down", .{}),
            key.TAB => self.cmd("indent", .{}),
            else => {},
        },
        else => {},
    };
}

fn mapFollower(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    if (keypress == key.LCTRL or
        keypress == key.RCTRL or
        keypress == key.LALT or
        keypress == key.RALT or
        keypress == key.LSHIFT or
        keypress == key.RSHIFT or
        keypress == key.LSUPER or
        keypress == key.RSUPER) return;

    switch (modifiers) {
        0 => switch (keypress) {
            '1' => {
                self.add_count(1);
                return;
            },
            '2' => {
                self.add_count(2);
                return;
            },
            '3' => {
                self.add_count(3);
                return;
            },
            '4' => {
                self.add_count(4);
                return;
            },
            '5' => {
                self.add_count(5);
                return;
            },
            '6' => {
                self.add_count(6);
                return;
            },
            '7' => {
                self.add_count(7);
                return;
            },
            '8' => {
                self.add_count(8);
                return;
            },
            '9' => {
                self.add_count(9);
                return;
            },
            else => {},
        },
        else => {},
    }

    defer self.leader = null;
    const ldr = if (self.leader) |leader| leader else return;
    return switch (ldr.modifiers) {
        mod.CTRL => switch (ldr.keypress) {
            'K' => switch (modifiers) {
                mod.CTRL => switch (keypress) {
                    'U' => self.cmd("delete_to_begin", .{}),
                    'K' => self.cmd("delete_to_end", .{}),
                    'D' => self.cmd("move_cursor_next_match", .{}),
                    else => {},
                },
                else => {},
            },
            else => {},
        },
        0 => switch (ldr.keypress) {
            'D', 'C' => {
                try switch (modifiers) {
                    mod.SHIFT => switch (keypress) {
                        '4' => self.cmd("delete_to_end", .{}),
                        else => {},
                    },
                    0 => switch (keypress) {
                        'D' => self.seq_count(.{ "move_begin", "select_end", "select_right", "cut" }, .{}),
                        'W' => self.seq_count(.{ "select_word_right", "select_word_right", "select_word_left", "cut" }, .{}),
                        'E' => self.seq_count(.{ "select_word_right", "cut" }, .{}),
                        else => {},
                    },
                    else => switch (egc) {
                        '$' => self.cmd("delete_to_end", .{}),
                        else => {},
                    },
                };
                if (ldr.keypress == 'C')
                    try self.cmd("enter_mode", command.fmt(.{"vim/insert"}));
            },
            'R' => switch (modifiers) {
                mod.SHIFT, 0 => if (!key.synthesized_p(keypress)) {
                    var count = self.count;
                    try self.cmd_count("delete_forward", .{});
                    while (count > 0) : (count -= 1)
                        try self.insert_code_point(egc);
                },
                else => {},
            },
            'Z' => switch (modifiers) {
                0 => switch (keypress) {
                    'Z' => self.cmd_cycle3("scroll_view_center", "scroll_view_top", "scroll_view_bottom", .{}),
                    else => {},
                },
                else => {},
            },
            'G' => switch (modifiers) {
                0 => switch (keypress) {
                    'G' => self.cmd("move_buffer_begin", .{}),
                    else => {},
                },
                else => {},
            },
            else => {},
        },
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32, _: u32) tp.result {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => self.cmd("disable_fast_scroll", .{}),
        key.LALT, key.RALT => self.cmd("disable_jump_mode", .{}),
        else => {},
    };
}

fn add_count(self: *Self, value: usize) void {
    if (self.count > 0) self.count *= 10;
    self.count += value;
}

fn insert_code_point(self: *Self, c: u32) tp.result {
    if (self.input.items.len + 4 > input_buffer_size)
        try self.flush_input();
    var buf: [6]u8 = undefined;
    const bytes = ucs32_to_utf8(&[_]u32{c}, &buf) catch |e| return tp.exit_error(e);
    self.input.appendSlice(buf[0..bytes]) catch |e| return tp.exit_error(e);
}

fn insert_bytes(self: *Self, bytes: []const u8) tp.result {
    if (self.input.items.len + 4 > input_buffer_size)
        try self.flush_input();
    self.input.appendSlice(bytes) catch |e| return tp.exit_error(e);
}

var insert_chars_id: ?command.ID = null;

fn flush_input(self: *Self) tp.result {
    if (self.input.items.len > 0) {
        defer self.input.clearRetainingCapacity();
        const id = insert_chars_id orelse command.get_id_cache("insert_chars", &insert_chars_id) orelse {
            return tp.exit_error(error.InputTargetNotFound);
        };
        try command.execute(id, command.fmt(.{self.input.items}));
        self.last_cmd = "insert_chars";
    }
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.count = 0;
    try self.flush_input();
    self.last_cmd = name_;
    try command.executeName(name_, ctx);
}

fn cmd_count(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    var count = if (self.count == 0) 1 else self.count;
    self.count = 0;
    try self.flush_input();
    self.last_cmd = name_;
    while (count > 0) : (count -= 1)
        try command.executeName(name_, ctx);
}

fn cmd_cycle3(self: *Self, name1: []const u8, name2: []const u8, name3: []const u8, ctx: command.Context) tp.result {
    return if (eql(u8, self.last_cmd, name2))
        self.cmd(name3, ctx)
    else if (eql(u8, self.last_cmd, name1))
        self.cmd(name2, ctx)
    else
        self.cmd(name1, ctx);
}

fn cmd_async(self: *Self, name_: []const u8) tp.result {
    self.last_cmd = name_;
    return tp.self_pid().send(.{ "cmd", name_ });
}

fn seq(self: *Self, cmds: anytype, ctx: command.Context) tp.result {
    const cmds_type_info = @typeInfo(@TypeOf(cmds));
    if (cmds_type_info != .Struct) @compileError("expected tuple argument");
    const fields_info = cmds_type_info.Struct.fields;
    inline for (fields_info) |field_info|
        try self.cmd(@field(cmds, field_info.name), ctx);
}

fn seq_count(self: *Self, cmds: anytype, ctx: command.Context) tp.result {
    var count = if (self.count == 0) 1 else self.count;
    self.count = 0;
    const cmds_type_info = @typeInfo(@TypeOf(cmds));
    if (cmds_type_info != .Struct) @compileError("expected tuple argument");
    const fields_info = cmds_type_info.Struct.fields;
    while (count > 0) : (count -= 1)
        inline for (fields_info) |field_info|
            try self.cmd(@field(cmds, field_info.name), ctx);
}
