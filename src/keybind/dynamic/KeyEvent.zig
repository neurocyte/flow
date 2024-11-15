const std = @import("std");
const input = @import("input");

key: input.Key = 0,
event: input.Event = input.event.press,
modifiers: input.Mods = 0,

pub fn eql(self: @This(), other: @This()) bool {
    return std.meta.eql(self, other);
}

pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    if (self.event == input.event.press) try writer.writeAll("press ");
    if (self.event == input.event.repeat) try writer.writeAll("repeat ");
    if (self.event == input.event.release) try writer.writeAll("release ");
    const mods: input.ModSet = @bitCast(self.modifiers);
    if (mods.super) try writer.writeAll("super+");
    if (mods.ctrl) try writer.writeAll("ctrl+");
    if (mods.alt) try writer.writeAll("alt+");
    if (mods.shift) try writer.writeAll("shift+");
    var key_string = input.utils.key_id_string(self.key);
    var buf: [6]u8 = undefined;
    if (key_string.len == 0) {
        const bytes = try input.ucs32_to_utf8(&[_]u32{self.key}, &buf);
        key_string = buf[0..bytes];
    }
    try writer.writeAll(key_string);
}
