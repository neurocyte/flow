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
const eql = @import("std").mem.eql;

const Self = @This();
const input_buffer_size = 1024;

allocator: Allocator,
input: ArrayList(u8),
last_cmd: []const u8 = "",
leader: ?struct { keypress: u32, modifiers: u32 } = null,
count: usize = 0,
commands: Commands = undefined,

pub fn create(allocator: Allocator) !tui.Mode {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .input = try ArrayList(u8).initCapacity(allocator, input_buffer_size),
    };
    try self.commands.init(self);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "SEL",
        .description = "helix",
        .line_numbers = if (tui.current().config.vim_visual_gutter_line_numbers_relative) .relative else .absolute,
        .keybind_hints = &hints,
        .cursor_shape = .block,
    };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.input.deinit();
    self.allocator.destroy(self);
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
            'B' => self.cmd("move_scroll_page_up", .{}),
            'F' => self.cmd("move_scroll_page_down", .{}),
            'U' => self.cmd("page_cursor_half_up", .{}),
            'D' => self.cmd("page_cursor_half_down", .{}),

            'C' => self.cmd("toggle_comment", .{}),

            'I' => self.cmd("jump_forward", .{}),
            'O' => self.cmd("jump_back", .{}),
            'S' => self.cmd("save_selection", .{}),
            'W' => self.leader = .{ .keypress = keynormal, .modifiers = 0 },

            'A' => self.cmd("increment", .{}),
            'X' => self.cmd("decrement", .{}),
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            '.' => self.cmd("repeat_last_motion", .{}),

            '`' => self.cmd("switch_to_uppercase", .{}),

            'D' => self.cmd("delete_backward", .{}),
            'C' => {
                try self.cmd("delete_backward", .{});
                try self.cmd("enter_mode", command.fmt(.{"helix/insert"}));
            },

            'S' => self.cmd("split_selection_on_newline", .{}),
            '-' => self.cmd("merge_selections", .{}),
            '_' => self.cmd("merge_consecutive_selections", .{}),

            ';' => self.cmd("flip_selections", .{}),
            'O', key.UP => self.cmd("expand_selection", .{}),
            'I', key.DOWN => self.cmd("shrink_selection", .{}),
            'P', key.LEFT => self.cmd("select_prev_sibling", .{}),
            'N', key.RIGHT => self.cmd("select_next_sibling", .{}),

            'E' => self.cmd("extend_parent_node_end", .{}),
            'B' => self.cmd("extend_parent_node_start", .{}),
            'A' => self.cmd("select_all_siblings", .{}),

            'X' => self.cmd("shrink_to_line_bounds", .{}),

            'U' => self.cmd("undo", .{}),

            ',' => self.cmd("remove_primary_selection", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),

            'C' => self.cmd("copy_selection_on_next_line", .{}),

            'I', key.DOWN => self.cmd("select_all_children", .{}),

            'U' => self.cmd("redo", .{}),

            'j' => self.cmd("join_selections_space", .{}),

            '(' => self.cmd("rotate_selection_contents_backward", .{}),
            ')' => self.cmd("rotate_selection_contents_forward", .{}),

            '\\' => self.cmd("shell_pipe_to", .{}),
            '1' => self.cmd("shell_append_output", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            '`' => self.cmd("switch_case", .{}),

            't' => self.cmd("extend_till_prev_char", .{}),
            'f' => self.cmd("extend_prev_char", .{}),
            'r' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },

            'w' => self.cmd_count("extend_next_long_word_start", .{}),
            'b' => self.cmd_count("extend_prev_long_word_start", .{}),
            'e' => self.cmd_count("extend_next_long_word_end", .{}),

            'g' => if (self.count == 0)
                self.cmd("move_buffer_end", .{})
            else {
                const count = self.count;
                try self.cmd("move_buffer_begin", .{});
                self.count = count - 1;
                if (self.count > 0)
                    try self.cmd_count("move_down", .{});
            },

            'i' => self.seq(.{ "smart_move_begin", "enter_mode" }, command.fmt(.{"helix/insert"})),
            'a' => self.seq(.{ "move_end", "enter_mode" }, command.fmt(.{"helix/insert"})),

            'o' => self.seq(.{ "smart_insert_line_before", "enter_mode" }, command.fmt(.{"helix/insert"})),

            'c' => self.cmd("copy_selection_on_next_line", .{}),

            's' => self.cmd("split_selection", .{}),

            'x' => self.cmd_count("extend_to_line_bounds", .{}),

            '/' => self.cmd("rfind", .{}),

            'n' => self.cmd("extend_search_next", .{}),
            '8' => self.cmd("extend_search_prev", .{}),

            'u' => self.cmd("redo", .{}),

            'p' => self.cmd("paste", .{}),

            'q' => self.cmd("replay_macro", .{}),

            '.' => self.cmd("indent", .{}),
            ',' => self.cmd("unindent", .{}),

            'j' => self.cmd("join_selections", .{}),

            ';' => self.cmd("open_command_palette", .{}),

            '7' => self.cmd("align_selections", .{}),
            '-' => self.cmd("trim_selections", .{}),

            '9' => self.cmd("rotate_selections_backward", .{}),
            '0' => self.cmd("rotate_selections_forward", .{}),

            '\'' => self.cmd("select_register", .{}),
            '\\' => self.cmd("shell_pipe", .{}),
            '1' => self.cmd("shell_insert_output", .{}),
            '4' => self.cmd("shell_keep_pipe", .{}),
            else => {},
        },
        0 => switch (keypress) {
            key.F02 => self.cmd("toggle_input_mode", .{}),
            'h', key.LEFT => self.cmd_count("select_left", .{}),
            'j', key.DOWN => self.cmd_count("select_down", .{}),
            'k', key.UP => self.cmd_count("select_up", .{}),
            'l', key.RIGHT => self.cmd_count("select_right", .{}),

            't' => self.cmd("extend_till_char", .{}),
            'f' => self.cmd("extend_next_char", .{}),
            'r' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },

            '`' => self.cmd("switch_to_lowercase", .{}),

            key.HOME => self.cmd("extend_to_line_start", .{}),
            key.END => self.cmd("extend_to_line_end", .{}),

            'w' => self.cmd_count("extend_next_word_start", .{}),
            'b' => self.cmd_count("extend_pre_word_start", .{}),
            'e' => self.cmd_count("extend_next_word_end", .{}),

            'v' => self.cmd("enter_mode", command.fmt(.{"helix/normal"})),
            'g' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },

            'i' => self.cmd("enter_mode", command.fmt(.{"helix/insert"})),
            'a' => self.seq(.{ "move_right", "enter_mode" }, command.fmt(.{"helix/insert"})), // TODO: keep selection
            'o' => self.seq(.{ "smart_insert_line_after", "enter_mode" }, command.fmt(.{"helix/insert"})),

            'd' => self.cmd("cut", .{}),
            'c' => {
                try self.cmd("cut", .{});
                try self.cmd("enter_mode", command.fmt(.{"helix/insert"}));
            },

            's' => self.cmd("select_regex", .{}),
            ';' => self.cmd("collapse_selections", .{}),

            'x' => self.cmd_count("extend_line_below", .{}),

            'm' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            '[' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            ']' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },

            '/' => self.cmd("find", .{}),
            'n' => self.cmd("goto_next_match", .{}),
            'u' => self.cmd("undo", .{}),

            'y' => self.cmd("copy", .{}),
            'p' => self.cmd("paste_after", .{}),

            'q' => self.cmd("record_macro", .{}),

            '=' => self.cmd("format_selections", .{}),

            ',' => self.cmd("keep_primary_selection", .{}),

            key.ESC => self.cmd("enter_mode", command.fmt(.{"helix/normal"})),

            key.PGUP => self.cmd("move_scroll_page_up", .{}),
            key.PGDOWN => self.cmd("move_scroll_page_down", .{}),

            ' ' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'z' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },

            '1' => self.add_count(1),
            '2' => self.add_count(2),
            '3' => self.add_count(3),
            '4' => self.add_count(4),
            '5' => self.add_count(5),
            '6' => self.add_count(6),
            '7' => self.add_count(7),
            '8' => self.add_count(8),
            '9' => self.add_count(9),
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
            'G' => switch (modifiers) {
                0 => switch (keypress) {
                    'G' => self.cmd("move_buffer_begin", .{}),
                    'E' => self.cmd("move_buffer_end", .{}),
                    'F' => self.cmd("goto_file", .{}),
                    'H' => self.cmd("move_begin", .{}),
                    'L' => self.cmd("move_end", .{}),
                    'S' => self.cmd("smart_move_begin", .{}),
                    'D' => self.cmd("goto_definition", .{}),
                    'Y' => self.cmd("goto_type_definition", .{}),
                    'R' => self.cmd("goto_reference", .{}),
                    'I' => self.cmd("goto_implementation", .{}),
                    'T' => self.cmd("goto_window_top", .{}),
                    'C' => self.cmd("goto_window_center", .{}),
                    'B' => self.cmd("goto_window_bottom", .{}),
                    'A' => self.cmd("goto_last_accessed_file", .{}),
                    'M' => self.cmd("goto_last_modified_file", .{}),
                    'N' => self.cmd("goto_next_buffer", .{}),
                    'P' => self.cmd("goto_previous_buffer", .{}),
                    'K' => self.cmd("goto_previous_buffer", .{}),
                    '.' => self.cmd("goto_last_modification", .{}),
                    'W' => self.cmd("goto_word", .{}),
                    else => {},
                },
                mod.SHIFT => switch (keypress) {
                    'D' => self.cmd("goto_declaration", .{}),
                    else => {},
                },
                else => {},
            },
            'M' => {
                try switch (modifiers) {
                    0 => switch (keypress) {
                        'M' => self.cmd("match_brackets", .{}),
                        'S' => self.cmd("surround_add", .{}),
                        'R' => self.cmd("surround_replace", .{}),
                        'D' => self.cmd("surround_delete", .{}),
                        'A' => self.cmd("select_textobject_around", .{}),
                        'I' => self.cmd("select_textobject_inner", .{}),
                        else => {},
                    },
                    else => {},
                };
            },
            '[' => {
                try switch (modifiers) {
                    mod.SHIFT => switch (keypress) {
                        'D' => self.cmd("goto_first_diag", .{}),
                        'G' => self.cmd("goto_first_change", .{}),
                        'T' => self.cmd("goto_prev_test", .{}),
                        else => {},
                    },
                    0 => switch (keypress) {
                        'D' => self.cmd("goto_prev_diagnostic", .{}),
                        'G' => self.cmd("goto_prev_change", .{}),
                        'F' => self.cmd("goto_prev_function", .{}),
                        'T' => self.cmd("goto_prev_class", .{}),
                        'A' => self.cmd("goto_prev_parameter", .{}),
                        'C' => self.cmd("goto_prev_comment", .{}),
                        'E' => self.cmd("goto_prev_entry", .{}),
                        'P' => self.cmd("goto_prev_paragraph", .{}),
                        ' ' => self.cmd("add_newline_above", .{}),
                        else => {},
                    },
                    else => {},
                };
            },
            ']' => {
                try switch (modifiers) {
                    mod.SHIFT => switch (keypress) {
                        'D' => self.cmd("goto_last_diag", .{}),
                        'G' => self.cmd("goto_last_change", .{}),
                        'T' => self.cmd("goto_next_test", .{}),
                        else => {},
                    },
                    0 => switch (keypress) {
                        'D' => self.cmd("goto_next_diagnostic", .{}),
                        'G' => self.cmd("goto_next_change", .{}),
                        'F' => self.cmd("goto_next_function", .{}),
                        'T' => self.cmd("goto_next_class", .{}),
                        'A' => self.cmd("goto_next_parameter", .{}),
                        'C' => self.cmd("goto_next_comment", .{}),
                        'E' => self.cmd("goto_next_entry", .{}),
                        'P' => self.cmd("goto_next_paragraph", .{}),
                        ' ' => self.cmd("add_newline_below", .{}),
                        else => {},
                    },
                    else => {},
                };
            },
            'W' => switch (modifiers) {
                // way too much stuff if someone wants they can implement it
                mod.SHIFT => switch (keypress) {
                    else => {},
                },
                0 => switch (keypress) {
                    else => {},
                },
                else => {},
            },
            ' ' => switch (modifiers) {
                mod.SHIFT => switch (keypress) {
                    'F' => self.cmd("file_picker_in_current_directory", .{}),
                    'S' => self.cmd("workspace_symbol_picker", .{}),
                    'D' => self.cmd("workspace_diagnostics_picker", .{}),
                    'P' => self.cmd("system_paste", .{}),
                    'R' => self.cmd("replace_selections_with_clipboard", .{}),
                    '/' => self.cmd("open_command_palette", .{}),
                    else => {},
                },
                0 => switch (keypress) {
                    'F' => self.cmd("file_picker", .{}),
                    'B' => self.cmd("buffer_picker", .{}),
                    'J' => self.cmd("jumplist_picker", .{}),
                    'S' => self.cmd("symbol_picker", .{}),
                    'D' => self.cmd("diagnostics_picker", .{}),
                    'A' => self.cmd("code_action", .{}),
                    'W' => self.leader = .{ .keypress = keypress, .modifiers = modifiers },
                    '\'' => self.cmd("last_picker", .{}),
                    'Y' => self.cmd("copy", .{}),
                    'P' => self.cmd("system_paste_after", .{}),
                    '/' => self.cmd("find_in_file", .{}),
                    'K' => self.cmd("hover", .{}),
                    'R' => self.cmd("rename_symbol", .{}),
                    'H' => self.cmd("select_references_to_symbol_under_cursor", .{}),
                    'C' => self.cmd("toggle_comment", .{}),
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
    .{ "open_command_palette", "Space ?, C-S-p, :, S-;, S-A-p" },
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
    .{ "toggle_whitespace_mode", "C-F10" },
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
    pub const w_meta = .{ .description = "w (write file)" };

    pub fn q(self: *Self, _: Ctx) Result {
        try self.cmd("quit", .{});
    }
    pub const q_meta = .{ .description = "w (quit)" };

    pub fn @"q!"(self: *Self, _: Ctx) Result {
        try self.cmd("quit_without_saving", .{});
    }
    pub const @"q!_meta" = .{ .description = "q! (quit without saving)" };

    pub fn wq(self: *Self, _: Ctx) Result {
        try self.cmd("save_file", .{});
        try self.cmd("quit", .{});
    }
    pub const wq_meta = .{ .description = "wq (write file and quit)" };

    pub fn o(self: *Self, _: Ctx) Result {
        try self.cmd("open_file", .{});
    }
    pub const o_meta = .{ .description = "o (open file)" };

    pub fn @"wq!"(self: *Self, _: Ctx) Result {
        self.cmd("save_file", .{}) catch {};
        try self.cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta" = .{ .description = "wq! (write file and quit without saving)" };
};
