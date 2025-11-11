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
    var prev: []const u8 = "";
    if ((self.ctx.args.match(.{tp.extract(&prev)}) catch false)) {
        if (std.mem.eql(u8, prev, "mi")) {
            command.executeName("select_textobject_inner", command.fmt(.{egc})) catch {
                try command.executeName("exit_mini_mode", .{});
            };
        } else if (std.mem.eql(u8, prev, "ma")) {
            command.executeName("select_textobject_around", command.fmt(.{egc})) catch {
                try command.executeName("exit_mini_mode", .{});
            };
        } else if (std.mem.eql(u8, prev, "md")) {
            command.executeName("surround_delete", command.fmt(.{egc})) catch {
                try command.executeName("exit_mini_mode", .{});
            };
        } else if (std.mem.eql(u8, prev, "mr")) {
            command.executeName("surround_replace", command.fmt(.{egc})) catch {
                try command.executeName("exit_mini_mode", .{});
            };
        } else if (std.mem.eql(u8, prev, "ms")) {
            command.executeName("surround_add", command.fmt(.{egc})) catch {
                try command.executeName("exit_mini_mode", .{});
            };
        }
        try command.executeName("exit_mini_mode", .{});
    } else {
        if (std.mem.eql(u8, egc, "i")) {
            try command.executeName("match", command.fmt(.{"mi"}));
        } else if (std.mem.eql(u8, egc, "a")) {
            try command.executeName("match", command.fmt(.{"ma"}));
        } else if (std.mem.eql(u8, egc, "d")) {
            try command.executeName("match", command.fmt(.{"md"}));
        } else if (std.mem.eql(u8, egc, "r")) {
            try command.executeName("match", command.fmt(.{"mr"}));
        } else if (std.mem.eql(u8, egc, "s")) {
            try command.executeName("match", command.fmt(.{"ms"}));
        } else if (std.mem.eql(u8, egc, "m")) {
            command.executeName("match_brackets", .{}) catch {
                try command.executeName("exit_mini_mode", .{});
            };
            try command.executeName("exit_mini_mode", .{});
        } else {
            try command.executeName("exit_mini_mode", .{});
        }
    }
}
