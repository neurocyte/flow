pub fn get(project: []const u8, lsp_name: []const u8) ?[]const u8 {
    if (project.len == 0) return get_global(lsp_name);
    if (get_project(project, lsp_name)) |conf| return conf;
    return get_global(lsp_name);
}

fn get_project(project: []const u8, lsp_name: []const u8) ?[]const u8 {
    const io = root.get_io();
    const file_name = get_config_file_path(project, lsp_name, .project, .no_create) catch return null;
    defer allocator.free(file_name);
    var file = std.Io.Dir.openFileAbsolute(io, file_name, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const size = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..size];
}

fn get_global(lsp_name: []const u8) ?[]const u8 {
    const io = root.get_io();
    const file_name = get_config_file_path(&.{}, lsp_name, .global, .no_create) catch return null;
    defer allocator.free(file_name);
    var file = std.Io.Dir.openFileAbsolute(io, file_name, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const size = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..size];
}

pub fn get_config_file_path(project: ?[]const u8, lsp_name: []const u8, scope: Scope, mode: Mode) ![]u8 {
    const config_dir_path = try get_config_dir_path(project, scope, mode);
    defer allocator.free(config_dir_path);
    var stream: std.Io.Writer.Allocating = .init(allocator);
    defer stream.deinit();
    try stream.writer.print("{s}{s}.json", .{ config_dir_path, lsp_name });
    return stream.toOwnedSlice();
}

fn get_config_dir_path(project: ?[]const u8, scope: Scope, mode: Mode) ![]u8 {
    var stream: std.Io.Writer.Allocating = .init(allocator);
    defer stream.deinit();
    const writer = &stream.writer;
    try writer.writeAll(try root.get_config_dir());
    try writer.writeByte(std.fs.path.sep);
    switch (scope) {
        .project => {
            try writer.writeAll("project");
            try writer.writeByte(std.fs.path.sep);
            if (mode == .mk_parents) std.Io.Dir.createDirAbsolute(root.get_io(), stream.written(), .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            if (project) |prj| {
                for (prj) |c| {
                    _ = if (std.fs.path.isSep(c))
                        try writer.write("__")
                    else if (c == ':')
                        try writer.write("___")
                    else
                        try writer.writeByte(c);
                }
                _ = try writer.writeByte(std.fs.path.sep);
            }
        },
        .global => {
            try writer.writeAll("lsp");
            try writer.writeByte(std.fs.path.sep);
        },
    }
    if (mode == .mk_parents) std.Io.Dir.createDirAbsolute(root.get_io(), stream.written(), .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return stream.toOwnedSlice();
}

pub const Scope = enum { project, global };
pub const Mode = enum { mk_parents, no_create };

pub const allocator = std.heap.c_allocator;
const std = @import("std");
const root = @import("soft_root").root;
