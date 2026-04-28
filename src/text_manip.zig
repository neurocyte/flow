const std = @import("std");
const TextWriter = *std.Io.Writer;

pub fn find_first_non_ws(text: []const u8) ?usize {
    for (text, 0..) |c, i| if (c == ' ' or c == '\t') continue else return i;
    return null;
}

pub fn find_prefix(prefix: []const u8, text: []const u8) ?usize {
    var start: usize = 0;
    var pos: usize = 0;
    var in_prefix: bool = false;
    for (text, 0..) |c, i| {
        if (!in_prefix) {
            if (c == ' ' or c == '\t')
                continue
            else {
                in_prefix = true;
                start = i;
            }
        }

        if (in_prefix) {
            if (c == prefix[pos]) {
                pos += 1;
                if (prefix.len > pos) continue else return start;
            } else return null;
        }
    }
    return null;
}

fn add_prefix_in_line(prefix: []const u8, text: []const u8, writer: TextWriter, pos: usize) !void {
    if (text.len >= pos and find_first_non_ws(text) != null) {
        try writer.writeAll(text[0..pos]);
        try writer.writeAll(prefix);
        try writer.writeAll(" ");
        try writer.writeAll(text[pos..]);
    } else {
        try writer.writeAll(text);
    }
}

fn remove_prefix_in_line(prefix: []const u8, text: []const u8, writer: TextWriter) !void {
    if (find_prefix(prefix, text)) |pos| {
        try writer.writeAll(text[0..pos]);
        if (text.len > pos + prefix.len) {
            _ = try if (text[pos + prefix.len] == ' ')
                writer.write(text[pos + 1 + prefix.len ..])
            else
                writer.write(text[pos + prefix.len ..]);
        }
    } else {
        try writer.writeAll(text);
    }
}

pub fn toggle_prefix_in_text(prefix: []const u8, text: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    const writer = &result.writer;
    var pos: usize = 0;
    var prefix_pos: usize = std.math.maxInt(usize);
    var have_prefix = true;
    while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |next| {
        if (find_prefix(prefix, text[pos..next])) |_| {} else {
            if (find_first_non_ws(text[pos..next])) |_| {
                have_prefix = false;
                break;
            }
        }
        pos = next + 1;
    }
    pos = 0;
    if (!have_prefix)
        while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |next| {
            if (find_first_non_ws(text[pos..next])) |prefix_pos_|
                prefix_pos = @min(prefix_pos, prefix_pos_);
            pos = next + 1;
        };
    pos = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |next| {
        if (have_prefix) {
            try remove_prefix_in_line(prefix, text[pos..next], writer);
        } else {
            try add_prefix_in_line(prefix, text[pos..next], writer, prefix_pos);
        }
        try writer.writeAll("\n");
        pos = next + 1;
    }
    return result.toOwnedSlice();
}

pub fn write_string(writer: *std.Io.Writer, string: []const u8, pad: ?usize) !void {
    try writer.writeAll(string);
    if (pad) |pad_| try write_padding(writer, string.len, pad_);
}

pub fn write_padding(writer: *std.Io.Writer, len: usize, pad_len: usize) !void {
    for (0..pad_len - len) |_| try writer.writeAll(" ");
}
