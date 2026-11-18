const std = @import("std");

/// the old and the new side of a hunk header `@@ -old_start,old_count +new_start,new_count @@`
pub const Range = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

pub fn parse_header(header: []const u8) ?Range {
    if (!std.mem.startsWith(u8, header, "@@ -")) return null;
    var pos: usize = 4;
    const old_start, const old_count = parse_side(header, &pos) orelse return null;
    if (!std.mem.startsWith(u8, header[pos..], " +")) return null;
    pos += 2;
    const new_start, const new_count = parse_side(header, &pos) orelse return null;
    return .{ .old_start = old_start, .old_count = old_count, .new_start = new_start, .new_count = new_count };
}

fn parse_side(header: []const u8, pos: *usize) ?struct { usize, usize } {
    const start = parse_number(header, pos) orelse return null;
    if (pos.* >= header.len or header[pos.*] != ',') return .{ start, 1 };
    pos.* += 1;
    return .{ start, parse_number(header, pos) orelse return null };
}

fn parse_number(text: []const u8, pos: *usize) ?usize {
    const begin = pos.*;
    while (pos.* < text.len and std.ascii.isDigit(text[pos.*])) pos.* += 1;
    return std.fmt.parseInt(usize, text[begin..pos.*], 10) catch null;
}

/// the number of lines between a line and the new side of a hunk, 0 if the hunk contains it
pub fn distance(header: []const u8, line: usize) usize {
    const range = parse_header(header) orelse return std.math.maxInt(usize);
    const end = range.new_start + @max(range.new_count, 1);
    return if (line < range.new_start) range.new_start - line else if (line >= end) line - end + 1 else 0;
}

/// the hunk headers of a diff, in the order of the diff
pub fn parse_headers(allocator: std.mem.Allocator, diff: []const u8) error{OutOfMemory}![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(allocator);
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| if (parse_header(line)) |range| {
        (try ranges.addOne(allocator)).* = range;
    };
    return ranges.toOwnedSlice(allocator);
}

/// The line of the new side of `ranges` that shows a line of the old side.
/// `ranges` are the hunks of a diff without context lines. A line that the
/// diff changed maps to the first new line of its hunk.
pub fn map_line(ranges: []const Range, line: usize) usize {
    var new_line = line;
    for (ranges) |range| {
        if (range.old_count == 0) {
            if (range.old_start < line) new_line += range.new_count;
            continue;
        }
        if (line < range.old_start) break;
        if (line < range.old_start + range.old_count)
            return if (range.new_count == 0) range.new_start + 1 else range.new_start;
        new_line = new_line + range.new_count - range.old_count;
    }
    return new_line;
}
