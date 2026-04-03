const std = @import("std");

/// Write a `[]const []const u8` argv array as a space-separated command string.
/// Args that contain spaces are wrapped in double-quotes.
/// Writes nothing if argv is null or empty.
pub fn write(writer: *std.Io.Writer, argv: ?[]const []const u8) error{WriteFailed}!usize {
    const args = argv orelse return 0;
    var count: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            try writer.writeByte(' ');
            count += 1;
        }
        const needs_quote = std.mem.indexOfScalar(u8, arg, ' ') != null;
        if (needs_quote) {
            try writer.writeByte('"');
            count += 1;
        }
        try writer.writeAll(arg);
        count += arg.len;
        if (needs_quote) {
            try writer.writeByte('"');
            count += 1;
        }
    }
    return count;
}

/// Return the display length of an argv array rendered by write_argv.
pub fn len(argv: ?[]const []const u8) usize {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    return write(&discard.writer, argv) catch return 0;
}
