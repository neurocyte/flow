const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("root");

const LSP = @import("LSP.zig");

a: std.mem.Allocator,
name: []const u8,
files: std.ArrayList(File),
open_time: i64,
lsp: ?LSP = null,
lsp_name: [:0]const u8,

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
        .lsp_name = "zls",
    };
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |file| self.a.free(file.path);
    self.files.deinit();
    if (self.lsp) |*lsp| lsp.deinit();
    self.a.free(self.name);
}

fn get_lsp(self: *Self) !LSP {
    if (self.lsp) |lsp| return lsp;
    self.lsp = try LSP.open(self.a, tp.message.fmt(.{self.lsp_name}), self.lsp_name);
    const uri = try self.make_URI(null);
    defer self.a.free(uri);
    const response = try self.lsp.?.send_request(self.a, "initialize", .{
        .processId = std.os.linux.getpid(),
        .rootUri = uri,
        .clientInfo = .{ .name = root.application_name },
        .capabilities = .{
            .workspace = .{
                .applyEdit = true,
                .codeLens = .{ .refreshSupport = true },
                .configuration = true,
                .diagnostics = .{ .refreshSupport = true },
                .fileOperations = .{
                    .didCreate = true,
                    .didDelete = true,
                    .didRename = true,
                    .willCreate = true,
                    .willDelete = true,
                    .willRename = true,
                },
            },
        },
    });
    defer self.a.free(response.buf);
    return self.lsp.?;
}

fn make_URI(self: *Self, file_path: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(self.a);
    if (file_path) |path|
        try buf.writer().print("file:/{s}/{s}", .{ self.name, path })
    else
        try buf.writer().print("file:/{s}", .{self.name});
    return buf.toOwnedSlice();
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

pub fn did_open(self: *Self, from: tp.pid_ref, file_path: []const u8, file_type: []const u8, version: usize, text: []const u8) tp.result {
    const lsp = self.get_lsp() catch |e| return tp.exit_error(e);
    const uri = self.make_URI(file_path) catch |e| return tp.exit_error(e);
    defer self.a.free(uri);
    const response = try lsp.send_request(self.a, "textDocument/didOpen", .{
        .textDocument = .{
            .uri = uri,
            .languageId = file_type,
            .version = version,
            .text = text,
        },
    });
    defer self.a.free(response.buf);
    _ = from;
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) tp.result {
    const lsp = self.get_lsp() catch |e| return tp.exit_error(e);
    const uri = self.make_URI(file_path) catch |e| return tp.exit_error(e);
    defer self.a.free(uri);
    const response = try lsp.send_request(self.a, "textDocument/definition", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    });
    defer self.a.free(response.buf);
    _ = from;
}
