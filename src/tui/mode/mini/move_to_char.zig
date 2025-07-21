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
operation_command: []const u8,
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
    var operation_command: []const u8 = undefined;
    _ = ctx.args.match(.{tp.extract(&operation_command)}) catch return error.InvalidMoveToCharArgument;

    const direction: Direction = if (std.mem.indexOf(u8, operation_command, "_left")) |_| .left else .right;
    const operation: Operation = if (tui.get_active_editor()) |editor| if (editor.get_primary().selection) |_| .select else .move else .move;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .direction = direction,
        .operation_command = try allocator.dupe(u8, operation_command),
        .operation = operation,
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
    self.allocator.free(self.operation_command);
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
    try command.executeName(self.operation_command, ctx);
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
