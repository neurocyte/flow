const nc = @import("notcurses");
const tp = @import("thespian");
const root = @import("root");

const tui = @import("../../../tui.zig");
const command = @import("../../../command.zig");
const EventHandler = @import("../../../EventHandler.zig");

const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const json = @import("std").json;
const eql = @import("std").mem.eql;
const mod = nc.mod;
const key = nc.key;

const Self = @This();
const input_buffer_size = 1024;

a: Allocator,
input: ArrayList(u8),
last_cmd: []const u8 = "",
leader: ?struct { keypress: u32, modifiers: u32 } = null,

pub fn create(a: Allocator) !tui.Mode {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .input = try ArrayList(u8).initCapacity(a, input_buffer_size),
    };
    return .{
        .handler = EventHandler.to_owned(self),
        .name = root.application_logo ++ "INSERT",
        .description = "vim",
        .line_numbers = if (tui.current().config.vim_insert_gutter_line_numbers_relative) .relative else .absolute,
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
        nc.event_type.PRESS => self.mapPress(keypress, egc, modifiers),
        nc.event_type.REPEAT => self.mapPress(keypress, egc, modifiers),
        nc.event_type.RELEASE => self.mapRelease(keypress, egc, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    if (self.leader) |_| return self.mapFollower(keynormal, egc, modifiers);
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'U' => self.cmd("move_scroll_page_up", .{}),
            'D' => self.cmd("move_scroll_page_down", .{}),
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
            'C' => self.cmd("enter_mode", command.fmt(.{"vim/normal"})),
            'V' => self.cmd("system_paste", .{}),
            'K' => self.leader = .{ .keypress = keynormal, .modifiers = modifiers },
            'F' => self.cmd("enter_find_mode", .{}),
            'G' => self.cmd("enter_goto_mode", .{}),
            'O' => self.cmd("run_ls", .{}),
            'A' => self.cmd("select_all", .{}),
            'I' => self.insert_bytes("\t"),
            '/' => self.cmd("toggle_comment", .{}),
            key.ENTER => self.cmd("insert_line_after", .{}),
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
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'D' => self.cmd("dupe_down", .{}),
            'Z' => self.cmd("redo", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'F' => self.cmd("enter_find_in_files_mode", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            '/' => self.cmd("log_widgets", .{}),
            key.ENTER => self.cmd("insert_line_before", .{}),
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
            'L' => self.cmd("toggle_logview", .{}),
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
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'D' => self.cmd("dupe_up", .{}),
            'F' => self.cmd("filter", command.fmt(.{ "zig", "fmt", "--stdin" })),
            'S' => self.cmd("filter", command.fmt(.{ "sort", "-u" })),
            'V' => self.cmd("paste", .{}),
            key.LEFT => self.cmd("move_scroll_left", .{}),
            key.RIGHT => self.cmd("move_scroll_right", .{}),
            key.UP => self.cmd("add_cursor_up", .{}),
            key.DOWN => self.cmd("add_cursor_down", .{}),
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
            key.ENTER => self.cmd("insert_line_before", .{}),
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
            key.F11 => self.cmd("toggle_logview", .{}),
            key.F12 => self.cmd("toggle_inputview", .{}),
            key.F34 => self.cmd("toggle_whitespace", .{}), // C-F10
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
            key.LCTRL, key.RCTRL => self.cmd("enable_fast_scroll", .{}),
            key.LALT, key.RALT => self.cmd("enable_fast_scroll", .{}),
            key.TAB => self.cmd("indent", .{}),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn mapFollower(self: *Self, keypress: u32, _: u32, modifiers: u32) tp.result {
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
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32, _: u32) tp.result {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => self.cmd("disable_fast_scroll", .{}),
        key.LALT, key.RALT => self.cmd("disable_fast_scroll", .{}),
        else => {},
    };
}

fn insert_code_point(self: *Self, c: u32) tp.result {
    if (self.input.items.len + 4 > input_buffer_size)
        try self.flush_input();
    var buf: [6]u8 = undefined;
    const bytes = nc.ucs32_to_utf8(&[_]u32{c}, &buf) catch |e| return tp.exit_error(e);
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
