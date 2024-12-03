const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");

const Allocator = @import("std").mem.Allocator;
const fmt = @import("std").fmt;

const Self = @This();
const name = "＃goto";

const Commands = command.Collection(cmds);

allocator: Allocator,
buf: [30]u8 = undefined,
input: ?usize = null,
start: usize,
commands: Commands = undefined,

pub fn create(allocator: Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
    const self: *Self = try allocator.create(Self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        self.* = .{
            .allocator = allocator,
            .start = editor.get_primary().cursor.row + 1,
        };
        try self.commands.init(self);
        var mode = try keybind.mode("mini/goto", allocator, .{
            .insert_command = "mini_mode_insert_bytes",
        });
        mode.event_handler = EventHandler.to_owned(self);
        return .{ mode, .{ .name = name } };
    };
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.allocator.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    self.update_mini_mode_text();
    return false;
}

fn update_mini_mode_text(self: *Self) void {
    if (tui.current().mini_mode) |*mini_mode| {
        mini_mode.text = if (self.input) |linenum|
            (fmt.bufPrint(&self.buf, "{d}", .{linenum}) catch "")
        else
            "";
        mini_mode.cursor = mini_mode.text.len;
    }
}

fn goto(self: *Self) void {
    command.executeName("goto_line", command.fmt(.{self.input orelse self.start})) catch {};
}

fn insert_char(self: *Self, char: u8) void {
    switch (char) {
        '0' => {
            if (self.input) |linenum| self.input = linenum * 10;
        },
        '1'...'9' => {
            const digit: usize = @intCast(char - '0');
            self.input = if (self.input) |x| x * 10 + digit else digit;
        },
        else => {},
    }
}

fn insert_bytes(self: *Self, bytes: []const u8) void {
    for (bytes) |c| self.insert_char(c);
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        self.input = null;
        self.update_mini_mode_text();
    }
    pub const mini_mode_reset_meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(self: *Self, _: Ctx) Result {
        self.input = null;
        self.update_mini_mode_text();
        self.goto();
        command.executeName("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_cancel_meta = .{ .description = "Cancel input" };

    pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
        if (self.input) |linenum| {
            const newval = if (linenum < 10) 0 else linenum / 10;
            self.input = if (newval == 0) null else newval;
            self.update_mini_mode_text();
            self.goto();
        }
    }
    pub const mini_mode_delete_backwards_meta = .{ .description = "Delete backwards" };

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var keypress: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&keypress)}))
            return error.InvalidArgument;
        switch (keypress) {
            '0'...'9' => self.insert_char(@intCast(keypress)),
            else => {},
        }
        self.update_mini_mode_text();
        self.goto();
    }
    pub const mini_mode_insert_code_point_meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidArgument;
        self.insert_bytes(bytes);
        self.update_mini_mode_text();
        self.goto();
    }
    pub const mini_mode_insert_bytes_meta = .{ .arguments = &.{.string} };
};
