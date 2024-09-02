const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");

const Allocator = @import("std").mem.Allocator;
const json = @import("std").json;
const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;

const Self = @This();

allocator: Allocator,
buf: [30]u8 = undefined,
input: ?usize = null,
start: usize,

pub fn create(allocator: Allocator, _: command.Context) !*Self {
    const self: *Self = try allocator.create(Self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        self.* = .{
            .allocator = allocator,
            .start = editor.get_primary().cursor.row + 1,
        };
        return self;
    };
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(_: *Self) []const u8 {
    return "＃goto";
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var modifiers: u32 = undefined;
    defer {
        if (tui.current().mini_mode) |*mini_mode| {
            mini_mode.text = if (self.input) |linenum|
                (fmt.bufPrint(&self.buf, "{d}", .{linenum}) catch "")
            else
                "";
            mini_mode.cursor = mini_mode.text.len;
        }
    }
    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.any, tp.string, tp.extract(&modifiers) }))
        try self.mapEvent(evtype, keypress, modifiers);
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, modifiers: u32) tp.result {
    switch (evtype) {
        event_type.PRESS => try self.mapPress(keypress, modifiers),
        event_type.REPEAT => try self.mapPress(keypress, modifiers),
        event_type.RELEASE => try self.mapRelease(keypress, modifiers),
        else => {},
    }
}

fn mapPress(self: *Self, keypress: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'Q' => command.executeName("quit", .{}),
            'U' => self.input = null,
            'G' => self.cancel(),
            'C' => self.cancel(),
            'L' => command.executeName("scroll_view_center", .{}),
            key.SPACE => self.cancel(),
            else => {},
        },
        0 => switch (keypress) {
            key.LCTRL, key.RCTRL => command.executeName("enable_fast_scroll", .{}),
            key.LALT, key.RALT => command.executeName("enable_fast_scroll", .{}),
            key.ESC => self.cancel(),
            key.ENTER => command.executeName("exit_mini_mode", .{}),
            key.BACKSPACE => if (self.input) |linenum| {
                const newval = if (linenum < 10) 0 else linenum / 10;
                self.input = if (newval == 0) null else newval;
                self.goto();
            },
            '0' => {
                if (self.input) |linenum| self.input = linenum * 10;
                self.goto();
            },
            '1'...'9' => {
                const digit: usize = @intCast(keypress - '0');
                self.input = if (self.input) |x| x * 10 + digit else digit;
                self.goto();
            },
            else => {},
        },
        else => {},
    };
}

fn mapRelease(_: *Self, keypress: u32, _: u32) tp.result {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => command.executeName("disable_fast_scroll", .{}),
        key.LALT, key.RALT => command.executeName("disable_fast_scroll", .{}),
        else => {},
    };
}

fn goto(self: *Self) void {
    command.executeName("goto_line", command.fmt(.{self.input orelse self.start})) catch {};
}

fn cancel(self: *Self) void {
    self.input = null;
    self.goto();
    command.executeName("exit_mini_mode", .{}) catch {};
}
