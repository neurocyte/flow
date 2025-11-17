const std = @import("std");
const cbor = @import("cbor");
const command = @import("command");
const tp = @import("thespian");
const log = @import("log");

const tui = @import("../../tui.zig");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub fn name(self: *Type) []const u8 {
    var suffix: []const u8 = "";
    if ((self.ctx.args.match(.{tp.extract(&suffix)}) catch false)) {
        return suffix;
    }
    return "󰅪 match";
}

pub fn process_egc(self: *Type, egc: []const u8) command.Result {
    var action: []const u8 = "";
    if ((self.ctx.args.match(.{tp.extract(&action)}) catch false)) {
        try command.executeName(action, command.fmt(.{egc}));
    } else {
        try command.executeName("match_brackets", .{});
    }
    try command.executeName("exit_mini_mode", .{});
}
