//! The ignore files that govern a project.

const std = @import("std");
const gitignore = @import("gitignore.zig");
const Matcher = @import("Matcher.zig");

const Sources = @This();

pub const max_file_size = 1 << 20;

pub const Source = struct {
    precedence: gitignore.Precedence,
    /// Project-relative directory that anchored patterns resolve against.
    base: []const u8 = "",
    name: []const u8,
    contents: []const u8,
};

allocator: std.mem.Allocator,
list: std.ArrayList(Source) = .empty,
use_builtin: bool = false,

pub fn init(allocator: std.mem.Allocator) Sources {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Sources) void {
    for (self.list.items) |src| self.allocator.free(src.contents);
    self.list.deinit(self.allocator);
}

pub fn add(self: *Sources, precedence: gitignore.Precedence, name: []const u8, contents: []const u8) void {
    self.list.append(self.allocator, .{
        .precedence = precedence,
        .name = name,
        .contents = contents,
    }) catch self.allocator.free(contents);
}

/// `environ` supplies XDG_CONFIG_HOME / HOME for the global excludes file.
pub fn collect(self: *Sources, io: std.Io, environ: *const std.process.Environ.Map, project_dir: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch null;
    defer if (dir) |*d| d.close(io);

    if (read_optional_file(io, self.allocator, dir, ".git/info/exclude")) |c|
        self.add(.repository, ".git/info/exclude", c);
    if (read_global_excludes(io, self.allocator, environ)) |c|
        self.add(.global, "git/ignore", c);

    self.use_builtin = self.list.items.len == 0 and
        !path_exists(io, dir, gitignore.per_directory_file_name) and
        !path_exists(io, dir, ".git");
}

pub fn register(self: *const Sources, m: *Matcher) void {
    if (self.use_builtin)
        m.add_source(.global, "", "builtin", gitignore.builtin_patterns) catch {};
    for (self.list.items) |src|
        m.add_source(src.precedence, src.base, src.name, src.contents) catch {};
}

/// A `Matcher` for `project_dir` with its sources already registered.
pub fn open(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    project_dir: []const u8,
    options: Matcher.Options,
) !*Matcher {
    const m = try allocator.create(Matcher);
    errdefer allocator.destroy(m);
    var dir = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    errdefer dir.close(io);
    m.* = try Matcher.init(allocator, dir, options);
    errdefer m.deinit();

    var sources: Sources = .init(allocator);
    defer sources.deinit();
    sources.collect(io, environ, project_dir);
    sources.register(m);
    return m;
}

/// Release a matcher from `open`, including the directory handle.
pub fn close(io: std.Io, allocator: std.mem.Allocator, m: *Matcher) void {
    var dir = m.root;
    m.deinit();
    dir.close(io);
    allocator.destroy(m);
}

fn read_optional_file(io: std.Io, allocator: std.mem.Allocator, dir: ?std.Io.Dir, sub_path: []const u8) ?[]const u8 {
    const d = dir orelse return null;
    return d.readFileAlloc(io, sub_path, allocator, .limited(max_file_size)) catch null;
}

fn path_exists(io: std.Io, dir: ?std.Io.Dir, sub_path: []const u8) bool {
    const d = dir orelse return false;
    _ = d.statFile(io, sub_path, .{}) catch return false;
    return true;
}

fn read_global_excludes(io: std.Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // git picks one of these, it does not fall back to the second
    const path = if (environ.get("XDG_CONFIG_HOME")) |xdg| blk: {
        if (xdg.len == 0) break :blk null;
        break :blk std.fmt.bufPrint(&buf, "{s}/git/ignore", .{xdg}) catch null;
    } else if (environ.get("HOME")) |home|
        std.fmt.bufPrint(&buf, "{s}/.config/git/ignore", .{home}) catch null
    else
        null;
    return std.Io.Dir.cwd().readFileAlloc(io, path orelse return null, allocator, .limited(max_file_size)) catch null;
}
