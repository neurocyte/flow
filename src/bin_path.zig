const std = @import("std");
const builtin = @import("builtin");

pub const find_binary_in_path = switch (builtin.os.tag) {
    .windows => find_binary_in_path_windows,
    else => find_binary_in_path_posix,
};

fn find_binary_in_path_posix(allocator: std.mem.Allocator, binary_name: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const bin_paths = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => &.{},
    };
    defer allocator.free(bin_paths);
    var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);
    while (bin_path_iterator.next()) |bin_path| {
        const resolved_binary_path = try std.fs.path.resolve(allocator, &.{ bin_path, binary_name });
        defer allocator.free(resolved_binary_path);
        std.posix.access(resolved_binary_path, std.posix.X_OK) catch continue;
        return try allocator.dupeZ(u8, resolved_binary_path);
    }
    return null;
}

fn find_binary_in_path_windows(allocator: std.mem.Allocator, binary_name_: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const bin_paths = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => &.{},
    };
    defer allocator.free(bin_paths);
    const bin_extensions = std.process.getEnvVarOwned(allocator, "PATHEXT") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => &.{},
    };
    defer allocator.free(bin_extensions);
    var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);
    while (bin_path_iterator.next()) |bin_path| {
        if (!std.fs.path.isAbsolute(bin_path)) continue;
        var dir = std.fs.openDirAbsolute(bin_path, .{}) catch continue;
        defer dir.close();
        var bin_extensions_iterator = std.mem.splitScalar(u8, bin_extensions, ';');
        while (bin_extensions_iterator.next()) |bin_extension| {
            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(allocator, binary_name_);
            try path.appendSlice(allocator, bin_extension);
            const binary_name = try path.toOwnedSlice(allocator);
            defer allocator.free(binary_name);
            _ = dir.statFile(binary_name) catch continue;
            const resolved_binary_path = try std.fs.path.join(allocator, &[_][]const u8{ bin_path, binary_name });
            defer allocator.free(resolved_binary_path);
            return try allocator.dupeZ(u8, resolved_binary_path);
        }
    }
    return null;
}

fn is_absolute_binary_path_executable(binary_path: []const u8) bool {
    switch (builtin.os.tag) {
        .windows => _ = std.fs.cwd().statFile(binary_path) catch return false,
        else => std.posix.access(binary_path, std.posix.X_OK) catch return false,
    }
    return true;
}

pub fn can_execute(allocator: std.mem.Allocator, binary_name: []const u8) bool {
    for (binary_name) |char| if (std.fs.path.isSep(char))
        return is_absolute_binary_path_executable(binary_name);
    const resolved_binary_path = find_binary_in_path(allocator, binary_name) catch return false;
    defer if (resolved_binary_path) |path| allocator.free(path);
    return resolved_binary_path != null;
}

pub fn resolve_executable(allocator: std.mem.Allocator, binary_name: [:0]const u8) [:0]const u8 {
    return for (binary_name) |char| {
        if (std.fs.path.isSep(char)) break binary_name;
    } else find_binary_in_path(allocator, binary_name) catch binary_name orelse binary_name;
}
