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
        self.mapEvent(event, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
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

fn mapEvent(self: *Self, event: input.Event, keypress: input.Key, egc: input.Key, modifiers: input.Mods) !void {
    return switch (event) {
        input.event.press => self.map_press(keypress, egc, modifiers),
        input.event.repeat => self.map_press(keypress, egc, modifiers),
        input.event.release => self.map_release(keypress),
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
            'U' => self.cmd("move_scroll_page_up", .{}),
            'D' => self.cmd("move_scroll_page_down", .{}),
            'J' => self.cmd("toggle_panel", .{}),
            'Z' => self.cmd("undo", .{}),
            'Y' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            'S' => self.cmd("save_file", .{}),
            'L' => self.cmd_cycle3("scroll_view_center", "scroll_view_top", "scroll_view_bottom", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'B' => self.cmd("move_to_char", command.fmt(.{false})),
            'T' => self.cmd("move_to_char", command.fmt(.{true})),
            'X' => self.cmd("cut", .{}),
            'C' => self.cmd("enter_mode", command.fmt(.{"helix/normal"})),
            'V' => self.cmd("system_paste", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'F' => self.cmd("find", .{}),
            'G' => self.cmd("goto", .{}),
            'O' => self.cmd("run_ls", .{}),
            'A' => self.cmd("select_all", .{}),
            'I' => self.insert_bytes("\t"),
            '/' => self.cmd("toggle_comment", .{}),
            input.key.enter => self.cmd("smart_insert_line_after", .{}),
            input.key.space => self.cmd("selections_reverse", .{}),
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
            'B' => self.cmd("move_word_left", .{}),
            'F' => self.cmd("move_word_right", .{}),
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
            input.key.up => self.cmd("add_cursor_up", .{}),
            input.key.down => self.cmd("add_cursor_down", .{}),
            else => {},
        },
        input.mod.shift => switch (keypress) {
            input.key.f3 => self.cmd("goto_prev_match", .{}),
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
            input.key.escape => self.cmd("enter_mode", command.fmt(.{"helix/normal"})),
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

pub const hints = keybind.KeybindHints.initComptime(.{});

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
