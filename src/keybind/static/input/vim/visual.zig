const std = @import("std");
const tp = @import("thespian");
const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");
const keybind = @import("../../keybind.zig");

const Self = @This();
const input_buffer_size = 1024;

allocator: std.mem.Allocator,
input: std.ArrayList(u8),
last_cmd: []const u8 = "",
leader: ?struct { keypress: input.Key, modifiers: input.Mods } = null,
count: usize = 0,
commands: Commands = undefined,

pub fn create(allocator: std.mem.Allocator, _: anytype) !EventHandler {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .input = try std.ArrayList(u8).initCapacity(allocator, input_buffer_size),
    };
    try self.commands.init(self);
    return EventHandler.to_owned(self);
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.input.deinit();
    self.allocator.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var event: input.Event = undefined;
    var keypress: input.Key = undefined;
    var egc: input.Key = undefined;
    var modifiers: input.Mods = undefined;
    var text: []const u8 = undefined;

    if (try m.match(.{ "I", tp.extract(&event), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        self.map_event(event, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
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

fn map_event(self: *Self, event: input.Event, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    return switch (event) {
        input.event.press => self.map_press(keypress, egc, modifiers),
        input.event.repeat => self.map_press(keypress, egc, modifiers),
        input.event.release => self.map_release(keypress),
        else => {},
    };
}

fn map_press(self: *Self, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    if (self.count > 0 and modifiers == 0 and '0' <= keypress and keypress <= '9') return self.add_count(keypress - '0');
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    if (self.leader) |_| return self.mapFollower(keynormal, egc, modifiers);
    switch (keypress) {
        input.key.left_control, input.key.right_control => return self.cmd("enable_fast_scroll", .{}),
        input.key.left_alt, input.key.right_alt => return self.cmd("enable_jump_mode", .{}),
        else => {},
    }
    return switch (modifiers) {
        input.mod.ctrl => switch (keynormal) {
            'E' => self.cmd("open_recent", .{}),
            'U' => self.cmd("move_scroll_page_up", .{}),
            'D' => self.cmd("move_scroll_page_down", .{}),
            'R' => self.cmd("redo", .{}),
            'O' => self.cmd("jump_back", .{}),
            'I' => self.cmd("jump_forward", .{}),

            'J' => self.cmd("toggle_panel", .{}),
            'Z' => self.cmd("undo", .{}),
            'Y' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            'S' => self.cmd("save_file", .{}),
            'L' => self.cmd("scroll_view_center_cycle", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'B' => self.cmd("move_to_char", command.fmt(.{false})),
            'T' => self.cmd("move_to_char", command.fmt(.{true})),
            'X' => self.cmd("cut", .{}),
            'C' => self.cmd("copy", .{}),
            'V' => self.cmd("system_paste", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'F' => self.cmd("find", .{}),
            'G' => self.cmd("goto", .{}),
            'A' => self.cmd("select_all", .{}),
            '/' => self.cmd("toggle_comment", .{}),
            input.key.enter => self.cmd("smart_insert_line_after", .{}),
            input.key.space => self.cmd("selections_reverse", .{}),
            input.key.end => self.cmd("select_buffer_end", .{}),
            input.key.home => self.cmd("select_buffer_begin", .{}),
            input.key.up => self.cmd("select_scroll_up", .{}),
            input.key.down => self.cmd("select_scroll_down", .{}),
            input.key.page_up => self.cmd("select_scroll_page_up", .{}),
            input.key.page_down => self.cmd("select_scroll_page_down", .{}),
            input.key.left => self.cmd("select_word_left", .{}),
            input.key.right => self.cmd("select_word_right", .{}),
            input.key.backspace => self.cmd("delete_word_left", .{}),
            input.key.delete => self.cmd("delete_word_right", .{}),
            input.key.f5 => self.cmd("toggle_inspector_view", .{}),
            input.key.f10 => self.cmd("toggle_whitespace_mode", .{}), // aka F34
            else => {},
        },
        input.mod.ctrl | input.mod.shift => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            'D' => self.cmd("dupe_down", .{}),
            'Z' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'W' => self.cmd("close_file_without_saving", .{}),
            'F' => self.cmd("find_in_files", .{}),
            'L' => self.cmd_async("add_cursor_all_matches"),
            'I' => self.cmd_async("toggle_inspector_view"),
            '6' => self.cmd("open_previous_file", .{}),
            input.key.enter => self.cmd("smart_insert_line_before", .{}),
            input.key.end => self.cmd("select_buffer_end", .{}),
            input.key.home => self.cmd("select_buffer_begin", .{}),
            input.key.up => self.cmd("select_scroll_up", .{}),
            input.key.down => self.cmd("select_scroll_down", .{}),
            input.key.left => self.cmd("select_word_left", .{}),
            input.key.right => self.cmd("select_word_right", .{}),
            else => {},
        },
        input.mod.alt => switch (keynormal) {
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
            input.key.left => self.cmd("jump_back", .{}),
            input.key.right => self.cmd("jump_forward", .{}),
            input.key.up => self.cmd("pull_up", .{}),
            input.key.down => self.cmd("pull_down", .{}),
            input.key.enter => self.cmd("insert_line", .{}),
            input.key.f10 => self.cmd("gutter_mode_next", .{}), // aka F58
            else => {},
        },
        input.mod.alt | input.mod.shift => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            'D' => self.cmd("dupe_up", .{}),
            'F' => self.cmd("filter", command.fmt(.{ "zig", "fmt", "--stdin" })),
            'S' => self.cmd("filter", command.fmt(.{ "sort", "-u" })),
            'V' => self.cmd("paste", .{}),
            'I' => self.cmd("add_cursors_to_line_ends", .{}),
            input.key.left => self.cmd("move_scroll_left", .{}),
            input.key.right => self.cmd("move_scroll_right", .{}),
            else => {},
        },
        input.mod.shift => switch (keypress) {
            input.key.f3 => self.cmd("goto_prev_match", .{}),
            input.key.f10 => self.cmd("toggle_syntax_highlighting", .{}),
            input.key.left => self.cmd("select_left", .{}),
            input.key.right => self.cmd("select_right", .{}),
            input.key.up => self.cmd("select_up", .{}),
            input.key.down => self.cmd("select_down", .{}),
            input.key.home => self.cmd("smart_select_begin", .{}),
            input.key.end => self.cmd("select_end", .{}),
            input.key.page_up => self.cmd("select_page_up", .{}),
            input.key.page_down => self.cmd("select_page_down", .{}),
            input.key.enter => self.cmd("smart_insert_line_before", .{}),
            input.key.backspace => self.cmd("delete_backward", .{}),
            input.key.tab => self.cmd("unindent", .{}),

            ';' => self.cmd("open_command_palette", .{}),
            'n' => self.cmd("goto_prev_match", .{}),
            'a' => self.seq(.{ "move_end", "enter_mode" }, command.fmt(.{"vim/insert"})),
            '4' => self.cmd("select_end", .{}),
            'g' => if (self.count == 0)
                self.cmd("move_buffer_end", .{})
            else {
                const count = self.count;
                try self.cmd("move_buffer_begin", .{});
                self.count = count - 1;
                if (self.count > 0)
                    try self.cmd_count("move_down", .{});
            },

            'o' => self.seq(.{ "smart_insert_line_before", "enter_mode" }, command.fmt(.{"vim/insert"})),

            '`' => self.cmd("switch_case", .{}),
            else => {},
        },
        0 => switch (keypress) {
            input.key.f2 => self.cmd("toggle_input_mode", .{}),
            input.key.f3 => self.cmd("goto_next_match", .{}),
            input.key.f15 => self.cmd("goto_prev_match", .{}), // S-F3
            input.key.f5 => self.cmd("toggle_inspector_view", .{}), // C-F5
            input.key.f6 => self.cmd("dump_current_line_tree", .{}),
            input.key.f7 => self.cmd("dump_current_line", .{}),
            input.key.f9 => self.cmd("theme_prev", .{}),
            input.key.f10 => self.cmd("theme_next", .{}),
            input.key.f11 => self.cmd("toggle_panel", .{}),
            input.key.f12 => self.cmd("goto_definition", .{}),
            input.key.f34 => self.cmd("toggle_whitespace_mode", .{}), // C-F10
            input.key.escape => self.seq(.{ "cancel", "enter_mode" }, command.fmt(.{"vim/normal"})),
            input.key.enter => self.cmd("smart_insert_line", .{}),
            input.key.delete => self.cmd("delete_forward", .{}),
            input.key.backspace => self.cmd("delete_backward", .{}),

            ':' => self.cmd("open_command_palette", .{}),
            'i' => self.cmd("enter_mode", command.fmt(.{"vim/insert"})),
            'a' => self.seq(.{ "move_right", "enter_mode" }, command.fmt(.{"vim/insert"})),
            'v' => self.cmd("enter_mode", command.fmt(.{"vim/visual"})),

            '/' => self.cmd("find", .{}),
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

            input.key.left => self.cmd("select_left", .{}),
            input.key.right => self.cmd("select_right", .{}),
            input.key.up => self.cmd("select_up", .{}),
            input.key.down => self.cmd("select_down", .{}),
            input.key.home => self.cmd("smart_select_begin", .{}),
            input.key.end => self.cmd("select_end", .{}),
            input.key.page_up => self.cmd("select_page_up", .{}),
            input.key.page_down => self.cmd("select_page_down", .{}),
            input.key.tab => self.cmd("indent", .{}),
            else => {},
        },
        else => {},
    };
}

fn mapFollower(self: *Self, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    if (keypress == input.key.left_control or
        keypress == input.key.right_control or
        keypress == input.key.left_alt or
        keypress == input.key.right_alt or
        keypress == input.key.left_shift or
        keypress == input.key.right_shift or
        keypress == input.key.left_super or
        keypress == input.key.right_super) return;

    defer self.leader = null;
    const ldr = if (self.leader) |leader| leader else return;
    return switch (ldr.modifiers) {
        input.mod.ctrl => switch (ldr.keypress) {
            'K' => switch (modifiers) {
                input.mod.ctrl => switch (keypress) {
                    'U' => self.cmd("delete_to_begin", .{}),
                    'K' => self.cmd("delete_to_end", .{}),
                    'D' => self.cmd("move_cursor_next_match", .{}),
                    'T' => self.cmd("change_theme", .{}),
                    'I' => self.cmd("hover", .{}),
                    else => {},
                },
                else => {},
            },
            else => {},
        },
        0 => switch (ldr.keypress) {
            'D', 'C' => {
                try switch (modifiers) {
                    input.mod.shift => switch (keypress) {
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
                input.mod.shift, 0 => if (!input.is_non_input_key(keypress)) {
                    var count = self.count;
                    try self.cmd_count("delete_forward", .{});
                    while (count > 0) : (count -= 1)
                        try self.insert_code_point(egc);
                },
                else => {},
            },
            'Z' => switch (modifiers) {
                0 => switch (keypress) {
                    'Z' => self.cmd("scroll_view_center_cycle", .{}),
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

fn map_release(self: *Self, keypress: input.Key) !void {
    return switch (keypress) {
        input.key.left_control, input.key.right_control => self.cmd("disable_fast_scroll", .{}),
        input.key.left_alt, input.key.right_alt => self.cmd("disable_jump_mode", .{}),
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
    const bytes = try input.ucs32_to_utf8(&[_]u32{c}, &buf);
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

pub const hints = keybind.KeybindHints.initComptime(.{
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
    .{ "open_previous_file", "C-^" },
    .{ "open_file", "C-o" },
    .{ "filter", "A-s" }, // self.cmd("filter", command.fmt(.{"sort"})),
    // .{ "filter", "S-A-s" }, // self.cmd("filter", command.fmt(.{ "sort", "-u" })),
    .{ "format", "S-A-f" },
    .{ "goto_definition", "F12" },
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
    .{ "scroll_view_center_cycle", "C-l, z z" },
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
    .{ "toggle_syntax_highlighting", "S-F10" },
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
    pub const q_meta = .{ .description = "q (quit)" };

    pub fn @"q!"(self: *Self, _: Ctx) Result {
        try self.cmd("quit_without_saving", .{});
    }
    pub const @"q!_meta" = .{ .description = "q! (quit without saving)" };

    pub fn wq(self: *Self, _: Ctx) Result {
        try self.cmd("save_file", .{});
        try self.cmd("quit", .{});
    }
    pub const wq_meta = .{ .description = "wq (write file and quit)" };

    pub fn @"wq!"(self: *Self, _: Ctx) Result {
        self.cmd("save_file", .{}) catch {};
        try self.cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta" = .{ .description = "wq! (write file and quit without saving)" };
};
