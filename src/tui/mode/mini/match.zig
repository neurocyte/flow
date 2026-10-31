const std = @import("std");
const cbor = @import("cbor");
const command = @import("command");
const tp = @import("thespian");
const log = @import("log");

const tui = @import("../../tui.zig");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub fn keybind_mode(self: *Type) []const u8 {
    return if (self.ctx.args.match(.{tp.string}) catch false) "mini/match_object" else "mini/get_char";
}

pub fn name(self: *Type) []const u8 {
    var suffix: []const u8 = "";
    if ((self.ctx.args.match(.{tp.extract(&suffix)}) catch false)) {
        return suffix;
    }
    return "󰅪 match";
}

pub fn process_egc(self: *Type, egc: []const u8) command.Result {
    var action: []const u8 = "";
    const result = if ((self.ctx.args.match(.{tp.extract(&action)}) catch false))
        command.executeName(action, command.fmt(.{egc}))
    else {};
    try command.executeName("exit_mini_mode", .empty());
    return result;
}
