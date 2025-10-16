const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

const Allocator = @import("std").mem.Allocator;

const Self = @This();

const Commands = command.Collection(cmds);

allocator: Allocator,
commands: Commands = undefined,

pub fn create(allocator: Allocator, ctx: command.Context) !struct { tui.Mode, tui.MiniMode } {
    var operation_command: []const u8 = undefined;
    _ = ctx.args.match(.{tp.extract(&operation_command)}) catch return error.InvalidReplaceArgument;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
    };
    try self.commands.init(self);
    var mode = try keybind.mode("mini/replace", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = self.name() } };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.allocator.destroy(self);
}

fn name(_: *Self) []const u8 {
    return "🗘 replace";
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}

fn execute_operation(_: *Self, ctx: command.Context) command.Result {
    try command.executeName("replace_with_character_helix", ctx);
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
            return error.InvalidRepaceInsertCodePointArgument;

        log.logger("replace").print("replacement '{d}'", .{code_point});
        var buf: [6]u8 = undefined;
        const bytes = input.ucs32_to_utf8(&[_]u32{code_point}, &buf) catch return error.InvalidReplaceCodePoint;
        log.logger("replace").print("replacement '{s}'", .{buf[0..bytes]});
        return self.execute_operation(ctx);
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .description = "🗘 Replace" };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidReplaceInsertBytesArgument;
        log.logger("replace").print("replacement '{s}'", .{bytes});
        return self.execute_operation(ctx);
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
        command.executeName("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel replace" };
};
