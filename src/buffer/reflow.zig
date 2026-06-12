pub const WidthMethod = enum { screen, unicode };
pub const IndentStyle = enum { spaces, tabs };

pub fn reflow(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    width_method: WidthMethod,
    indent: IndentStyle,
    metrics: Metrics,
) error{ OutOfMemory, WriteFailed }![]u8 {
    const len = text.len;
    const trailing_ln: bool = (len > 0 and text[len - 1] == '\n');
    const input = if (trailing_ln) text[0 .. len - 1] else text;
    const prefix = detect_prefix(input);
    const tokens = try split_words(allocator, input, prefix);
    defer allocator.free(tokens);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;

    var cur = prefix;
    var item_start = true;
    var line_has_word = false;
    var line_len: usize = 0;
    for (tokens) |token| switch (token) {
        .item => |item_prefix| {
            if (line_len != 0) try writer.writeByte('\n');
            line_len = 0;
            line_has_word = false;
            cur = item_prefix;
            item_start = true;
        },
        .paragraph => {
            try writer.writeByte('\n');
            try writer.writeByte('\n');
            line_len = 0;
            line_has_word = false;
        },
        .word => |word| {
            const state: enum { begin, words } = if (line_len == 0) .begin else .words;
            blk: switch (state) {
                .begin => {
                    const indent_cols = indent_width(cur.indent, metrics.tab_width);
                    try emit_indent(writer, indent_cols, indent, metrics.tab_width);
                    line_len += indent_cols;
                    const content_width = measure(cur.content, line_len, width_method, metrics);
                    if (item_start or !cur.bullet) {
                        try writer.writeAll(cur.content);
                    } else {
                        var pad = content_width;
                        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
                    }
                    line_len += content_width;
                    item_start = false;
                    line_has_word = false;
                    continue :blk .words;
                },
                .words => {
                    const word_width = measure(word, line_len, width_method, metrics);
                    if (line_has_word) {
                        if (line_len + word_width + 1 >= width) {
                            try writer.writeByte('\n');
                            line_len = 0;
                            continue :blk .begin;
                        }
                        try writer.writeByte(' ');
                        line_len += 1;
                    }
                    try writer.writeAll(word);
                    line_len += word_width;
                    line_has_word = true;
                },
            }
        },
    };
    if (trailing_ln) try writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn measure(text: []const u8, abs_col: usize, width_method: WidthMethod, metrics: Metrics) usize {
    return switch (width_method) {
        .screen => metrics.egc_chunk_width(metrics, text, abs_col),
        .unicode => gwidth.gwidth(text, .unicode),
    };
}

fn emit_indent(writer: *std.Io.Writer, cols: usize, indent: IndentStyle, tab_width: usize) error{WriteFailed}!void {
    var w = cols;
    if (indent == .tabs and tab_width > 0) while (w >= tab_width) : (w -= tab_width)
        try writer.writeByte('\t');
    while (w > 0) : (w -= 1)
        try writer.writeByte(' ');
}

const Token = union(enum) {
    word: []const u8,
    paragraph,
    item: Prefix,
};

fn split_words(allocator: std.mem.Allocator, text: []const u8, prefix: Prefix) error{OutOfMemory}![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var blank = false;
    while (lines.next()) |line| {
        const rest: []const u8 = if (prefix.bullet) blk: {
            const indent = whitespace_len(line);
            if (indent == line.len) break :blk &.{};
            if (bullet_marker(line, indent)) |marker_len| {
                (try tokens.addOne(allocator)).* = .{ .item = .{
                    .indent = line[0..indent],
                    .content = line[indent .. indent + marker_len],
                    .bullet = true,
                } };
                break :blk line[indent + marker_len ..];
            }
            break :blk line[indent..];
        } else if (line.len > prefix.len) line[prefix.len..] else &.{};
        if (rest.len == 0) {
            if (!blank) (try tokens.addOne(allocator)).* = .paragraph;
            blank = true;
            continue;
        }
        blank = false;
        var it = std.mem.splitAny(u8, rest, " \t");
        while (it.next()) |word| if (word.len > 0) {
            (try tokens.addOne(allocator)).* = .{ .word = word };
        };
    }
    return tokens.toOwnedSlice(allocator);
}

fn whitespace_len(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

const unicode_bullets = [_][]const u8{ "•", "◦", "‣", "⁃", "▪", "▸", "●", "○" };

fn bullet_marker(line: []const u8, indent: usize) ?usize {
    const rest = line[indent..];
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        if (rest[0] == '-' and rest.len >= 6 and rest[2] == '[' and
            (rest[3] == ' ' or rest[3] == 'x' or rest[3] == 'X') and
            rest[4] == ']' and rest[5] == ' ')
            return 6;
        return 2;
    }
    for (unicode_bullets) |bullet|
        if (rest.len > bullet.len and std.mem.startsWith(u8, rest, bullet) and rest[bullet.len] == ' ')
            return bullet.len + 1;
    return null;
}

fn detect_prefix(text: []const u8) Prefix {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const line1 = lines.next() orelse return .{};

    const indent = whitespace_len(line1);
    if (bullet_marker(line1, indent)) |_|
        return .{ .bullet = true };

    var prefix: []const u8 = line1;
    var count: usize = 0;
    while (lines.next()) |line| if (line.len > 0) {
        prefix = lcp(prefix, line);
        count += 1;
    };
    if (count < 1)
        return make_prefix(prefix[0..prefix_len(prefix, .alnum)]);
    return make_prefix(prefix[0..prefix_len(prefix, .alpha)]);
}

fn make_prefix(prefix: []const u8) Prefix {
    const indent = whitespace_len(prefix);
    return .{
        .indent = prefix[0..indent],
        .content = prefix[indent..],
        .len = prefix.len,
    };
}

const Prefix = struct {
    indent: []const u8 = &.{},
    content: []const u8 = &.{},
    len: usize = 0,
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

fn indent_width(text: []const u8, tab_width: usize) usize {
    var col: usize = 0;
    var run: usize = 0;
    for (text, 0..) |c, i| if (c == '\t') {
        if (i > run) col += gwidth.gwidth(text[run..i], .unicode);
        col += if (tab_width == 0) 0 else tab_width - (col % tab_width);
        run = i + 1;
    };
    if (text.len > run) col += gwidth.gwidth(text[run..], .unicode);
    return col;
}

const std = @import("std");
const Buffer = @import("Buffer.zig");
const Metrics = Buffer.Metrics;
const uucode = @import("vaxis").uucode;
const gwidth = @import("vaxis").gwidth;
