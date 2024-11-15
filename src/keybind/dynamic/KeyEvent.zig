const std = @import("std");
const input = @import("input");

key: input.Key = 0,
event: input.Event = input.event.press,
modifiers: input.Mods = 0,

pub fn eql(self: @This(), other: @This()) bool {
    return std.meta.eql(self, other);
}
