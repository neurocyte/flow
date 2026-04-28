const std = @import("std");
const file_type_config = @import("file_type_config");
const text_manip = @import("text_manip");
const write_string = text_manip.write_string;
const write_padding = text_manip.write_padding;
const argv = @import("argv");
const builtin = @import("builtin");
const RGB = @import("color").RGB;

const bin_path = @import("bin_path");

const checkmark_width = if (builtin.os.tag != .windows) 2 else 3;

const success_mark = if (builtin.os.tag != .windows) "✓ " else "[y]";
const fail_mark = if (builtin.os.tag != .windows) "✘ " else "[n]";

pub fn list(allocator: std.mem.Allocator, tty: std.Io.Terminal) !void {
    var max_language_len: usize = 0;
    var max_langserver_len: usize = 0;
    var max_formatter_len: usize = 0;
    var max_extensions_len: usize = 0;

    for (file_type_config.get_all_names()) |file_type_name| {
        const file_type = try file_type_config.get(file_type_name) orelse unreachable;
        max_language_len = @max(max_language_len, file_type.name.len);
        max_langserver_len = @max(max_langserver_len, argv.len(file_type.language_server));
        max_formatter_len = @max(max_formatter_len, argv.len(file_type.formatter));
        max_extensions_len = @max(max_extensions_len, argv.len(file_type.extensions));
    }

    try tty.setColor(.yellow);
    try write_string(tty.writer, "    Language", max_language_len + 1 + 4);
    try write_string(tty.writer, "Extensions", max_extensions_len + 1 + checkmark_width);
    try write_string(tty.writer, "Language Server", max_langserver_len + 1 + checkmark_width);
    try write_string(tty.writer, "Formatter", null);
    try tty.setColor(.reset);
    try tty.writer.writeAll("\n");

    for (file_type_config.get_all_names()) |file_type_name| {
        const file_type = try file_type_config.get(file_type_name) orelse unreachable;
        try tty.writer.writeAll(" ");
        try setColorRgb(tty, file_type.color orelse file_type_config.default.color);
        try tty.writer.writeAll(file_type.icon orelse file_type_config.default.icon);
        try tty.setColor(.reset);
        try tty.writer.writeAll("  ");
        try write_string(tty.writer, file_type.name, max_language_len + 1);
        try write_segmented(tty, file_type.extensions, ",", max_extensions_len + 1);

        if (file_type.language_server) |language_server|
            try write_checkmark(tty, bin_path.can_execute(allocator, language_server[0]));

        try write_segmented(tty, file_type.language_server, " ", max_langserver_len + 1);

        if (file_type.formatter) |formatter|
            try write_checkmark(tty, bin_path.can_execute(allocator, formatter[0]));

        try write_segmented(tty, file_type.formatter, " ", null);
        try tty.writer.writeAll("\n");
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

fn write_checkmark(tty: std.Io.Terminal, success: bool) !void {
    try tty.setColor(if (success) .green else .red);
    if (success) try tty.writer.writeAll(success_mark) else try tty.writer.writeAll(fail_mark);
}

fn write_segmented(
    tty: std.Io.Terminal,
    args_: ?[]const []const u8,
    sep: []const u8,
    pad: ?usize,
) !void {
    const args = args_ orelse return;
    var len: usize = 0;
    var first: bool = true;
    for (args) |arg| {
        if (first) first = false else {
            len += 1;
            try tty.writer.writeAll(sep);
        }
        len += arg.len;
        try tty.writer.writeAll(arg);
    }
    try tty.setColor(.reset);
    if (pad) |pad_| try write_padding(tty.writer, len, pad_);
}

fn setColorRgb(tty: std.Io.Terminal, color: u24) !void {
    const fg_rgb_legacy = "\x1b[38;2;{d};{d};{d}m";
    const rgb = RGB.from_u24(color);
    try tty.writer.print(fg_rgb_legacy, .{ rgb.r, rgb.g, rgb.b });
}
