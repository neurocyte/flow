const std = @import("std");
const input = @import("input");

event: input.Event = input.event.press,
key: input.Key = 0,
modifiers: input.Mods = 0,

pub fn eql(self: @This(), other: @This()) bool {
    return std.meta.eql(self, other);
}

pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print("{}:{}{}", .{ input.event_fmt(self.event), input.mod_fmt(self.modifiers), input.key_fmt(self.key) });
}
