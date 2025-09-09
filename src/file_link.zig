const std = @import("std");
const tp = @import("thespian");
const root = @import("root");

pub const Dest = union(enum) {
    file: FileDest,
    dir: DirDest,
};

pub const FileDest = struct {
    path: []const u8,
    line: ?usize = null,
    column: ?usize = null,
    end_column: ?usize = null,
    exists: bool = false,
};

pub const DirDest = struct {
    path: []const u8,
};

pub fn parse(link: []const u8) error{InvalidFileLink}!Dest {
    if (link.len == 0) return error.InvalidFileLink;

    if (std.mem.lastIndexOfScalar(u8, link, '(')) |pos| blk: {
        for (link[pos + 1 ..]) |c| switch (c) {
            '0'...'9', ',', ')', ':' => continue,
            else => break :blk,
        };
        return parse_bracket_link(link);
    }

    var it = std.mem.splitScalar(u8, link, ':');
    var dest: Dest = if (root.is_directory(link))
        .{ .dir = .{ .path = link } }
    else
        .{ .file = .{ .path = it.first() } };
    switch (dest) {
        .file => |*file| {
            if (it.next()) |line_|
                file.line = std.fmt.parseInt(usize, line_, 10) catch blk: {
                    file.path = link;
                    break :blk null;
                };
            if (file.line) |_| if (it.next()) |col_| {
                file.column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            if (file.column) |_| if (it.next()) |col_| {
                file.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            file.exists = root.is_file(file.path);
        },
        .dir => {},
    }
    return dest;
}

pub fn parse_bracket_link(link: []const u8) error{InvalidFileLink}!Dest {
    var it_ = std.mem.splitScalar(u8, link, '(');
    var dest: Dest = if (root.is_directory(link))
        .{ .dir = .{ .path = link } }
    else
        .{ .file = .{ .path = it_.first() } };

    const rest = it_.next() orelse "";
    var it = std.mem.splitAny(u8, rest, ",):");

    switch (dest) {
        .file => |*file| {
            if (it.next()) |line_|
                file.line = std.fmt.parseInt(usize, line_, 10) catch blk: {
                    file.path = link;
                    break :blk null;
                };
            if (file.line) |_| if (it.next()) |col_| {
                file.column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            if (file.column) |_| if (it.next()) |col_| {
                file.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            file.exists = root.is_file(file.path);
        },
        .dir => {},
    }
    return dest;
}

pub fn navigate(to: tp.pid_ref, link: *const Dest) anyerror!void {
    switch (link.*) {
        .file => |file| {
            if (file.line) |l| {
                if (file.column) |col| {
                    try to.send(.{ "cmd", "navigate", .{ .file = file.path, .line = l, .column = col } });
                    if (file.end_column) |end|
                        try to.send(.{ "A", l, col - 1, end - 1 });
                    return;
                }
                return to.send(.{ "cmd", "navigate", .{ .file = file.path, .line = l } });
            }
            return to.send(.{ "cmd", "navigate", .{ .file = file.path } });
        },
        else => {},
    }
}
