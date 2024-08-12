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
const json = @import("std").json;
const eql = @import("std").mem.eql;

const Self = @This();

a: Allocator,
buf: [1024]u8 = undefined,
input: []u8 = "",
last_buf: [1024]u8 = undefined,
last_input: []u8 = "",
mainview: *mainview,

pub fn create(a: Allocator, _: command.Context) !*Self {
    const self: *Self = try a.create(Self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv| {
        self.* = .{
            .a = a,
            .mainview = mv,
        };
        if (mv.get_editor()) |editor| if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.a) catch break :ret;
            defer self.a.free(text);
            @memcpy(self.buf[0..text.len], text);
            self.input = self.buf[0..text.len];
        };
        return self;
    }
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.a.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(_: *Self) []const u8 {
    return "󰥨 find";
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;
    var text: []const u8 = undefined;

    defer {
        if (tui.current().mini_mode) |*mini_mode| {
            mini_mode.text = self.input;
            mini_mode.cursor = self.input.len;
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
            'N' => self.cmd("goto_next_file", .{}),
            'P' => self.cmd("goto_prev_file", .{}),
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
            key.UP => self.cmd("select_prev_file", .{}),
            key.DOWN => self.cmd("select_next_file", .{}),
            key.F03 => self.cmd("goto_next_match", .{}),
            key.F15 => self.cmd("goto_prev_match", .{}),
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.ESC => self.cancel(),
            key.ENTER => self.cmd("goto_selected_file", .{}) catch self.cmd("exit_mini_mode", .{}),
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

fn mapRelease(self: *Self, keypress: u32, _: u32, _: u32) !void {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => self.cmd("disable_fast_scroll", .{}),
        key.LALT, key.RALT => self.cmd("disable_fast_scroll", .{}),
        else => {},
    };
}

fn insert_code_point(self: *Self, c: u32) !void {
    if (self.input.len + 16 > self.buf.len)
        try self.flush_input();
    const bytes = try ucs32_to_utf8(&[_]u32{c}, self.buf[self.input.len..]);
    self.input = self.buf[0 .. self.input.len + bytes];
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    if (self.input.len + 16 > self.buf.len)
        try self.flush_input();
    const newlen = self.input.len + bytes.len;
    @memcpy(self.buf[self.input.len..newlen], bytes);
    self.input = self.buf[0..newlen];
}

var find_cmd_id: ?command.ID = null;

fn flush_input(self: *Self) !void {
    if (self.input.len > 2) {
        if (eql(u8, self.input, self.last_input))
            return;
        @memcpy(self.last_buf[0..self.input.len], self.input);
        self.last_input = self.last_buf[0..self.input.len];
        try self.mainview.find_in_files(self.input);
    }
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.flush_input() catch {};
    return command.executeName(name_, ctx);
}

fn cancel(_: *Self) void {
    command.executeName("exit_mini_mode", .{}) catch {};
}
