const std = @import("std");
const cbor = @import("cbor");
const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    direction: Direction,
    operation_command: []const u8,
    operation: Operation,
};

const Direction = enum {
    left,
    right,
};

const Operation = enum {
    move,
    select,
    extend,
};

pub fn start(self: *Type) ValueType {
    var operation_command: []const u8 = "move_to_char_left";
    _ = self.ctx.args.match(.{cbor.extract(&operation_command)}) catch {};

    const direction: Direction = if (std.mem.indexOf(u8, operation_command, "_left")) |_| .left else .right;
    var operation: Operation = undefined;
    if (std.mem.indexOf(u8, operation_command, "extend_")) |_| {
        operation = .extend;
    } else if (std.mem.indexOf(u8, operation_command, "select_")) |_| {
        operation = .select;
    } else if (tui.get_active_editor()) |editor| if (editor.get_primary().selection) |_| {
        operation = .select;
    } else {
        operation = .move;
    } else {
        operation = .move;
    }

    return .{
        .direction = direction,
        .operation_command = operation_command,
        .operation = operation,
    };
}

pub fn name(self: *Type) []const u8 {
    return switch (self.value.operation) {
        .move => switch (self.value.direction) {
            .left => "↶ move",
            .right => "↷ move",
        },
        .select => switch (self.value.direction) {
            .left => "󰒅 ↶ select",
            .right => "󰒅 ↷ select",
        },
        .extend => switch (self.value.direction) {
            .left => "󰒅 ↶ extend",
            .right => "󰒅 ↷ extend",
        },
    };
}

pub fn process_egc(self: *Type, egc: []const u8) command.Result {
    try command.executeName(self.value.operation_command, command.fmt(.{egc}));
    try command.executeName("exit_mini_mode", .{});
}
