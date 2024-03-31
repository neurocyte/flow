const std = @import("std");
const tp = @import("thespian");

const Lsp = @import("Lsp.zig");

a: std.mem.Allocator,
name: []const u8,
files: std.ArrayList(File),
open_time: i64,
lsp: ?Lsp = null,

const Self = @This();

const File = struct {
    path: []const u8,
    mtime: i128,
};

pub fn init(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!Self {
    return .{
        .a = a,
        .name = try a.dupe(u8, name),
        .files = std.ArrayList(File).init(a),
        .open_time = std.time.milliTimestamp(),
    };
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |file| self.a.free(file.path);
    self.files.deinit();
    if (self.lsp) |*lsp| lsp.deinit();
    self.a.free(self.name);
}

fn get_lsp(self: *Self) !Lsp {
    if (self.lsp) |lsp| return lsp;
    self.lsp = try Lsp.open(self.a, tp.message.fmt(.{"zls"}), "LSP");
    return self.lsp.?;
}

pub fn add_file(self: *Self, path: []const u8, mtime: i128) error{OutOfMemory}!void {
    (try self.files.addOne()).* = .{ .path = try self.a.dupe(u8, path), .mtime = mtime };
}

pub fn sort_files_by_mtime(self: *Self) void {
    const less_fn = struct {
        fn less_fn(_: void, lhs: File, rhs: File) bool {
            return lhs.mtime > rhs.mtime;
        }
    }.less_fn;
    std.mem.sort(File, self.files.items, {}, less_fn);
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) error{ OutOfMemory, Exit }!void {
    defer from.send(.{ "PRJ", "recent_done", "" }) catch {};
    for (self.files.items, 0..) |file, i| {
        try from.send(.{ "PRJ", "recent", file.path });
        if (i >= max) return;
    }
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) error{ OutOfMemory, Exit }!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "recent_done", query }) catch {};
    for (self.files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |_| {
            try from.send(.{ "PRJ", "recent", file.path });
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, file_type: []const u8, row: usize, col: usize) tp.result {
    const lsp = self.get_lsp() catch |e| return tp.exit_error(e);
    _ = from;
    _ = file_path;
    _ = file_type;
    _ = row;
    _ = col;
    _ = lsp;
}
