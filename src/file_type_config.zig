name: []const u8 = default.name,
description: ?[]const u8 = null,
extensions: ?[]const []const u8 = null,
icon: ?[]const u8 = null,
color: ?u24 = null,
comment: ?[]const u8 = null,
formatter: ?[]const []const u8 = null,
language_server: ?[]const []const u8 = null,
first_line_matches_prefix: ?[]const u8 = null,
first_line_matches_content: ?[]const u8 = null,
first_line_matches: ?[]const u8 = null,

include_files: []const u8 = "",

pub const default = struct {
    pub const name = "text";
    pub const description = "Plain Text";
    pub const icon = "🖹";
    pub const color = 0x000000;
};

fn from_file_type(file_type: syntax.FileType) @This() {
    return .{
        .name = file_type.name,
        .color = file_type.color,
        .icon = file_type.icon,
        .description = file_type.description,
        .extensions = file_type.extensions,
        .first_line_matches_prefix = if (file_type.first_line_matches) |flm| flm.prefix else null,
        .first_line_matches_content = if (file_type.first_line_matches) |flm| flm.content else null,
        .comment = file_type.comment,
        .formatter = file_type.formatter,
        .language_server = file_type.language_server,
    };
}

pub fn get_default(allocator: std.mem.Allocator, file_type_name: []const u8) ![]const u8 {
    const file_type = syntax.FileType.get_by_name_static(file_type_name) orelse return error.UnknownFileType;
    const config = from_file_type(file_type);
    var content = std.ArrayListUnmanaged(u8).empty;
    defer content.deinit(allocator);
    root.write_config_to_writer(@This(), config, content.writer(allocator)) catch {};
    return content.toOwnedSlice(allocator);
}

pub fn get_all_names() []const []const u8 {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cache_list.len == 0)
        cache_list = load_all(cache_allocator) catch &.{};
    return cache_list;
}

const cache_allocator = std.heap.c_allocator;
var cache_mutex: std.Thread.Mutex = .{};
var cache: CacheType = .empty;
const CacheType = std.StringHashMapUnmanaged(?@This());
var cache_list: []const []const u8 = &.{};

pub fn get(file_type_name: []const u8) !?@This() {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    return if (cache.get(file_type_name)) |self| self else self: {
        const file_type = file_type: {
            const file_name = try get_config_file_path(cache_allocator, file_type_name);
            defer cache_allocator.free(file_name);

            const file: ?std.fs.File = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch null;
            if (file) |f| {
                defer f.close();
                const stat = try f.stat();
                const buf = try cache_allocator.alloc(u8, @intCast(stat.size));
                defer cache_allocator.free(buf);
                const size = try f.readAll(buf);
                std.debug.assert(size == stat.size);
                var self: @This() = .{};
                var bufs_: [][]const u8 = &.{}; // cached, no need to free
                try root.parse_text_config_file(@This(), cache_allocator, &self, &bufs_, file_name, buf);
                break :file_type self;
            } else {
                break :file_type if (syntax.FileType.get_by_name_static(file_type_name)) |ft| from_file_type(ft) else null;
            }
        };
        try cache.put(cache_allocator, file_type_name, file_type);
        break :self file_type;
    };
}

pub fn get_config_file_path(allocator: std.mem.Allocator, file_type: []const u8) ![]u8 {
    var stream = std.ArrayList(u8).fromOwnedSlice(allocator, try get_config_dir_path(allocator));
    const writer = stream.writer();
    _ = try writer.writeAll(file_type);
    _ = try writer.writeAll(".conf");
    return stream.toOwnedSlice();
}

fn get_config_dir_path(allocator: std.mem.Allocator) ![]u8 {
    var stream = std.ArrayList(u8).init(allocator);
    const writer = stream.writer();
    _ = try writer.writeAll(try root.get_config_dir());
    _ = try writer.writeByte(std.fs.path.sep);
    _ = try writer.writeAll("file_type");
    _ = try writer.writeByte(std.fs.path.sep);
    std.fs.makeDirAbsolute(stream.items) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return stream.toOwnedSlice();
}

const extension = ".conf";

fn load_all(allocator: std.mem.Allocator) ![]const []const u8 {
    const dir_path = try get_config_dir_path(allocator);
    defer allocator.free(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, extension)) continue;
        const file_type_name = entry.name[0 .. entry.name.len - extension.len];
        if (!names.contains(file_type_name))
            try names.put(allocator, try allocator.dupe(u8, file_type_name), {});
    }

    for (syntax.FileType.get_all()) |file_type| {
        if (!names.contains(file_type.name))
            try names.put(allocator, try allocator.dupe(u8, file_type.name), {});
    }

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(allocator);

    var names_iter = names.keyIterator();
    while (names_iter.next()) |key| {
        (try list.addOne(allocator)).* = key.*;
    }

    const less_fn = struct {
        fn less_fn(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less_fn;
    std.mem.sort([]const u8, list.items, {}, less_fn);

    return list.toOwnedSlice(allocator);
}

pub fn guess_file_type(file_path: ?[]const u8, content: []const u8) ?@This() {
    return guess(file_path, content);
}

fn guess(file_path: ?[]const u8, content: []const u8) ?@This() {
    if (guess_first_line(content)) |ft| return ft;
    for (get_all_names()) |file_type_name| {
        const file_type = get(file_type_name) catch unreachable orelse unreachable;
        if (file_path) |fp| if (syntax.FileType.match_file_type(file_type.extensions orelse continue, fp))
            return file_type;
    }
    return null;
}

fn guess_first_line(content: []const u8) ?@This() {
    const first_line = if (std.mem.indexOf(u8, content, "\n")) |pos| content[0..pos] else content;
    for (get_all_names()) |file_type_name| {
        const file_type = get(file_type_name) catch unreachable orelse unreachable;
        if (syntax.FileType.match_first_line(file_type.first_line_matches_prefix, file_type.first_line_matches_content, first_line))
            return file_type;
    }
    return null;
}

pub fn create_syntax(file_type_config: @This(), allocator: std.mem.Allocator, query_cache: *syntax.QueryCache) !*syntax {
    return syntax.create(
        syntax.FileType.get_by_name_static(file_type_config.name) orelse return error.FileTypeNotFound,
        allocator,
        query_cache,
    );
}

pub fn create_syntax_guess_file_type(
    allocator: std.mem.Allocator,
    content: []const u8,
    file_path: ?[]const u8,
    query_cache: *syntax.QueryCache,
) !*syntax {
    const file_type = guess(file_path, content) orelse return error.NotFound;
    return create_syntax(file_type, allocator, query_cache);
}

const syntax = @import("syntax");
const std = @import("std");
const root = @import("root");
