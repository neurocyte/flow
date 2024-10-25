const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const ed = @import("../../editor.zig");

const Allocator = @import("std").mem.Allocator;
const eql = @import("std").mem.eql;
const ArrayList = @import("std").ArrayList;

const Self = @This();

allocator: Allocator,
input: ArrayList(u8),
last_input: ArrayList(u8),
start_view: ed.View,
start_cursor: ed.Cursor,
editor: *ed.Editor,
history_pos: ?usize = null,

pub fn create(allocator: Allocator, _: command.Context) !*Self {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        const self: *Self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .input = ArrayList(u8).init(allocator),
            .last_input = ArrayList(u8).init(allocator),
            .start_view = editor.view,
            .start_cursor = editor.get_primary().cursor,
            .editor = editor,
        };
        if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.allocator) catch break :ret;
            defer self.allocator.free(text);
            try self.input.appendSlice(text);
        }
        return self;
    };
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.input.deinit();
    self.last_input.deinit();
    self.allocator.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(_: *Self) []const u8 {
    return "󱎸 find";
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;
    var text: []const u8 = undefined;

    defer {
        if (tui.current().mini_mode) |*mini_mode| {
            mini_mode.text = self.input.items;
            mini_mode.cursor = self.input.items.len;
        }
    }

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        self.mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{"F"})) {
        self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
    switch (evtype) {
        event_type.PRESS => try self.mapPress(keypress, egc, modifiers),
        event_type.REPEAT => try self.mapPress(keypress, egc, modifiers),
        event_type.RELEASE => try self.mapRelease(keypress, egc, modifiers),
        else => {},
    }
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'Q' => self.cmd("quit", .{}),
            'V' => self.cmd("system_paste", .{}),
            'U' => self.input.clearRetainingCapacity(),
            'G' => self.cancel(),
            'C' => self.cancel(),
            'L' => self.cmd("scroll_view_center", .{}),
            'F' => self.cmd("goto_next_match", .{}),
            'N' => self.cmd("goto_next_match", .{}),
            'P' => self.cmd("goto_prev_match", .{}),
            'I' => self.insert_bytes("\t"),
            key.SPACE => self.cancel(),
            key.ENTER => self.insert_bytes("\n"),
            key.BACKSPACE => self.input.clearRetainingCapacity(),
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
            key.BACKSPACE => _ = self.input.popOrNull(),
            key.LCTRL, key.RCTRL => self.cmd("enable_fast_scroll", .{}),
            key.LALT, key.RALT => self.cmd("enable_fast_scroll", .{}),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32, _: u32) !void {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => self.cmd("disable_fast_scroll", .{}),
        key.LALT, key.RALT => self.cmd("disable_fast_scroll", .{}),
        else => {},
    };
}

fn insert_code_point(self: *Self, c: u32) !void {
    var buf: [16]u8 = undefined;
    const bytes = ucs32_to_utf8(&[_]u32{c}, &buf) catch |e| return tp.exit_error(e, @errorReturnTrace());
    try self.input.appendSlice(buf[0..bytes]);
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    try self.input.appendSlice(bytes);
}

fn flush_input(self: *Self) !void {
    if (self.input.items.len > 0) {
        if (eql(u8, self.input.items, self.last_input.items))
            return;
        self.last_input.clearRetainingCapacity();
        try self.last_input.appendSlice(self.input.items);
        self.editor.find_operation = .goto_next_match;
        const primary = self.editor.get_primary();
        primary.selection = null;
        primary.cursor = self.start_cursor;
        try self.editor.find_in_buffer(self.input.items);
    } else {
        self.editor.get_primary().selection = null;
        self.editor.init_matches_update();
    }
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.flush_input() catch {};
    return command.executeName(name_, ctx);
}

fn confirm(self: *Self) void {
    self.editor.push_find_history(self.input.items);
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
            if (self.input.items.len > 0)
                self.editor.push_find_history(self.editor.allocator.dupe(u8, self.input.items) catch return);
            if (eql(u8, history.items[self.history_pos.?], self.input.items) and self.history_pos.? > 0)
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
        self.input.clearRetainingCapacity();
        self.input.appendSlice(history.items[pos]) catch {};
    }
}
