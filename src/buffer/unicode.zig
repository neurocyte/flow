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
    return buf[0..try utf16LeToUtf8(buf, &utf16le)];
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
    OutOfMemory,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    WriteFailed,
};

fn utf8_write_transform(comptime field: uucode.FieldEnum, writer: *std.Io.Writer, text: []const u8) TransformError!void {
    const view: Utf8View = .initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_ = switch (field) {
            .simple_uppercase_mapping, .simple_lowercase_mapping => uucode.get(field, cp) orelse cp,
            .case_folding_simple => uucode.get(field, cp),
            else => @compileError(@tagName(field) ++ " is not a unicode transformation"),
        };
        var utf8_buf: [6]u8 = undefined;
        const size = try utf8Encode(cp_, &utf8_buf);
        try writer.writeAll(utf8_buf[0..size]);
    }
}

fn utf8_partial_write_transform(comptime field: uucode.FieldEnum, writer: *std.Io.Writer, text: []const u8) TransformError![]const u8 {
    const view: Utf8PartialView = .initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_ = switch (field) {
            .simple_uppercase_mapping, .simple_lowercase_mapping => uucode.get(field, cp) orelse cp,
            .case_folding_simple => uucode.get(field, cp),
            else => @compileError(@tagName(field) ++ " is not a unicode transformation"),
        };
        var utf8_buf: [6]u8 = undefined;
        const size = try utf8Encode(cp_, &utf8_buf);
        try writer.writeAll(utf8_buf[0..size]);
    }
    return text[0..it.end];
}

fn utf8_transform(comptime field: uucode.FieldEnum, allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    try utf8_write_transform(field, &result.writer, text);
    return result.toOwnedSlice();
}

fn utf8_predicate(comptime field: uucode.FieldEnum, text: []const u8) bool {
    const view: Utf8View = .initUnchecked(text);
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

pub fn to_upper(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
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

pub fn case_folded_write_partial(writer: *std.Io.Writer, text: []const u8) TransformError![]const u8 {
    return utf8_partial_write_transform(.case_folding_simple, writer, text);
}

pub fn switch_case(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return if (utf8_predicate(.is_lowercase, text))
        to_upper(allocator, text)
    else
        to_lower(allocator, text);
}

pub fn is_lowercase(text: []const u8) bool {
    return utf8_predicate(.is_lowercase, text);
}

const std = @import("std");
const uucode = @import("vaxis").uucode;

const utf16LeToUtf8 = std.unicode.utf16LeToUtf8;
const utf8ByteSequenceLength = std.unicode.utf8ByteSequenceLength;
const utf8Decode = std.unicode.utf8Decode;
const utf8Encode = std.unicode.utf8Encode;
const Utf8View = std.unicode.Utf8View;

const Utf8PartialIterator = struct {
    bytes: []const u8,
    end: usize,

    fn nextCodepointSlice(it: *Utf8PartialIterator) ?[]const u8 {
        if (it.end >= it.bytes.len) {
            return null;
        }

        const cp_len = utf8ByteSequenceLength(it.bytes[it.end]) catch unreachable;
        if (it.end + cp_len > it.bytes.len) {
            return null;
        }
        it.end += cp_len;
        return it.bytes[it.end - cp_len .. it.end];
    }

    fn nextCodepoint(it: *Utf8PartialIterator) ?u21 {
        const slice = it.nextCodepointSlice() orelse return null;
        return utf8Decode(slice) catch unreachable;
    }
};

const Utf8PartialView = struct {
    bytes: []const u8,

    fn initUnchecked(s: []const u8) Utf8PartialView {
        return Utf8PartialView{ .bytes = s };
    }

    fn iterator(s: Utf8PartialView) Utf8PartialIterator {
        return Utf8PartialIterator{
            .bytes = s.bytes,
            .end = 0,
        };
    }
};
