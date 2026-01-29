const std = @import("std");
const file_type_config = @import("file_type_config");
const text_manip = @import("text_manip");
const write_string = text_manip.write_string;
const write_padding = text_manip.write_padding;
const builtin = @import("builtin");
const RGB = @import("color").RGB;

const bin_path = @import("bin_path");

const checkmark_width = if (builtin.os.tag != .windows) 2 else 3;

const success_mark = if (builtin.os.tag != .windows) "✓ " else "[y]";
const fail_mark = if (builtin.os.tag != .windows) "✘ " else "[n]";

pub fn list(allocator: std.mem.Allocator, writer: *std.io.Writer, tty_config: std.io.tty.Config) !void {
    var max_language_len: usize = 0;
    var max_langserver_len: usize = 0;
    var max_formatter_len: usize = 0;
    var max_extensions_len: usize = 0;

    for (file_type_config.get_all_names()) |file_type_name| {
        const file_type = try file_type_config.get(file_type_name) orelse unreachable;
        max_language_len = @max(max_language_len, file_type.name.len);
        max_langserver_len = @max(max_langserver_len, args_string_length(file_type.language_server));
        max_formatter_len = @max(max_formatter_len, args_string_length(file_type.formatter));
        max_extensions_len = @max(max_extensions_len, args_string_length(file_type.extensions));
    }

    try tty_config.setColor(writer, .yellow);
    try write_string(writer, "    Language", max_language_len + 1 + 4);
    try write_string(writer, "Extensions", max_extensions_len + 1 + checkmark_width);
    try write_string(writer, "Language Server", max_langserver_len + 1 + checkmark_width);
    try write_string(writer, "Formatter", null);
    try tty_config.setColor(writer, .reset);
    try writer.writeAll("\n");

    for (file_type_config.get_all_names()) |file_type_name| {
        const file_type = try file_type_config.get(file_type_name) orelse unreachable;
        try writer.writeAll(" ");
        try setColorRgb(writer, file_type.color orelse file_type_config.default.color);
        try writer.writeAll(file_type.icon orelse file_type_config.default.icon);
        try tty_config.setColor(writer, .reset);
        try writer.writeAll("  ");
        try write_string(writer, file_type.name, max_language_len + 1);
        try write_segmented(writer, file_type.extensions, ",", max_extensions_len + 1, tty_config);

        if (file_type.language_server) |language_server|
            try write_checkmark(writer, bin_path.can_execute(allocator, language_server[0]), tty_config);

        try write_segmented(writer, file_type.language_server, " ", max_langserver_len + 1, tty_config);

        if (file_type.formatter) |formatter|
            try write_checkmark(writer, bin_path.can_execute(allocator, formatter[0]), tty_config);

        try write_segmented(writer, file_type.formatter, " ", null, tty_config);
        try writer.writeAll("\n");
    }
}

fn args_string_length(args_: ?[]const []const u8) usize {
    const args = args_ orelse return 0;
    var len: usize = 0;
    var first: bool = true;
    for (args) |arg| {
        if (first) first = false else len += 1;
        len += arg.len;
    }
    return len;
}

fn write_checkmark(writer: anytype, success: bool, tty_config: std.io.tty.Config) !void {
    try tty_config.setColor(writer, if (success) .green else .red);
    if (success) try writer.writeAll(success_mark) else try writer.writeAll(fail_mark);
}

fn write_segmented(
    writer: anytype,
    args_: ?[]const []const u8,
    sep: []const u8,
    pad: ?usize,
    tty_config: std.io.tty.Config,
) !void {
    const args = args_ orelse return;
    var len: usize = 0;
    var first: bool = true;
    for (args) |arg| {
        if (first) first = false else {
            len += 1;
            try writer.writeAll(sep);
        }
        len += arg.len;
        try writer.writeAll(arg);
    }
    try tty_config.setColor(writer, .reset);
    if (pad) |pad_| try write_padding(writer, len, pad_);
}

fn setColorRgb(writer: anytype, color: u24) !void {
    const fg_rgb_legacy = "\x1b[38;2;{d};{d};{d}m";
    const rgb = RGB.from_u24(color);
    try writer.print(fg_rgb_legacy, .{ rgb.r, rgb.g, rgb.b });
}
