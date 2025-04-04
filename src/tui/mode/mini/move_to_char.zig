const std = @import("std");
const tp = @import("thespian");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

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
    var direction: Direction = undefined;

    if (tui.input_mode()) |input_mode| if (std.mem.eql(u8, "select", input_mode.mode) or std.mem.eql(u8, "visual", input_mode.mode)) if (tui.mainview()) |mv| if (mv.get_active_editor()) |ed| {
        const root = try ed.buf_root();
        _ = try ed.get_primary().enable_selection(root, ed.metrics);
    };

    const select = if (tui.get_active_editor()) |editor| if (editor.get_primary().selection) |_| true else false else false;
    _ = ctx.args.match(.{tp.extract(&direction)}) catch return error.InvalidMoveToCharArgument;
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .direction = direction,
        .operation = if (select) .select else .move,
    };
    try self.commands.init(self);
    var mode = try keybind.mode("mini/move_to_char", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = self.name() } };
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

fn execute_operation(self: *Self, ctx: command.Context) command.Result {
    const cmd = Cmd: switch (self.direction) {
        .left => switch (self.operation) {
            .move => "move_to_char_left",
            .select => "select_to_char_left",
        },
        .right => switch (self.operation) {
            .move => "move_to_char_right",
            .select => {
                if (std.mem.eql(u8, "helix", tui.config().input_mode)) break :Cmd "select_to_char_right_helix";
                break :Cmd "select_to_char_right";
            },
        },
    };
    try command.executeName(cmd, ctx);
    try command.executeName("exit_mini_mode", .{});
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var code_point: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&code_point)}))
            return error.InvalidMoveToCharInsertCodePointArgument;
        var buf: [6]u8 = undefined;
        const bytes = input.ucs32_to_utf8(&[_]u32{code_point}, &buf) catch return error.InvalidMoveToCharCodePoint;
        return self.execute_operation(command.fmt(.{buf[0..bytes]}));
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidMoveToCharInsertBytesArgument;
        return self.execute_operation(ctx);
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
        command.executeName("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };
};
