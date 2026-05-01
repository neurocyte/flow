const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

pub const find_binary_in_path = switch (builtin.os.tag) {
    .windows => find_binary_in_path_windows,
    else => find_binary_in_path_posix,
};

fn find_binary_in_path_posix(allocator: std.mem.Allocator, binary_name: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const bin_paths = root.get_init().environ_map.get("PATH") orelse &.{};
    var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);
    while (bin_path_iterator.next()) |bin_path| {
        const resolved_binary_path = try std.fs.path.resolve(allocator, &.{ bin_path, binary_name });
        defer allocator.free(resolved_binary_path);
        const resolved_binary_pathZ = try allocator.dupeZ(u8, resolved_binary_path);
        errdefer allocator.free(resolved_binary_pathZ);
        const rc = std.posix.system.access(resolved_binary_pathZ, std.posix.X_OK);
        if (rc == -1) continue;
        return resolved_binary_pathZ;
    }
    return null;
}

fn find_binary_in_path_windows(allocator: std.mem.Allocator, binary_name_: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const io = root.get_io();
    const bin_paths = root.get_init().environ_map.get("PATH") orelse &.{};
    const bin_extensions = root.get_init().environ_map.get("PATHEXT") orelse &.{};
    var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);
    while (bin_path_iterator.next()) |bin_path| {
        if (!std.fs.path.isAbsolute(bin_path)) continue;
        var dir = std.Io.Dir.openDirAbsolute(io, bin_path, .{}) catch continue;
        defer dir.close(io);
        var bin_extensions_iterator = std.mem.splitScalar(u8, bin_extensions, ';');
        while (bin_extensions_iterator.next()) |bin_extension| {
            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(allocator, binary_name_);
            try path.appendSlice(allocator, bin_extension);
            const binary_name = try path.toOwnedSlice(allocator);
            defer allocator.free(binary_name);
            _ = dir.statFile(io, binary_name, .{}) catch continue;
            const resolved_binary_path = try std.fs.path.join(allocator, &[_][]const u8{ bin_path, binary_name });
            defer allocator.free(resolved_binary_path);
            return try allocator.dupeZ(u8, resolved_binary_path);
        }
    }
    return null;
}

fn is_absolute_binary_path_executable(binary_path: [:0]const u8) bool {
    return switch (builtin.os.tag) {
        .windows => blk: {
            _ = std.Io.Dir.cwd().statFile(root.get_io(), binary_path, .{}) catch break :blk false;
            break :blk true;
        },
        else => std.posix.system.access(binary_path, std.posix.X_OK) == 0,
    };
}

pub fn can_execute(allocator: std.mem.Allocator, binary_name: []const u8) bool {
    const binary_nameZ = allocator.dupeZ(u8, binary_name) catch @panic("OOM in can_execute");
    defer allocator.free(binary_nameZ);
    for (binary_name) |char| if (std.fs.path.isSep(char))
        return is_absolute_binary_path_executable(binary_nameZ);
    const resolved_binary_path = find_binary_in_path(allocator, binary_nameZ) catch return false;
    defer if (resolved_binary_path) |path| allocator.free(path);
    return resolved_binary_path != null;
}

pub fn resolve_executable(allocator: std.mem.Allocator, binary_name: [:0]const u8) [:0]const u8 {
    return for (binary_name) |char| {
        if (std.fs.path.isSep(char)) break binary_name;
    } else find_binary_in_path(allocator, binary_name) catch binary_name orelse binary_name;
}
