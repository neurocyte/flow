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
    const extensions = [_][]const u8{".exe", ".cmd"};
    for (extensions) |extension| {
        var path = std.ArrayList(u8).init(allocator);
        try path.appendSlice(binary_name_);
        try path.appendSlice(extension);
        const binary_name = try path.toOwnedSlice();
        defer allocator.free(binary_name);
        var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);
        while (bin_path_iterator.next()) |bin_path| {
            if (!std.fs.path.isAbsolute(bin_path)) continue;
            var dir = std.fs.openDirAbsolute(bin_path, .{}) catch continue;
            defer dir.close();
            _ = dir.statFile(binary_name) catch continue;
            const resolved_binary_path = try std.fs.path.join(allocator, &[_][]const u8{ bin_path, binary_name });
            defer allocator.free(resolved_binary_path);
            return try allocator.dupeZ(u8, resolved_binary_path);
        }
    }
    return null;
}
