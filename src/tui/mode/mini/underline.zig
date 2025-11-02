const std = @import("std");
const cbor = @import("cbor");
const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub fn name(_: *Type) []const u8 {
    return "underline";
}

pub fn process_egc(_: *Type, egc: []const u8) command.Result {
    try command.executeName("underline_with_char", command.fmt(.{ egc, "solid" }));
    try command.executeName("exit_mini_mode", .{});
}
