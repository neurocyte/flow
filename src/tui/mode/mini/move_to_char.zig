const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");

const Allocator = @import("std").mem.Allocator;

const Self = @This();

const Commands = command.Collection(cmds);

allocator: Allocator,
key: [6]u8 = undefined,
direction: Direction,
operation: Operation,
commands: Commands = undefined,

const Direction = enum {
    left,
    right,
};

const Operation = enum {
    move,
    select,
};

pub fn create(allocator: Allocator, ctx: command.Context) !struct { tui.Mode, tui.MiniMode } {
    var right: bool = true;
    const select = if (tui.current().mainview.dynamic_cast(mainview)) |mv| if (mv.get_editor()) |editor| if (editor.get_primary().selection) |_| true else false else false else false;
    _ = ctx.args.match(.{tp.extract(&right)}) catch return error.NotFound;
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .direction = if (right) .right else .left,
        .operation = if (select) .select else .move,
    };
    try self.commands.init(self);
    return .{
        .{
            .input_handler = keybind.mode.mini.move_to_char.create(allocator),
            .event_handler = EventHandler.to_owned(self),
        },
        .{
            .name = self.name(),
        },
    };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.allocator.destroy(self);
}

fn name(self: *Self) []const u8 {
    return switch (self.operation) {
        .move => switch (self.direction) {
            .left => "↶ move",
            .right => "↷ move",
        },
        .select => switch (self.direction) {
            .left => "󰒅 ↶ select",
            .right => "󰒅 ↷ select",
        },
    };
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    switch (keypress) {
        key.LSUPER, key.RSUPER => return,
        key.LSHIFT, key.RSHIFT => return,
        key.LCTRL, key.RCTRL => return,
        key.LALT, key.RALT => return,
        else => {},
    }
    return switch (modifiers) {
        mod.SHIFT => if (!key.synthesized_p(keypress)) self.execute_operation(egc) else self.cancel(),
        0 => switch (keypress) {
            key.ESC => self.cancel(),
            key.ENTER => self.cancel(),
            else => if (!key.synthesized_p(keypress)) self.execute_operation(egc) else self.cancel(),
        },
        else => self.cancel(),
    };
}

fn execute_operation(self: *Self, c: u32) void {
    const cmd = switch (self.direction) {
        .left => switch (self.operation) {
            .move => "move_to_char_left",
            .select => "select_to_char_left",
        },
        .right => switch (self.operation) {
            .move => "move_to_char_right",
            .select => "select_to_char_right",
        },
    };
    var buf: [6]u8 = undefined;
    const bytes = ucs32_to_utf8(&[_]u32{c}, &buf) catch return;
    command.executeName(cmd, command.fmt(.{buf[0..bytes]})) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var code_point: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&code_point)}))
            return error.InvalidArgument;
        var buf: [6]u8 = undefined;
        const bytes = ucs32_to_utf8(&[_]u32{code_point}, &buf) catch return error.InvalidArgument;
        const cmd = switch (self.direction) {
            .left => switch (self.operation) {
                .move => "move_to_char_left",
                .select => "select_to_char_left",
            },
            .right => switch (self.operation) {
                .move => "move_to_char_right",
                .select => "select_to_char_right",
            },
        };
        try command.executeName(cmd, command.fmt(.{buf[0..bytes]}));
        try command.executeName("exit_mini_mode", .{});
    }
    pub const mini_mode_insert_code_point_meta = .{ .interactive = false };

    pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
        command.executeName("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_cancel_meta = .{ .description = "Cancel input" };
};
