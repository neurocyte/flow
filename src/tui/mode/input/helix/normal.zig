const tp = @import("thespian");

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
commands: Commands = undefined,

pub fn create(a: Allocator) !tui.Mode {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .input = try ArrayList(u8).initCapacity(a, input_buffer_size),
    };
    try self.commands.init(self);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "NOR",
        .description = "helix",
        .line_numbers = if (tui.current().config.vim_normal_gutter_line_numbers_relative) .relative else .absolute,
        .keybind_hints = &hints,
        .cursor_shape = .block,
    };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
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
        self.mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{"F"})) {
        self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

pub fn add_keybind() void {}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
    return switch (evtype) {
        event_type.PRESS => self.mapPress(keypress, egc, modifiers),
        event_type.REPEAT => self.mapPress(keypress, egc, modifiers),
        event_type.RELEASE => self.mapRelease(keypress, egc, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) !void {
    if (self.count > 0 and modifiers == 0 and '0' <= keypress and keypress <= '9') return self.add_count(keypress - '0');
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    if (self.leader) |_| return self.mapFollower(keynormal, egc, modifiers);
    switch (keypress) {
        key.LCTRL, key.RCTRL => return self.cmd("enable_fast_scroll", .{}),
        key.LALT, key.RALT => return self.cmd("enable_jump_mode", .{}),
        else => {},
    }
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'E' => self.cmd("open_recent", .{}),
            'U' => self.cmd("move_scroll_page_up", .{}),
            'D' => self.cmd("move_scroll_page_down", .{}),
            'O' => self.cmd("jump_back", .{}),
            'I' => self.cmd("jump_forward", .{}),

            'X' => self.cmd("cut", .{}),
            'C' => self.cmd("copy", .{}),
            'V' => self.cmd("system_paste", .{}),
            'W' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'c' => self.cmd("toggle_comment", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'N' => self.cmd("pull_back", .{}), // next sibling
            '`' => self.cmd("to_upper", .{}),
            'd' => self.cmd("delete_backward", .{}),
            'c' => {
                try self.cmd("delete_backward", .{});
                try self.cmd("enter_mode", command.fmt(.{"helix/insert"}));
            },
            's' => self.cmd("toggle_inputview", .{}),
            '-' => self.cmd("move_word_left", .{}),
            '_' => self.cmd("move_word_right", .{}),
            ';' => self.cmd("filter", command.fmt(.{"sort"})),
            'O' => self.cmd("pull_up", .{}),
            key.UP => self.cmd("pull_up", .{}),
            'P' => self.cmd("pull_left", .{}),
            key.RIGHT => self.cmd("jump_forward", .{}),
            'I' => self.cmd("jump_back", .{}),
            key.DOWN => self.cmd("pull_down", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'C' => self.cmd("select_up", .{}),
            'I' => self.cmd("dupe_up", .{}), // select all children
            key.DOWN => self.cmd("dupe_up", .{}), // select all children
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            'r' => self.cmd("goto_prev_match", .{}), // replace with yanked
            key.TAB => self.cmd("unindent", .{}),

            ';' => self.cmd("open_command_palette", .{}),
            'n' => self.cmd("goto_prev_match", .{}),
            'a' => self.seq(.{ "move_end", "enter_mode" }, command.fmt(.{"helix/insert"})),
            'i' => self.seq(.{ "smart_move_begin", "enter_mode" }, command.fmt(.{"helix/insert"})),
            'w' => self.cmd("select_word_right", .{}), // move long word next
            'b' => self.cmd("select_word_left", .{}), // move long word prev
            'e' => self.cmd("select_word_end", .{}), // move long word end
            'c' => self.cmd("select_down", .{}), // copy_selection_on_next_line
            's' => self.cmd("select_down", .{}), // split_selection
            '5' => self.cmd("select_all", .{}),
            'x' => self.cmd("extend", .{}), // extend_to_line_bounds
            'p' => self.cmd("paste", .{}), // paste_before
            'u' => self.cmd("undo", .{}),
            'g' => if (self.count == 0)
                self.cmd("move_buffer_end", .{})
            else {
                const count = self.count;
                try self.cmd("move_buffer_begin", .{});
                self.count = count - 1;
                if (self.count > 0)
                    try self.cmd_count("move_down", .{});
            },

            'o' => self.seq(.{ "smart_insert_line_before", "enter_mode" }, command.fmt(.{"helix/insert"})),

            else => {},
        },
        0 => switch (keypress) {
            key.ESC => self.cmd("cancel", .{}),
            key.ENTER => self.cmd("smart_insert_line", .{}),

            ':' => self.cmd("open_command_palette", .{}),
            '%' => self.cmd("select_all", .{}),
            'i' => self.cmd("enter_mode", command.fmt(.{"helix/insert"})),
            'a' => self.seq(.{ "move_right", "enter_mode" }, command.fmt(.{"helix/insert"})),
            'v' => self.cmd("enter_mode", command.fmt(.{"helix/select"})),

            '/' => self.cmd("find", .{}),
            'n' => self.cmd("goto_next_match", .{}),

            'h' => self.cmd_count("move_left", .{}),
            'j' => self.cmd_count("move_down", .{}),
            'k' => self.cmd_count("move_up", .{}),
            'l' => self.cmd_count("move_right", .{}),

            'b' => self.cmd_count("select_word_left", .{}),
            'w' => self.cmd_count("select_word_right", .{}),
            'e' => self.cmd_count("select_word_end", .{}),

            'd' => self.cmd("cut", .{}),
            'c' => {
                try self.cmd("cut", .{});
                try self.cmd("enter_mode", command.fmt(.{"helix/insert"}));
            },
            's' => self.cmd("select", .{}), // select regex
            ';' => self.cmd("collapse_cursors", .{}),
            '*' => self.cmd("find_selection_match", .{}),
            '1' => self.add_count(1),
            '2' => self.add_count(2),
            '3' => self.add_count(3),
            '4' => self.add_count(4),
            '5' => self.add_count(5),
            '6' => self.add_count(6),
            '7' => self.add_count(7),
            '8' => self.add_count(8),
            '9' => self.add_count(9),

            'x' => self.cmd_count("select_line_at_cursor", .{}),
            'u' => self.cmd("undo", .{}),

            'm' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'r' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            '[' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            ']' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'z' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            ' ' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'g' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            '>' => self.cmd("indent", .{}),
            '<' => self.cmd("unindent", .{}),
            ',' => self.cmd("cancel", .{}),

            'p' => self.cmd("paste", .{}),
            'y' => self.cmd("yank", .{}),
            'o' => self.seq(.{ "smart_insert_line_after", "enter_mode" }, command.fmt(.{"helix/insert"})),

            key.LEFT => self.cmd("move_left", .{}),
            key.RIGHT => self.cmd("move_right", .{}),
            key.UP => self.cmd("move_up", .{}),
            key.DOWN => self.cmd("move_down", .{}),
            key.HOME => self.cmd("smart_move_begin", .{}),
            key.END => self.cmd("move_end", .{}),
            key.PGUP => self.cmd("move_page_up", .{}),
            key.PGDOWN => self.cmd("move_page_down", .{}),
            key.TAB => self.cmd("indent", .{}),
            else => {},
        },
        else => {},
    };
}

fn mapFollower(self: *Self, keypress: u32, _: u32, modifiers: u32) !void {
    if (keypress == key.LCTRL or
        keypress == key.RCTRL or
        keypress == key.LALT or
        keypress == key.RALT or
        keypress == key.LSHIFT or
        keypress == key.RSHIFT or
        keypress == key.LSUPER or
        keypress == key.RSUPER) return;

    defer self.leader = null;
    const ldr = if (self.leader) |leader| leader else return;
    return switch (ldr.modifiers) {
        0 => switch (ldr.keypress) {
            'm' => {
                // apparently not a thing
            },
            '[' => {
                try switch (modifiers) {
                    0 => switch (keypress) {
                        'd' => self.cmd("goto_next_diagnostic", .{}),
                        'D' => self.cmd("goto_next_diagnostic", .{}), // goto last diagnostic
                        else => {},
                    },
                    else => {},
                };
            },
            ']' => {
                try switch (modifiers) {
                    0 => switch (keypress) {
                        'd' => self.cmd("goto_prev_diagnostic", .{}),
                        'D' => self.cmd("goto_prev_diagnostic", .{}), // goto first diagnostic
                        else => {},
                    },
                    else => {},
                };
            },
            ' ' => switch (modifiers) {
                0 => switch (keypress) {
                    'F' => self.cmd("open_file", .{}),
                    'B' => self.cmd("open_buffer", .{}),
                    'Y' => self.cmd("yank", .{}),
                    'P' => self.cmd("paste", .{}),
                    '/' => self.cmd("find", .{}),
                    'K' => self.cmd("hover", .{}),
                    'C' => self.cmd("toggle_comment", .{}),
                    else => {},
                },
                else => {},
            },
            'G' => switch (modifiers) {
                0 => switch (keypress) {
                    'G' => self.cmd("move_buffer_begin", .{}),
                    'E' => self.cmd("move_buffer_end", .{}),
                    'D' => self.cmd("goto_definition", .{}),
                    'I' => self.cmd("goto_implementation", .{}),
                    'Y' => self.cmd("goto_type_definition", .{}),
                    else => {},
                },
                mod.SHIFT => switch (keypress) {
                    'D' => self.cmd("goto_declaration", .{}),
                    else => {},
                },
                else => {},
            },
            'w' => switch (modifiers) {
                mod.SHIFT => switch (keypress) {
                    else => {},
                },
                0 => switch (keypress) {
                    else => {},
                },
                else => {},
            },
            else => {},
        },
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32, _: u32) !void {
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

fn insert_code_point(self: *Self, c: u32) !void {
    if (self.input.items.len + 4 > input_buffer_size)
        try self.flush_input();
    var buf: [6]u8 = undefined;
    const bytes = try ucs32_to_utf8(&[_]u32{c}, &buf);
    try self.input.appendSlice(buf[0..bytes]);
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    if (self.input.items.len + 4 > input_buffer_size)
        try self.flush_input();
    try self.input.appendSlice(bytes);
}

var insert_chars_id: ?command.ID = null;

fn flush_input(self: *Self) !void {
    if (self.input.items.len > 0) {
        defer self.input.clearRetainingCapacity();
        const id = insert_chars_id orelse command.get_id_cache("insert_chars", &insert_chars_id) orelse {
            return tp.exit_error(error.InputTargetNotFound, null);
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

const hints = tui.KeybindHints.initComptime(.{
    .{ "add_cursor_all_matches", "C-S-l" },
    .{ "add_cursor_down", "S-A-down" },
    .{ "add_cursor_next_match", "C-d" },
    .{ "add_cursors_to_line_ends", "S-A-i" },
    .{ "add_cursor_up", "S-A-up" },
    .{ "cancel", "esc" },
    .{ "close_file", "C-w" },
    .{ "close_file_without_saving", "C-S-w" },
    .{ "copy", "C-c" },
    .{ "cut", "C-x" },
    .{ "delete_backward", "backspace" },
    .{ "delete_forward", "del, x" },
    .{ "delete_to_begin", "C-k C-u" },
    .{ "delete_to_end", "C-k C-k, d $" },
    .{ "delete_word_left", "C-backspace" },
    .{ "delete_word_right", "C-del" },
    .{ "dump_current_line", "F7" },
    .{ "dump_current_line_tree", "F6" },
    .{ "dupe_down", "C-S-d" },
    .{ "dupe_up", "S-A-d" },
    .{ "enable_fast_scroll", "hold Ctrl" },
    .{ "enable_jump_mode", "hold Alt" },
    .{ "find_in_files", "C-S-f" },
    .{ "find", "C-f, /" },
    .{ "goto", "C-g" },
    .{ "move_to_char", "C-b, C-t" }, // true/false
    .{ "open_file", "C-o" },
    .{ "filter", "A-s" }, // self.cmd("filter", command.fmt(.{"sort"})),
    // .{ "filter", "S-A-s" }, // self.cmd("filter", command.fmt(.{ "sort", "-u" })),
    .{ "format", "S-A-f" },
    .{ "goto_definition", "F12, g d" },
    .{ "goto_declaration", "g D" },
    .{ "goto_implementation", "g i" },
    .{ "goto_type_definition", "g y" },
    .{ "goto_next_file_or_diagnostic", "A-n" },
    .{ "goto_next_match", "C-n, F3, n" },
    .{ "goto_prev_file_or_diagnostic", "A-p" },
    .{ "goto_prev_match", "C-p, S-F3, N" },
    .{ "gutter_mode_next", "A-F10" },
    .{ "indent", "tab" },
    .{ "insert_line", "A-enter" },
    .{ "join_next_line", "A-j" },
    .{ "jump_back", "A-left" },
    .{ "jump_forward", "A-right" },
    .{ "move_begin", "0" },
    .{ "move_buffer_begin", "C-home, g g" },
    .{ "move_buffer_end", "C-end, G" },
    .{ "move_cursor_next_match", "C-k C-d" },
    .{ "move_down", "down, j" },
    .{ "move_end", "end, $, S-4" },
    .{ "move_left", "left" },
    .{ "move_left_vim", "h" },
    .{ "move_page_down", "pgdn" },
    .{ "move_page_up", "pgup" },
    .{ "move_right", "right" },
    .{ "move_right_vim", "l, space" },
    .{ "move_scroll_down", "C-down" },
    .{ "move_scroll_left", "S-A-left" },
    .{ "move_scroll_page_down", "C-pgdn" },
    .{ "move_scroll_page_up", "C-pgup" },
    .{ "move_scroll_right", "S-A-right" },
    .{ "move_scroll_up", "C-up" },
    .{ "move_up", "up, k" },
    .{ "move_word_left", "C-left, A-b, b" },
    .{ "move_word_right", "C-right, A-f, e" },
    .{ "move_word_right_vim", "w" },
    .{ "open_command_palette", "C-S-p, :, S-;, S-A-p" },
    .{ "open_recent", "C-e" },
    .{ "paste", "A-v, p" },
    .{ "pop_cursor", "C-u" },
    .{ "pull_down", "A-down" },
    .{ "pull_up", "A-up" },
    .{ "quit", "C-q" },
    .{ "quit_without_saving", "C-S-q" },
    .{ "redo", "C-S-z, C-y" },
    .{ "save_file", "C-s" },
    .{ "scroll_view_bottom", "C-l, z z" },
    .{ "scroll_view_center", "C-l, z z" },
    .{ "scroll_view_top", "C-l, z z" },
    .{ "select_all", "C-a" },
    .{ "select_buffer_begin", "C-S-home" },
    .{ "select_buffer_end", "C-S-end" },
    .{ "select_down", "S-down" },
    .{ "select_end", "S-end" },
    .{ "selections_reverse", "C-space" },
    .{ "select_left", "S-left" },
    .{ "select_page_down", "S-pgdn" },
    .{ "select_page_up", "S-pgup" },
    .{ "select_right", "S-right" },
    .{ "select_scroll_down", "C-S-down" },
    .{ "select_scroll_up", "C-S-up" },
    .{ "change_theme", "C-k C-t" },
    .{ "select_up", "S-up" },
    .{ "select_word_left", "C-S-left" },
    .{ "select_word_right", "C-S-right" },
    .{ "smart_insert_line_after", "C-enter, o" },
    .{ "smart_insert_line_before", "S-enter, C-S-enter, O" },
    .{ "smart_insert_line", "enter" },
    .{ "smart_move_begin", "home" },
    .{ "smart_select_begin", "S-home" },
    .{ "system_paste", "C-v" },
    .{ "theme_next", "F10" },
    .{ "theme_prev", "F9" },
    .{ "toggle_comment", "C-/" },
    .{ "toggle_input_mode", "F2" },
    .{ "toggle_inputview", "A-i" },
    .{ "toggle_inspector_view", "F5, C-F5, C-S-i" },
    .{ "toggle_panel", "C-j, F11" },
    .{ "toggle_whitespace", "C-F10" },
    .{ "to_lower", "A-l" },
    .{ "to_upper", "A-u" },
    .{ "undo", "C-z" },
    .{ "undo", "u" },
    .{ "unindent", "S-tab" },
});

const Commands = command.Collection(cmds_);
const cmds_ = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn w(self: *Self, _: Ctx) Result {
        try self.cmd("save_file", .{});
    }

    pub fn q(self: *Self, _: Ctx) Result {
        try self.cmd("quit", .{});
    }

    pub fn @"q!"(self: *Self, _: Ctx) Result {
        try self.cmd("quit_without_saving", .{});
    }

    pub fn wq(self: *Self, _: Ctx) Result {
        try self.cmd("save_file", .{});
        try self.cmd("quit", .{});
    }

    pub fn o(self: *Self, _: Ctx) Result {
        try self.cmd("open_file", .{});
    }

    pub fn @"wq!"(self: *Self, _: Ctx) Result {
        self.cmd("save_file", .{}) catch {};
        try self.cmd("quit_without_saving", .{});
    }
};
