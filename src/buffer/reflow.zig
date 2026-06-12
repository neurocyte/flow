pub fn reflow(allocator: std.mem.Allocator, text: []const u8, width: usize) error{ OutOfMemory, WriteFailed }![]u8 {
    const len = text.len;
    const trailing_ln: bool = (len > 0 and text[len - 1] == '\n');
    const input = if (trailing_ln) text[0 .. len - 1] else text;
    const prefix = detect_prefix(input);
    const words = try split_words(allocator, input, prefix);
    defer allocator.free(words);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;

    var item_start = true;
    var line_len: usize = 0;
    for (words) |word| {
        if (word.ptr == item_break.ptr) {
            if (line_len != 0) try writer.writeByte('\n');
            line_len = 0;
            item_start = true;
            continue;
        }
        const state: enum {
            begin,
            words,
        } = if (line_len == 0) .begin else .words;
        blk: switch (state) {
            .begin => {
                if (item_start) {
                    try writer.writeAll(prefix.first);
                    line_len += prefix.first.len;
                    item_start = false;
                } else {
                    try writer.writeAll(prefix.continuation);
                    line_len += prefix.continuation.len;
                    var pad = prefix.first.len - prefix.continuation.len;
                    while (pad > 0) : (pad -= 1) {
                        try writer.writeByte(' ');
                        line_len += 1;
                    }
                }
                continue :blk .words;
            },
            .words => {
                if (word.len == 1 and word[0] == '\n') {
                    try writer.writeByte('\n');
                    try writer.writeByte('\n');
                    line_len = 0;
                    continue;
                }
                if (line_len > prefix.len) {
                    if (line_len + word.len + 1 >= width) {
                        try writer.writeByte('\n');
                        line_len = 0;
                        continue :blk .begin;
                    }
                    try writer.writeByte(' ');
                    line_len += 1;
                }
                try writer.writeAll(word);
                line_len += word.len;
            },
        }
    }
    if (trailing_ln) try writer.writeByte('\n');
    return output.toOwnedSlice();
}

// matched by pointer identity, never by content
const item_break: []const u8 = "\x1e"; // RS (Record Separator control char)

fn split_words(allocator: std.mem.Allocator, text: []const u8, prefix: Prefix) error{OutOfMemory}![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var blank = false;
    while (lines.next()) |line| {
        const content = if (prefix.bullet) bullet_content(line) else blk: {
            if (line.len <= prefix.len) break :blk null;
            break :blk Content{ .item = false, .text = line[prefix.len..] };
        };
        const c = content orelse {
            if (!blank)
                (try words.addOne(allocator)).* = "\n";
            blank = true;
            continue;
        };
        blank = false;
        if (c.item)
            (try words.addOne(allocator)).* = item_break;
        var it = std.mem.splitAny(u8, c.text, " \t");
        while (it.next()) |word| if (word.len > 0) {
            (try words.addOne(allocator)).* = word;
        };
    }
    return words.toOwnedSlice(allocator);
}

const Content = struct { item: bool, text: []const u8 };

fn bullet_content(line: []const u8) ?Content {
    const indent = whitespace_len(line);
    if (indent == line.len) return null;
    if (line.len >= indent + 2 and line[indent] == '-' and line[indent + 1] == ' ')
        return .{ .item = true, .text = line[indent + 2 ..] };
    return .{ .item = false, .text = line[indent..] };
}

fn whitespace_len(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn detect_prefix(text: []const u8) Prefix {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const line1 = lines.next() orelse return .{};

    const indent = whitespace_len(line1);
    if (line1.len >= indent + 2 and line1[indent] == '-' and line1[indent + 1] == ' ')
        return .{
            .len = indent + 2,
            .first = line1[0 .. indent + 2],
            .continuation = line1[0..indent],
            .bullet = true,
        };

    var prefix: []const u8 = line1;
    var count: usize = 0;
    while (lines.next()) |line| if (line.len > 0) {
        prefix = lcp(prefix, line);
        count += 1;
    };
    if (count < 1) {
        prefix = prefix[0..prefix_len(prefix, .alnum)];
        return .{
            .len = prefix.len,
            .first = prefix,
            .continuation = prefix,
        };
    }
    prefix = prefix[0..prefix_len(prefix, .alpha)];

    return .{
        .len = prefix.len,
        .first = prefix,
        .continuation = prefix,
    };
}

const Prefix = struct {
    len: usize = 0,
    first: []const u8 = &.{},
    continuation: []const u8 = &.{},
    bullet: bool = false,
};

fn lcp(a: []const u8, b: []const u8) []const u8 {
    const len = @min(a.len, b.len);
    for (0..len) |i| if (a[i] != b[i])
        return a[0..i];
    return a[0..len];
}

const Stop = enum { alpha, alnum };

fn prefix_len(text: []const u8, comptime stop: Stop) usize {
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return i;
        if (i + n > text.len) return i;
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return i;
        if (is_alpha(cp)) return i;
        if (stop == .alnum and is_number(cp)) return i;
        i += n;
    }
    return i;
}

fn is_alpha(cp: u21) bool {
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase,
        .letter_lowercase,
        .letter_titlecase,
        .letter_modifier,
        .letter_other,
        => true,
        else => false,
    };
}

fn is_number(cp: u21) bool {
    return switch (uucode.get(.general_category, cp)) {
        .number_decimal_digit,
        .number_letter,
        .number_other,
        => true,
        else => false,
    };
}

const std = @import("std");
const uucode = @import("vaxis").uucode;
