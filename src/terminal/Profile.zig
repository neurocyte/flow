//! Terminal profile
//!
//! A terminal profile is a named shell or application flow can launch in a
//! terminal panel. Each profile lives in its own file under the "profiles"
//! subdirectory of the config directory (e.g. ~/.config/flow/profiles/shell),
//! written in flow's normal text config format.

const std = @import("std");
const root = @import("soft_root").root;

const log = std.log.scoped(.terminal_profiles);

const Profile = @This();

/// Display name. Empty means "use the file name".
name: []const u8 = "",
/// Command line to run.
command: []const u8 = default_command,
/// Optional icon (glyph) for the profile picker.
icon: []const u8 = "",
/// Accent color for the profile picker, as a 24 bit hex value.
color: u24 = 0x000000,
/// Working directory to start in.
cwd: []const u8 = "{{project}}",

pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    allocator.free(self.command);
    allocator.free(self.icon);
    allocator.free(self.cwd);
}

pub fn dupe(allocator: std.mem.Allocator, src: Profile) std.mem.Allocator.Error!Profile {
    const name = try allocator.dupe(u8, src.name);
    errdefer allocator.free(name);
    const command = try allocator.dupe(u8, src.command);
    errdefer allocator.free(command);
    const icon = try allocator.dupe(u8, src.icon);
    errdefer allocator.free(icon);
    const cwd = try allocator.dupe(u8, src.cwd);
    return .{ .name = name, .command = command, .icon = icon, .color = src.color, .cwd = cwd };
}

pub fn free(allocator: std.mem.Allocator, profiles: []Profile) void {
    for (profiles) |*profile| profile.deinit(allocator);
    allocator.free(profiles);
}

const default_command = "{{shell}}";
const default_id = "default";
const default_profile: Profile = .{ .name = "Default shell" };

const profiles_dir_name = "profile";
const max_profile_bytes = 1024 * 1024;

pub const WriteError = error{
    ConfigDirUnavailable,
    WriteFailed,
} || std.mem.Allocator.Error;

/// List all profiles, default first then the rest by file name (id). Caller owns the result.
pub fn list(allocator: std.mem.Allocator) std.mem.Allocator.Error![]Profile {
    const dir_path = get_profiles_dir(allocator) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return default_list(allocator),
    };
    defer allocator.free(dir_path);

    var ids = collect_ids(allocator, dir_path) catch |e| {
        log.info("cannot read profiles directory {s}: {s}", .{ dir_path, @errorName(e) });
        return default_list(allocator);
    };
    defer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    if (ids.items.len == 0) return default_list(allocator);

    std.mem.sort([]const u8, ids.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            const a_default = std.mem.eql(u8, a, default_id);
            const b_default = std.mem.eql(u8, b, default_id);
            if (a_default != b_default) return a_default;
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var result: std.ArrayList(Profile) = try .initCapacity(allocator, ids.items.len);
    errdefer free(allocator, result.toOwnedSlice(allocator) catch @panic("OOM Profile.list"));

    for (ids.items) |id| {
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, id });
        defer allocator.free(file_path);
        result.appendAssumeCapacity(read_file(allocator, id, file_path) catch |e| {
            log.warn("skipping profile '{s}': {s}", .{ id, @errorName(e) });
            continue;
        });
    }
    if (result.items.len == 0) return default_list(allocator);
    return result.toOwnedSlice(allocator);
}

fn default_list(allocator: std.mem.Allocator) std.mem.Allocator.Error![]Profile {
    const profiles = try allocator.alloc(Profile, 1);
    errdefer allocator.free(profiles);
    profiles[0] = try dupe(allocator, default_profile);
    return profiles;
}

pub fn read(allocator: std.mem.Allocator, id: []const u8) std.mem.Allocator.Error!?Profile {
    const dir_path = get_profiles_dir(allocator) catch return null;
    defer allocator.free(dir_path);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, id });
    defer allocator.free(file_path);
    return read_file(allocator, id, file_path) catch null;
}

pub fn write(profile: Profile, id: []const u8) WriteError!void {
    const io = root.get_io();
    var dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}{c}{s}", .{
        root.get_config_dir() catch return error.ConfigDirUnavailable,
        std.fs.path.sep,
        profiles_dir_name,
    }) catch return error.ConfigDirUnavailable;

    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            log.err("cannot create profiles directory {s}: {s}", .{ dir_path, @errorName(e) });
            return error.WriteFailed;
        },
    };

    var file_buf: [std.posix.PATH_MAX]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, id }) catch return error.ConfigDirUnavailable;

    var file = std.Io.Dir.createFileAbsolute(io, file_path, .{}) catch |e| {
        log.err("cannot create profile {s}: {s}", .{ file_path, @errorName(e) });
        return error.WriteFailed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    root.write_config_to_writer(Profile, profile, &writer.interface) catch return error.WriteFailed;
    writer.interface.flush() catch return error.WriteFailed;
}

pub fn write_default() WriteError!void {
    return write(default_profile, default_id);
}

pub fn get_default(allocator: std.mem.Allocator) !Profile {
    const profiles = try list(allocator);
    defer free(allocator, profiles);
    return try dupe(allocator, profiles[0]);
}

fn get_profiles_dir(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ try root.get_config_dir(), profiles_dir_name });
}

fn collect_ids(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]const u8) {
    const io = root.get_io();
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        try ids.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return ids;
}

fn read_file(allocator: std.mem.Allocator, id: []const u8, file_path: []const u8) !Profile {
    const io = root.get_io();
    var file = try std.Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_profile_bytes) {
        log.warn("ignoring oversized profile {s} ({d} bytes)", .{ file_path, stat.size });
        return error.ProfileTooLarge;
    }
    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    const content = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var conf: Profile = .{};
    var bufs: [][]const u8 = &[_][]const u8{};
    defer root.free_config(allocator, bufs);
    root.parse_text_config_file(Profile, allocator, &conf, &bufs, id, content) catch |e| {
        log.warn("cannot parse profile '{s}': {s}", .{ id, @errorName(e) });
        return error.BadProfile;
    };
    if (conf.name.len == 0) conf.name = id;
    return dupe(allocator, conf);
}
