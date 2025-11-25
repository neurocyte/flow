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

pub const char_pairs = [_]struct { []const u8, []const u8 }{
    .{ "\"", "\"" },
    .{ "'", "'" },
    .{ "`", "`" },
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
    .{ "‘", "’" },
    .{ "“", "”" },
    .{ "‚", "‘" },
    .{ "«", "»" },
    .{ "¿", "?" },
    .{ "¡", "!" },
};

pub const open_close_pairs = [_]struct { []const u8, []const u8 }{
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
    .{ "‘", "’" },
    .{ "“", "”" },
    .{ "«", "»" },
    .{ "¿", "?" },
    .{ "¡", "!" },
};

const spinner = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
};

const spinner_short = [_][]const u8{
    "⠋",
    "⠙",
    "⠸",
    "⠴",
    "⠦",
    "⠇",
};

fn raw_byte_to_utf8(cp: u8, buf: []u8) ![]const u8 {
    var utf16le: [1]u16 = undefined;
    const utf16le_as_bytes = std.mem.sliceAsBytes(utf16le[0..]);
    std.mem.writeInt(u16, utf16le_as_bytes[0..2], cp, .little);
    return buf[0..try std.unicode.utf16LeToUtf8(buf, &utf16le)];
}

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

pub const TransformError = error{
    InvalidUtf8,
    OutOfMemory,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    WriteFailed,
};

fn utf8_write_transform(comptime field: uucode.FieldEnum, writer: *std.Io.Writer, text: []const u8) TransformError!void {
    const view: std.unicode.Utf8View = try .init(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_ = switch (field) {
            .simple_uppercase_mapping, .simple_lowercase_mapping => uucode.get(field, cp) orelse cp,
            .case_folding_simple => uucode.get(field, cp),
            else => @compileError(@tagName(field) ++ " is not a unicode transformation"),
        };
        var utf8_buf: [6]u8 = undefined;
        const size = try std.unicode.utf8Encode(cp_, &utf8_buf);
        try writer.writeAll(utf8_buf[0..size]);
    }
}

fn utf8_transform(comptime field: uucode.FieldEnum, allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    try utf8_write_transform(field, &result.writer, text);
    return result.toOwnedSlice();
}

fn utf8_predicate(comptime field: uucode.FieldEnum, text: []const u8) error{InvalidUtf8}!bool {
    const view: std.unicode.Utf8View = try .init(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const result = switch (field) {
            .is_lowercase => uucode.get(field, cp),
            else => @compileError(@tagName(field) ++ " is not a unicode predicate"),
        };
        if (!result) return false;
    }
    return true;
}

pub fn to_upper(allocator: std.mem.Allocator, text: []const u8) error{
    InvalidUtf8,
    OutOfMemory,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    WriteFailed,
}![]u8 {
    return utf8_transform(.simple_uppercase_mapping, allocator, text);
}

pub fn to_lower(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return utf8_transform(.simple_lowercase_mapping, allocator, text);
}

pub fn case_fold(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return utf8_transform(.case_folding_simple, allocator, text);
}

pub fn case_folded_write(writer: *std.Io.Writer, text: []const u8) TransformError!void {
    return utf8_write_transform(.case_folding_simple, writer, text);
}

pub fn switch_case(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return if (try utf8_predicate(.is_lowercase, text))
        to_upper(allocator, text)
    else
        to_lower(allocator, text);
}

pub fn is_lowercase(text: []const u8) error{InvalidUtf8}!bool {
    return try utf8_predicate(.is_lowercase, text);
}

const std = @import("std");
const uucode = @import("vaxis").uucode;
