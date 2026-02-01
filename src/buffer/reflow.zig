pub fn reflow(allocator: std.mem.Allocator, text: []const u8, width: usize) error{ OutOfMemory, WriteFailed }![]u8 {
    const prefix = detect_prefix(text);
    const words = try split_words(allocator, text, prefix.len);
    defer allocator.free(words);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;

    var first = true;
    var line_len: usize = 0;
    for (words) |word| {
        const state: enum {
            begin,
            words,
        } = if (line_len == 0) .begin else .words;
        blk: switch (state) {
            .begin => {
                if (first) {
                    try writer.writeAll(prefix.first);
                    first = false;
                } else {
                    try writer.writeAll(prefix.continuation);
                    var pad = prefix.first.len - prefix.continuation.len;
                    while (pad > 0) : (pad -= 1)
                        try writer.writeByte(' ');
                }
                line_len += prefix.len;
                continue :blk .words;
            },
            .words => {
                if (line_len + word.len + 1 >= width - 1) {
                    try writer.writeByte('\n');
                    line_len = 0;
                    continue :blk .begin;
                }
                if (line_len > prefix.len)
                    try writer.writeByte(' ');
                try writer.writeAll(word);
                line_len += word.len;
            },
        }
    }

    return output.toOwnedSlice();
}

fn split_words(allocator: std.mem.Allocator, text: []const u8, prefix: usize) error{OutOfMemory}![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len <= prefix) continue;
        var it = std.mem.splitAny(u8, line[prefix..], " \t");
        while (it.next()) |word| if (word.len > 0) {
            (try words.addOne(allocator)).* = word;
        };
    }
    return words.toOwnedSlice(allocator);
}

fn detect_prefix(text: []const u8) Prefix {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const line1 = lines.next() orelse return .{};
    var prefix: []const u8 = line1;
    while (lines.next()) |line|
        prefix = lcp(prefix, line);

    if (line1.len > prefix.len + 2 and line1[prefix.len] == '-' and line1[prefix.len + 1] == ' ') {
        const first = line1[0 .. prefix.len + 2];
        return .{
            .len = first.len,
            .first = first,
            .continuation = prefix,
        };
    }

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
};

fn lcp(a: []const u8, b: []const u8) []const u8 {
    const len = @min(a.len, b.len);
    for (0..len) |i| if (a[i] != b[i])
        return a[0..i];
    return a[0..len];
}

const std = @import("std");
