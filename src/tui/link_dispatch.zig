const std = @import("std");
const tp = @import("thespian");
const build_options = @import("build_options");

const tui = @import("tui.zig");

pub const Renderer = enum { tui, gui };

pub const renderer: Renderer = if (build_options.gui) .gui else .tui;

pub const Context = struct {
    base_dir: []const u8 = "",
    renderer: Renderer = renderer,
};

pub const Target = struct {
    path: []const u8,
    line: ?usize = null,
    column: ?usize = null,
    anchor: ?[]const u8 = null,
};

pub const Action = union(enum) {
    url: []const u8,
    markdown: Target,
    file: Target,
    anchor: []const u8,
};

pub fn classify(allocator: std.mem.Allocator, href: []const u8, ctx: Context) error{OutOfMemory}!Action {
    if (href.len > 0 and href[0] == '#') return .{ .anchor = href[1..] };
    var path = href;
    if (scheme(href)) |s| {
        if (!std.ascii.eqlIgnoreCase(s, "file")) return .{ .url = href };
        path = file_uri_path(href);
    }
    var target: Target = .{ .path = "" };
    if (std.mem.indexOfScalar(u8, path, '#')) |i| {
        const fragment = path[i + 1 ..];
        path = path[0..i];
        if (fragment_line(fragment)) |line| target.line = line else if (fragment.len > 0) target.anchor = fragment;
    } else if (suffix_location(path)) |split| {
        path = split.path;
        target.line = split.line;
        target.column = split.column;
    }
    const decoded = std.Uri.percentDecodeInPlace(try allocator.dupe(u8, path));
    target.path = if (std.fs.path.isAbsolute(decoded) or ctx.base_dir.len == 0)
        try std.fs.path.resolveAlloc(allocator, &.{decoded})
    else
        try std.fs.path.resolveAlloc(allocator, &.{ ctx.base_dir, decoded });
    return if (is_markdown(target.path)) .{ .markdown = target } else .{ .file = target };
}

pub fn terminal_link(href: []const u8, renderer_: Renderer) bool {
    if (renderer_ != .tui) return false;
    return starts_with_ignore_case(href, "http://") or starts_with_ignore_case(href, "https://");
}

pub const Click = enum { normal, alternate };

pub fn dispatch(action: Action, click: Click) void {
    switch (action) {
        .url => |url| tui.open_url(url),
        .file => |target| navigate(target) catch |e| std.log.err("link navigate failed: {t}", .{e}),
        .markdown => |target| switch (click) {
            .normal => preview(target) catch |e| std.log.err("link preview failed: {t}", .{e}),
            .alternate => if (target.anchor) |anchor|
                tp.self_pid().send(.{ "cmd", "markdown_open_heading", .{ target.path, anchor } }) catch |e|
                    std.log.err("link navigate failed: {t}", .{e})
            else
                navigate(target) catch |e| std.log.err("link navigate failed: {t}", .{e}),
        },
        .anchor => {},
    }
}

fn preview(target: Target) !void {
    try tp.self_pid().send(.{ "cmd", "markdown_preview_open", .{ target.path, target.anchor orelse "", target.line orelse 0 } });
}

fn navigate(target: Target) !void {
    const line = target.line orelse
        return tp.self_pid().send(.{ "cmd", "navigate", .{ .file = target.path } });
    if (target.column) |column|
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = target.path, .line = line, .column = column } })
    else
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = target.path, .line = line } });
}

/// write an href for `path` at `line` and `column` that `classify` reads back
pub fn write_file_href(writer: *std.Io.Writer, path: []const u8, line: ?usize, column: ?usize) std.Io.Writer.Error!void {
    try std.Uri.Component.percentEncode(writer, path, is_href_path_char);
    if (line) |l| try writer.print(":{d}", .{l});
    if (line != null) if (column) |c| try writer.print(":{d}", .{c});
}

fn is_href_path_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '.' or c == '_' or c == '~';
}

fn scheme(href: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, href, ':') orelse return null;
    if (colon < 2 or !std.ascii.isAlphabetic(href[0])) return null;
    for (href[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    return href[0..colon];
}

fn file_uri_path(href: []const u8) []const u8 {
    const rest = href["file:".len..];
    if (!std.mem.startsWith(u8, rest, "//")) return rest;
    const after = rest[2..];
    return after[std.mem.indexOfScalar(u8, after, '/') orelse after.len ..];
}

/// `L10` or `L10-L20`
fn fragment_line(fragment: []const u8) ?usize {
    if (fragment.len < 2 or fragment[0] != 'L') return null;
    const end = std.mem.indexOfScalar(u8, fragment, '-') orelse fragment.len;
    return std.fmt.parseInt(usize, fragment[1..end], 10) catch null;
}

/// `path:10` or `path:10:5`
fn suffix_location(path: []const u8) ?struct { path: []const u8, line: usize, column: ?usize = null } {
    const last = suffix_number(path) orelse return null;
    if (suffix_number(last.path)) |first| return .{ .path = first.path, .line = first.number, .column = last.number };
    return .{ .path = last.path, .line = last.number };
}

fn suffix_number(path: []const u8) ?struct { path: []const u8, number: usize } {
    const colon = std.mem.lastIndexOfScalar(u8, path, ':') orelse return null;
    if (colon == 0) return null;
    const number = std.fmt.parseInt(usize, path[colon + 1 ..], 10) catch return null;
    return .{ .path = path[0..colon], .number = number };
}

fn is_markdown(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}

fn starts_with_ignore_case(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}
