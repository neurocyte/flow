const tp = @import("thespian");
const std = @import("std");

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
commands: Commands = undefined,
last_key: KeyPressEvent = .{},

pub const KeyPressEvent = struct {
    keypress: u32 = 0,
    modifiers: u32 = std.math.maxInt(u32),
    egc: u32 = 0,
    timestamp_ms: i64 = 0,
};

pub fn create(allocator: Allocator) !tui.Mode {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .input = try ArrayList(u8).initCapacity(allocator, input_buffer_size),
    };
    try self.commands.init(self);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "INSERT",
        .description = "vim",
        .line_numbers = if (tui.current().config.vim_insert_gutter_line_numbers_relative) .relative else .absolute,
        .cursor_shape = .beam,
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
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    if (self.leader) |_| return self.mapFollower(keynormal, egc, modifiers);
    switch (keypress) {
        key.LCTRL, key.RCTRL => return self.cmd("enable_fast_scroll", .{}),
        key.LALT, key.RALT => return self.cmd("enable_jump_mode", .{}),
        else => {},
    }

    //reset chord if enough time has passed
    const chord_time_window_ms = 750;
    if (std.time.milliTimestamp() - self.last_key.timestamp_ms > chord_time_window_ms) {
        self.last_key = .{};
    }

    //chording
    if (self.last_key.keypress == 'j' and self.last_key.modifiers == 0 and keypress == 'k' and modifiers == 0) {
        try self.cmd("delete_backward", .{});
        try self.cmd("enter_mode", command.fmt(.{"vim/normal"}));
        return;
    }
    if (self.last_key.keypress == 'k' and self.last_key.modifiers == 0 and keypress == 'j' and modifiers == 0) {
        try self.cmd("delete_backward", .{});
        try self.cmd("enter_mode", command.fmt(.{"vim/normal"}));
        return;
    }
    if (self.last_key.keypress == 'f' and self.last_key.modifiers == 0 and keypress == 'j' and modifiers == 0) {
        try self.cmd("delete_backward", .{});
        try self.cmd("enter_mode", command.fmt(.{"vim/normal"}));
        return;
    }
    if (self.last_key.keypress == 'j' and self.last_key.modifiers == 0 and keypress == 'f' and modifiers == 0) {
        try self.cmd("delete_backward", .{});
        try self.cmd("enter_mode", command.fmt(.{"vim/normal"}));
        return;
    }

    //record current key event
    self.last_key = .{
        .keypress = keypress,
        .modifiers = modifiers,
        .egc = egc,
        .timestamp_ms = std.time.milliTimestamp(),
    };

    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
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
            'C' => self.cmd("enter_mode", command.fmt(.{"vim/normal"})),
            'V' => self.cmd("system_paste", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'F' => self.cmd("find", .{}),
            'G' => self.cmd("goto", .{}),
            'O' => self.cmd("run_ls", .{}),
            'A' => self.cmd("select_all", .{}),
            'I' => self.insert_bytes("\t"),
            '/' => self.cmd("toggle_comment", .{}),
            key.ENTER => self.cmd("smart_insert_line_after", .{}),
            key.SPACE => self.cmd("selections_reverse", .{}),
            key.END => self.cmd("move_buffer_end", .{}),
            key.HOME => self.cmd("move_buffer_begin", .{}),
            key.UP => self.cmd("move_scroll_up", .{}),
            key.DOWN => self.cmd("move_scroll_down", .{}),
            key.PGUP => self.cmd("move_scroll_page_up", .{}),
            key.PGDOWN => self.cmd("move_scroll_page_down", .{}),
            key.LEFT => self.cmd("move_word_left", .{}),
            key.RIGHT => self.cmd("move_word_right", .{}),
            key.BACKSPACE => self.cmd("delete_word_left", .{}),
            key.DEL => self.cmd("delete_word_right", .{}),
            key.F05 => self.cmd("toggle_inspector_view", .{}),
            key.F10 => self.cmd("toggle_whitespace_mode", .{}), // aka F34
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("open_command_palette", .{}),
            'D' => self.cmd("dupe_down", .{}),
            'Z' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'W' => self.cmd("close_file_without_saving", .{}),
            'F' => self.cmd("find_in_files", .{}),
            'L' => self.cmd_async("add_cursor_all_matches"),
            'I' => self.cmd_async("toggle_inspector_view"),
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
            'B' => self.cmd("move_word_left", .{}),
            'F' => self.cmd("move_word_right", .{}),
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
            'P' => self.cmd("open_command_palette", .{}),
            'D' => self.cmd("dupe_up", .{}),
            'F' => self.cmd("filter", command.fmt(.{ "zig", "fmt", "--stdin" })),
            'S' => self.cmd("filter", command.fmt(.{ "sort", "-u" })),
            'V' => self.cmd("paste", .{}),
            'I' => self.cmd("add_cursors_to_line_ends", .{}),
            key.LEFT => self.cmd("move_scroll_left", .{}),
            key.RIGHT => self.cmd("move_scroll_right", .{}),
            key.UP => self.cmd("add_cursor_up", .{}),
            key.DOWN => self.cmd("add_cursor_down", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            key.F03 => self.cmd("goto_prev_match", .{}),
            key.F10 => self.cmd("toggle_syntax_highlighting", .{}),
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
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
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
            key.F11 => self.cmd("toggle_panel", .{}),
            key.F12 => self.cmd("goto_definition", .{}),
            key.F34 => self.cmd("toggle_whitespace_mode", .{}), // C-F10
            key.F58 => self.cmd("gutter_mode_next", .{}), // A-F10
            key.ESC => self.cmd("enter_mode", command.fmt(.{"vim/normal"})),
            key.ENTER => self.cmd("smart_insert_line", .{}),
            key.DEL => self.cmd("delete_forward", .{}),
            key.BACKSPACE => self.cmd("delete_backward", .{}),
            key.LEFT => self.cmd("move_left", .{}),
            key.RIGHT => self.cmd("move_right", .{}),
            key.UP => self.cmd("move_up", .{}),
            key.DOWN => self.cmd("move_down", .{}),
            key.HOME => self.cmd("smart_move_begin", .{}),
            key.END => self.cmd("move_end", .{}),
            key.PGUP => self.cmd("move_page_up", .{}),
            key.PGDOWN => self.cmd("move_page_down", .{}),
            key.TAB => self.cmd("indent", .{}),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn mapFollower(self: *Self, keypress: u32, _: u32, modifiers: u32) !void {
    defer self.leader = null;
    const ldr = if (self.leader) |leader| leader else return;
    return switch (ldr.modifiers) {
        mod.CTRL => switch (ldr.keypress) {
            'K' => switch (modifiers) {
                mod.CTRL => switch (keypress) {
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

fn mapRelease(self: *Self, keypress: u32, _: u32, _: u32) !void {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => self.cmd("disable_fast_scroll", .{}),
        key.LALT, key.RALT => self.cmd("disable_jump_mode", .{}),
        else => {},
    };
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
    try self.flush_input();
    self.last_cmd = name_;
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
