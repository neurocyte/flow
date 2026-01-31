pub fn reflow(allocator: std.mem.Allocator, text: []const u8, width: usize) error{ OutOfMemory, WriteFailed }![]u8 {
    const prefix = detect_prefix(text);
    const words = try split_words(allocator, text, prefix.len);
    defer allocator.free(words);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;

    var line_len: usize = 0;
    for (words) |word| {
        if (line_len == 0) {
            try writer.writeAll(prefix);
            line_len += prefix.len;
        }
        if (line_len > prefix.len)
            try writer.writeByte(' ');
        try writer.writeAll(word);
        line_len += word.len;
        if (line_len >= width) {
            try writer.writeByte('\n');
            line_len = 0;
        }
    }

    return output.toOwnedSlice();
}

fn split_words(allocator: std.mem.Allocator, text: []const u8, prefix: usize) error{OutOfMemory}![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitAny(u8, line[prefix..], " \t");
        while (it.next()) |word| if (word.len > 0) {
            (try words.addOne(allocator)).* = word;
        };
    }
    return words.toOwnedSlice(allocator);
}

fn detect_prefix(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const line1 = lines.next() orelse return &.{};
    var prefix: []const u8 = line1;
    while (lines.next()) |line|
        prefix = lcp(prefix, line);
    return prefix;
}

fn lcp(a: []const u8, b: []const u8) []const u8 {
    const len = @min(a.len, b.len);
    for (0..len) |i| if (a[i] != b[i])
        return a[0..i];
    return a[0..len];
}

const std = @import("std");
