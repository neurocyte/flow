pub fn get(project: []const u8, lsp_name: []const u8) ?[]const u8 {
    return get_kind(project, lsp_name, .options);
}

pub fn get_settings(project: []const u8, lsp_name: []const u8) ?[]const u8 {
    return get_kind(project, lsp_name, .settings);
}

fn get_kind(project: []const u8, lsp_name: []const u8, kind: Kind) ?[]const u8 {
    if (project.len == 0) return read(&.{}, lsp_name, .global, kind);
    if (read(project, lsp_name, .project, kind)) |conf| return conf;
    return read(&.{}, lsp_name, .global, kind);
}

fn read(project: []const u8, lsp_name: []const u8, scope: Scope, kind: Kind) ?[]const u8 {
    const io = root.get_io();
    const file_name = get_file_path(project, lsp_name, scope, .no_create, kind) catch return null;
    defer allocator.free(file_name);
    var file = std.Io.Dir.openFileAbsolute(io, file_name, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    root.record_loaded_file(file_name);
    const stat = file.stat(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const size = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..size];
}

const settings_suffix = ".settings.json";

/// the server name if path is the global settings file or the settings file of project
pub fn settings_server_name(path: []const u8, project: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, settings_suffix)) return null;
    const dir_name = std.fs.path.dirname(path) orelse return null;
    const lsp_name = std.fs.path.basename(path[0 .. path.len - settings_suffix.len]);
    if (lsp_name.len == 0) return null;
    for ([_]Scope{ .global, .project }) |scope| {
        if (scope == .project and project.len == 0) continue;
        const dir = get_config_dir_path(project, scope, .no_create) catch continue;
        defer allocator.free(dir);
        if (std.mem.eql(u8, std.mem.trimEnd(u8, dir, std.fs.path.sep_str), dir_name)) return lsp_name;
    }
    return null;
}

pub fn get_config_file_path(project: ?[]const u8, lsp_name: []const u8, scope: Scope, mode: Mode) ![]u8 {
    return get_file_path(project, lsp_name, scope, mode, .options);
}

pub fn get_settings_file_path(project: ?[]const u8, lsp_name: []const u8, scope: Scope, mode: Mode) ![]u8 {
    return get_file_path(project, lsp_name, scope, mode, .settings);
}

fn get_file_path(project: ?[]const u8, lsp_name: []const u8, scope: Scope, mode: Mode, kind: Kind) ![]u8 {
    const config_dir_path = try get_config_dir_path(project, scope, mode);
    defer allocator.free(config_dir_path);
    var stream: std.Io.Writer.Allocating = .init(allocator);
    defer stream.deinit();
    try stream.writer.print("{s}{s}{s}", .{ config_dir_path, lsp_name, switch (kind) {
        .options => ".json",
        .settings => settings_suffix,
    } });
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
                try root.encode_path_to_filename(writer, prj);
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
const Kind = enum { options, settings };
pub const Mode = enum { mk_parents, no_create };

pub const allocator = std.heap.c_allocator;
const std = @import("std");
const root = @import("soft_root").root;
