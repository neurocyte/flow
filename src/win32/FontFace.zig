const FontFace = @This();

const std = @import("std");

// it seems that Windows only supports font faces with up to 31 characters,
// but we use a larger buffer here because GetFamilyNames can apparently
// return longer strings
pub const max = 254;

buf: [max + 1]u16,
len: usize,

pub fn initUtf8(utf8: []const u8) error{ TooLong, InvalidUtf8 }!FontFace {
    const utf16_len = std.unicode.calcUtf16LeLen(utf8) catch return error.InvalidUtf8;
    if (utf16_len > max)
        return error.TooLong;
    var result: FontFace = .{ .buf = undefined, .len = @intCast(utf16_len) };
    result.buf[utf16_len] = 0;
    const actual_len = try std.unicode.utf8ToUtf16Le(&result.buf, utf8);
    std.debug.assert(actual_len == utf16_len);
    return result;
}

pub fn ptr(self: *const FontFace) [*:0]const u16 {
    std.debug.assert(self.buf[@as(usize, self.len)] == 0);
    return @ptrCast(&self.buf);
}
pub fn slice(self: *const FontFace) [:0]const u16 {
    return self.ptr()[0..self.len :0];
}
pub fn eql(self: *const FontFace, other: *const FontFace) bool {
    return std.mem.eql(u16, self.slice(), other.slice());
}
