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
    var self: FontFace = .{ .buf = undefined, .len = utf16_len };
    const actual_len = try std.unicode.utf8ToUtf16Le(&self.buf, utf8);
    std.debug.assert(actual_len == utf16_len);
    self.buf[actual_len] = 0;
    return self;
}

pub fn ptr(self: *const FontFace) [*:0]const u16 {
    return self.slice().ptr;
}
pub fn slice(self: *const FontFace) [:0]const u16 {
    std.debug.assert(self.buf[self.len] == 0);
    return self.buf[0..self.len :0];
}
pub fn eql(self: *const FontFace, other: *const FontFace) bool {
    return std.mem.eql(u16, self.slice(), other.slice());
}
