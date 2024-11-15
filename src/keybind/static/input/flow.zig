const std = @import("std");
const tp = @import("thespian");
const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");
const keybind = @import("../keybind.zig");

const Self = @This();
const input_buffer_size = 1024;

allocator: std.mem.Allocator,
input: std.ArrayList(u8),
last_cmd: []const u8 = "",
leader: ?struct { keypress: input.Key, modifiers: input.Mods } = null,

pub fn create(allocator: std.mem.Allocator, _: anytype) !EventHandler {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .input = try std.ArrayList(u8).initCapacity(allocator, input_buffer_size),
    };
    return EventHandler.to_owned(self);
}

pub fn deinit(self: *Self) void {
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
        self.paste_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

pub fn add_keybind() void {}

fn map_event(self: *Self, event: input.Event, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    return switch (event) {
        input.event.press => self.map_press(keypress, egc, modifiers),
        input.event.repeat => self.map_press(keypress, egc, modifiers),
        input.event.release => self.map_release(keypress, egc, modifiers),
        else => {},
    };
}

fn map_press(self: *Self, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    if (self.leader) |_| return self.map_follower(keynormal, modifiers);
    switch (keypress) {
        input.key.left_control, input.key.right_control => return self.cmd("enable_fast_scroll", .{}),
        input.key.left_alt, input.key.right_alt => return self.cmd("enable_jump_mode", .{}),
        else => {},
    }
    return switch (modifiers) {
        input.mod.ctrl => switch (keynormal) {
            'E' => self.cmd("open_recent", .{}),
            'R' => self.cmd("open_recent_project", .{}),
            'J' => self.cmd("toggle_panel", .{}),
            'Z' => self.cmd("undo", .{}),
            'Y' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit", .{}),
            'O' => self.cmd("open_file", .{}),
            'W' => self.cmd("close_file", .{}),
            'S' => self.cmd("save_file", .{}),
            'L' => self.cmd_cycle3("scroll_view_center", "scroll_view_top", "scroll_view_bottom", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'B' => self.cmd("move_to_char", command.fmt(.{false})),
            'T' => self.cmd("move_to_char", command.fmt(.{true})),
            'X' => self.cmd("cut", .{}),
            'C' => self.cmd("copy", .{}),
            'V' => self.cmd("system_paste", .{}),
            'U' => self.cmd("pop_cursor", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'F' => self.cmd("find", .{}),
            'G' => self.cmd("goto", .{}),
            'D' => self.cmd("add_cursor_next_match", .{}),
            'A' => self.cmd("select_all", .{}),
            'I' => self.insert_bytes("\t"),
            '/' => self.cmd("toggle_comment", .{}),
            input.key.enter => self.cmd("smart_insert_line_after", .{}),
            input.key.space => self.cmd("completion", .{}),
            input.key.end => self.cmd("move_buffer_end", .{}),
            input.key.home => self.cmd("move_buffer_begin", .{}),
            input.key.up => self.cmd("move_scroll_up", .{}),
            input.key.down => self.cmd("move_scroll_down", .{}),
            input.key.page_up => self.cmd("move_scroll_page_up", .{}),
            input.key.page_down => self.cmd("move_scroll_page_down", .{}),
            input.key.left => self.cmd("move_word_left", .{}),
            input.key.right => self.cmd("move_word_right", .{}),
            input.key.backspace => self.cmd("delete_word_left", .{}),
            input.key.delete => self.cmd("delete_word_right", .{}),
            input.key.f5 => self.cmd("toggle_inspector_view", .{}),
            input.key.f10 => self.cmd("toggle_whitespace_mode", .{}), // aka F34
            input.key.f12 => self.cmd("goto_implementation", .{}),
            else => {},
        },
        input.mod.ctrl | input.mod.shift => switch (keynormal) {
            'S' => self.cmd("save_as", .{}),
            'P' => self.cmd("open_command_palette", .{}),
            'D' => self.cmd("dupe_down", .{}),
            'Z' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'W' => self.cmd("close_file_without_saving", .{}),
            'F' => self.cmd("find_in_files", .{}),
            'L' => self.cmd_async("add_cursor_all_matches"),
            'I' => self.cmd_async("toggle_inspector_view"),
            'M' => self.cmd("show_diagnostics", .{}),
            input.key.enter => self.cmd("smart_insert_line_before", .{}),
            input.key.end => self.cmd("select_buffer_end", .{}),
            input.key.home => self.cmd("select_buffer_begin", .{}),
            input.key.up => self.cmd("select_scroll_up", .{}),
            input.key.down => self.cmd("select_scroll_down", .{}),
            input.key.left => self.cmd("select_word_left", .{}),
            input.key.right => self.cmd("select_word_right", .{}),
            input.key.space => self.cmd("selections_reverse", .{}),
            else => {},
        },
        input.mod.alt => switch (keynormal) {
            'O' => self.cmd("open_previous_file", .{}),
            'J' => self.cmd("join_next_line", .{}),
            'N' => self.cmd("goto_next_file_or_diagnostic", .{}),
            'P' => self.cmd("goto_prev_file_or_diagnostic", .{}),
            'U' => self.cmd("to_upper", .{}),
            'L' => self.cmd("to_lower", .{}),
            'C' => self.cmd("switch_case", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            'B' => self.cmd("move_word_left", .{}),
            'F' => self.cmd("move_word_right", .{}),
            'S' => self.cmd("filter", command.fmt(.{"sort"})),
            'V' => self.cmd("paste", .{}),
            'X' => self.cmd("open_command_palette", .{}),
            input.key.left => self.cmd("jump_back", .{}),
            input.key.right => self.cmd("jump_forward", .{}),
            input.key.up => self.cmd("pull_up", .{}),
            input.key.down => self.cmd("pull_down", .{}),
            input.key.enter => self.cmd("insert_line", .{}),
            input.key.f10 => self.cmd("gutter_mode_next", .{}), // aka F58
            input.key.f12 => self.cmd("goto_declaration", .{}),
            else => {},
        },
        input.mod.alt | input.mod.shift => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            'D' => self.cmd("dupe_up", .{}),
            // 'B' => self.cmd("select_word_left", .{}),
            // 'F' => self.cmd("select_word_right", .{}),
            'F' => self.cmd("format", .{}),
            'S' => self.cmd("filter", command.fmt(.{ "sort", "-u" })),
            'V' => self.cmd("paste", .{}),
            'I' => self.cmd("add_cursors_to_line_ends", .{}),
            input.key.left => self.cmd("shrink_selection", .{}),
            input.key.right => self.cmd("expand_selection", .{}),
            input.key.home => self.cmd("move_scroll_left", .{}),
            input.key.end => self.cmd("move_scroll_right", .{}),
            input.key.up => self.cmd("add_cursor_up", .{}),
            input.key.down => self.cmd("add_cursor_down", .{}),
            input.key.f12 => self.cmd("goto_type_definition", .{}),
            else => {},
        },
        input.mod.shift => switch (keypress) {
            input.key.f3 => self.cmd("goto_prev_match", .{}),
            input.key.f10 => self.cmd("toggle_syntax_highlighting", .{}),
            input.key.f12 => self.cmd("references", .{}),
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
            else => if (!input.is_non_input_key(keypress))
                self.insert_code_point(egc)
            else {},
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
            input.key.escape => self.cmd("cancel", .{}),
            input.key.enter => self.cmd("smart_insert_line", .{}),
            input.key.delete => self.cmd("delete_forward", .{}),
            input.key.backspace => self.cmd("delete_backward", .{}),
            input.key.left => self.cmd("move_left", .{}),
            input.key.right => self.cmd("move_right", .{}),
            input.key.up => self.cmd("move_up", .{}),
            input.key.down => self.cmd("move_down", .{}),
            input.key.home => self.cmd("smart_move_begin", .{}),
            input.key.end => self.cmd("move_end", .{}),
            input.key.page_up => self.cmd("move_page_up", .{}),
            input.key.page_down => self.cmd("move_page_down", .{}),
            input.key.tab => self.cmd("indent", .{}),
            else => if (!input.is_non_input_key(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn map_follower(self: *Self, keypress: input.Key, modifiers: input.Mods) !void {
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
        else => {},
    };
}

fn map_release(self: *Self, keypress: input.Key, _: u32, _: u32) !void {
    return switch (keypress) {
        input.key.left_control, input.key.right_control => self.cmd("disable_fast_scroll", .{}),
        input.key.left_alt, input.key.right_alt => self.cmd("disable_jump_mode", .{}),
        else => {},
    };
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

fn paste_bytes(self: *Self, bytes: []const u8) !void {
    try self.flush_input();
    try command.executeName("paste", command.fmt(.{bytes}));
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
    try self.flush_input();
    self.last_cmd = name_;
    try command.executeName(name_, ctx);
}

fn cmd_cycle3(self: *Self, name1: []const u8, name2: []const u8, name3: []const u8, ctx: command.Context) tp.result {
    return if (std.mem.eql(u8, self.last_cmd, name2))
        self.cmd(name3, ctx)
    else if (std.mem.eql(u8, self.last_cmd, name1))
        self.cmd(name2, ctx)
    else
        self.cmd(name1, ctx);
}

fn cmd_async(self: *Self, name_: []const u8) tp.result {
    self.last_cmd = name_;
    return tp.self_pid().send(.{ "cmd", name_ });
}

pub const hints = keybind.KeybindHints.initComptime(.{
    .{ "add_cursor_all_matches", "C-S-l" },
    .{ "add_cursor_down", "S-A-down" },
    .{ "add_cursor_next_match", "C-d" },
    .{ "add_cursors_to_line_ends", "S-A-i" },
    .{ "add_cursor_up", "S-A-up" },
    .{ "cancel", "esc" },
    .{ "change_theme", "C-k C-t" },
    .{ "close_file", "C-w" },
    .{ "close_file_without_saving", "C-S-w" },
    .{ "copy", "C-c" },
    .{ "cut", "C-x" },
    .{ "delete_backward", "backspace" },
    .{ "delete_forward", "del" },
    .{ "delete_to_begin", "C-k C-u" },
    .{ "delete_to_end", "C-k C-k" },
    .{ "delete_word_left", "C-backspace" },
    .{ "delete_word_right", "C-del" },
    .{ "dump_current_line", "F7" },
    .{ "dump_current_line_tree", "F6" },
    .{ "dupe_down", "C-S-d" },
    .{ "dupe_up", "S-A-d" },
    .{ "enable_fast_scroll", "hold Ctrl" },
    .{ "enable_jump_mode", "hold Alt" },
    .{ "expand_selection", "S-A-right" },
    .{ "filter", "A-s" }, // self.cmd("filter", command.fmt(.{"sort"})),
    // .{ "filter", "S-A-s" }, // self.cmd("filter", command.fmt(.{ "sort", "-u" })),
    .{ "find", "C-f" },
    .{ "find_in_files", "C-S-f" },
    .{ "format", "S-A-f" },
    .{ "goto", "C-g" },
    .{ "goto_declaration", "A-F12" },
    .{ "goto_definition", "F12" },
    .{ "goto_implementation", "C-F12" },
    .{ "goto_next_file_or_diagnostic", "A-n" },
    .{ "goto_next_match", "C-n, F3" },
    .{ "goto_prev_file_or_diagnostic", "A-p" },
    .{ "goto_prev_match", "C-p, S-F3" },
    .{ "goto_type_definition", "A-S-F12" },
    .{ "gutter_mode_next", "A-F10" },
    .{ "indent", "tab" },
    .{ "insert_line", "A-enter" },
    .{ "join_next_line", "A-j" },
    .{ "jump_back", "A-left" },
    .{ "jump_forward", "A-right" },
    .{ "move_buffer_begin", "C-home" },
    .{ "move_buffer_end", "C-end" },
    .{ "move_cursor_next_match", "C-k C-d" },
    .{ "move_down", "down" },
    .{ "move_end", "end" },
    .{ "move_left", "left" },
    .{ "move_page_down", "pgdn" },
    .{ "move_page_up", "pgup" },
    .{ "move_right", "right" },
    .{ "move_scroll_down", "C-down" },
    .{ "move_scroll_left", "S-A-home" },
    .{ "move_scroll_page_down", "C-pgdn" },
    .{ "move_scroll_page_up", "C-pgup" },
    .{ "move_scroll_right", "S-A-end" },
    .{ "move_scroll_up", "C-up" },
    .{ "move_to_char", "C-b, C-t" }, // true/false
    .{ "move_up", "up" },
    .{ "move_word_left", "C-left, A-b" },
    .{ "move_word_right", "C-right, A-f" },
    .{ "open_command_palette", "C-S-p, S-A-p, A-x" },
    .{ "open_file", "C-o" },
    .{ "open_previous_file", "A-o" },
    .{ "open_recent", "C-e" },
    .{ "open_recent_project", "C-r" },
    .{ "paste", "A-v" },
    .{ "pop_cursor", "C-u" },
    .{ "pull_down", "A-down" },
    .{ "pull_up", "A-up" },
    .{ "quit", "C-q" },
    .{ "quit_without_saving", "C-S-q" },
    .{ "redo", "C-S-z, C-y" },
    .{ "references", "S-F12" },
    .{ "save_as", "C-S-s" },
    .{ "save_file", "C-s" },
    .{ "scroll_view_bottom", "C-l" },
    .{ "scroll_view_center", "C-l" },
    .{ "scroll_view_top", "C-l" },
    .{ "select_all", "C-a" },
    .{ "select_buffer_begin", "C-S-home" },
    .{ "select_buffer_end", "C-S-end" },
    .{ "select_down", "S-down" },
    .{ "select_end", "S-end" },
    .{ "selections_reverse", "C-S-space" },
    .{ "select_left", "S-left" },
    .{ "select_page_down", "S-pgdn" },
    .{ "select_page_up", "S-pgup" },
    .{ "select_right", "S-right" },
    .{ "select_scroll_down", "C-S-down" },
    .{ "select_scroll_up", "C-S-up" },
    .{ "select_up", "S-up" },
    .{ "select_word_left", "C-S-left" },
    .{ "select_word_right", "C-S-right" },
    .{ "show_diagnostics", "C-S-m" },
    .{ "shrink_selection", "S-A-left" },
    .{ "smart_insert_line_after", "C-enter" },
    .{ "smart_insert_line_before", "S-enter, C-S-enter" },
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
    .{ "unindent", "S-tab" },
});
