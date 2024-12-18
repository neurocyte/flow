pub fn control_code_to_unicode(code: u8) [:0]const u8 {
    return switch (code) {
        '\x00' => "␀",
        '\x01' => "␁",
        '\x02' => "␂",
        '\x03' => "␃",
        '\x04' => "␄",
        '\x05' => "␅",
        '\x06' => "␆",
        '\x07' => "␇",
        '\x08' => "␈",
        '\x09' => "␉",
        '\x0A' => "␊",
        '\x0B' => "␋",
        '\x0C' => "␌",
        '\x0D' => "␍",
        '\x0E' => "␎",
        '\x0F' => "␏",
        '\x10' => "␐",
        '\x11' => "␑",
        '\x12' => "␒",
        '\x13' => "␓",
        '\x14' => "␔",
        '\x15' => "␕",
        '\x16' => "␖",
        '\x17' => "␗",
        '\x18' => "␘",
        '\x19' => "␙",
        '\x1A' => "␚",
        '\x1B' => "␛",
        '\x1C' => "␜",
        '\x1D' => "␝",
        '\x1E' => "␞",
        '\x1F' => "␟",
        '\x20' => "␠",
        '\x7F' => "␡",
        else => "",
    };
}

fn raw_byte_to_utf8(cp: u8, buf: []u8) ![]const u8 {
    var utf16le: [1]u16 = undefined;
    const utf16le_as_bytes = std.mem.sliceAsBytes(utf16le[0..]);
    std.mem.writeInt(u16, utf16le_as_bytes[0..2], cp, .little);
    return buf[0..try std.unicode.utf16LeToUtf8(buf, &utf16le)];
}

const std = @import("std");

pub fn utf8_sanitize(allocator: std.mem.Allocator, input: []const u8) error{
    OutOfMemory,
    DanglingSurrogateHalf,
    ExpectedSecondSurrogateHalf,
    UnexpectedSecondSurrogateHalf,
}![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .{};
    const writer = output.writer(allocator);
    var buf: [4]u8 = undefined;
    for (input) |byte| try writer.writeAll(try raw_byte_to_utf8(byte, &buf));
    return output.toOwnedSlice(allocator);
}
