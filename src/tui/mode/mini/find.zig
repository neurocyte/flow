const nc = @import("notcurses");
const tp = @import("thespian");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const ed = @import("../../editor.zig");

const Allocator = @import("std").mem.Allocator;
const json = @import("std").json;
const eql = @import("std").mem.eql;
const mod = nc.mod;
const key = nc.key;

const Self = @This();

a: Allocator,
buf: [1024]u8 = undefined,
input: []u8 = "",
last_buf: [1024]u8 = undefined,
last_input: []u8 = "",
start_view: ed.View,
start_cursor: ed.Cursor,
editor: *ed.Editor,
history_pos: ?usize = null,

pub fn create(a: Allocator, _: command.Context) !*Self {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        const self: *Self = try a.create(Self);
        self.* = .{
            .a = a,
            .start_view = editor.view,
            .start_cursor = editor.get_primary().cursor,
            .editor = editor,
        };
        if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.a) catch break :ret;
            defer self.a.free(text);
            @memcpy(self.buf[0..text.len], text);
            self.input = self.buf[0..text.len];
        }
        return self;
    };
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.a.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(_: *Self) []const u8 {
    return "find";
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;

    defer {
        if (tui.current().mini_mode) |*mini_mode| {
            mini_mode.text = self.input;
            mini_mode.cursor = self.input.len;
        }
    }

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        try self.mapEvent(evtype, keypress, egc, modifiers);
    } else if (try m.match(.{"F"})) {
        self.flush_input() catch |e| return e;
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) tp.result {
    switch (evtype) {
        nc.event_type.PRESS => try self.mapPress(keypress, egc, modifiers),
        nc.event_type.REPEAT => try self.mapPress(keypress, egc, modifiers),
        nc.event_type.RELEASE => try self.mapRelease(keypress, egc, modifiers),
        else => {},
    }
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'Q' => self.cmd("quit", .{}),
            'V' => self.cmd("system_paste", .{}),
            'U' => self.input = "",
            'G' => self.cancel(),
            'C' => self.cancel(),
            'L' => self.cmd("scroll_view_center", .{}),
            'F' => self.cmd("goto_next_match", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'I' => self.insert_bytes("\t"),
            key.SPACE => self.cancel(),
            key.ENTER => self.insert_bytes("\n"),
            key.BACKSPACE => self.input = "",
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'V' => self.cmd("system_paste", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'V' => self.cmd("system_paste", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            key.ENTER => self.cmd("goto_prev_match", .{}),
            key.F03 => self.cmd("goto_prev_match", .{}),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        0 => switch (keypress) {
            key.UP => self.find_history_prev(),
            key.DOWN => self.find_history_next(),
            key.F03 => self.cmd("goto_next_match", .{}),
            key.F15 => self.cmd("goto_prev_match", .{}),
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.ESC => self.cancel(),
            key.ENTER => self.confirm(),
            key.BACKSPACE => if (self.input.len > 0) {
                self.input = self.input[0 .. self.input.len - 1];
            },
            key.LCTRL, key.RCTRL => self.cmd("enable_fast_scroll", .{}),
            key.LALT, key.RALT => self.cmd("enable_fast_scroll", .{}),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
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
    if (self.input.len + 16 > self.buf.len)
        try self.flush_input();
    const bytes = nc.ucs32_to_utf8(&[_]u32{c}, self.buf[self.input.len..]) catch |e| return tp.exit_error(e);
    self.input = self.buf[0 .. self.input.len + bytes];
}

fn insert_bytes(self: *Self, bytes: []const u8) tp.result {
    if (self.input.len + 16 > self.buf.len)
        try self.flush_input();
    const newlen = self.input.len + bytes.len;
    @memcpy(self.buf[self.input.len..newlen], bytes);
    self.input = self.buf[0..newlen];
}

var find_cmd_id: ?command.ID = null;

fn flush_input(self: *Self) tp.result {
    if (self.input.len > 0) {
        if (eql(u8, self.input, self.last_input))
            return;
        @memcpy(self.last_buf[0..self.input.len], self.input);
        self.last_input = self.last_buf[0..self.input.len];
        self.editor.find_operation = .goto_next_match;
        self.editor.get_primary().cursor = self.start_cursor;
        try self.editor.find_in_buffer(self.input);
    }
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.flush_input() catch {};
    return command.executeName(name_, ctx);
}

fn confirm(self: *Self) void {
    self.editor.push_find_history(self.input);
    self.cmd("exit_mini_mode", .{}) catch {};
}

fn cancel(self: *Self) void {
    self.editor.get_primary().cursor = self.start_cursor;
    self.editor.scroll_to(self.start_view.row);
    command.executeName("exit_mini_mode", .{}) catch {};
}

fn find_history_prev(self: *Self) void {
    if (self.editor.find_history) |*history| {
        if (self.history_pos) |pos| {
            if (pos > 0) self.history_pos = pos - 1;
        } else {
            self.history_pos = history.items.len - 1;
            if (self.input.len > 0)
                self.editor.push_find_history(self.editor.a.dupe(u8, self.input) catch return);
            if (eql(u8, history.items[self.history_pos.?], self.input) and self.history_pos.? > 0)
                self.history_pos = self.history_pos.? - 1;
        }
        self.load_history(self.history_pos.?);
    }
}

fn find_history_next(self: *Self) void {
    if (self.editor.find_history) |*history| if (self.history_pos) |pos| {
        if (pos < history.items.len - 1) {
            self.history_pos = pos + 1;
            self.load_history(self.history_pos.?);
        }
    };
}

fn load_history(self: *Self, pos: usize) void {
    if (self.editor.find_history) |*history| {
        const new = history.items[pos];
        @memcpy(self.buf[0..new.len], new);
        self.input = self.buf[0..new.len];
    }
}
