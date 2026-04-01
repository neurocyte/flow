const std = @import("std");
const builtin = @import("builtin");

pub fn findFont(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .linux => @import("font_finder/linux.zig").find(allocator, name),
        else => error.FontFinderNotSupported,
    };
}

/// Returns a sorted, deduplicated list of monospace font family names.
/// Caller owns the returned slice and each string within it.
pub fn listFonts(allocator: std.mem.Allocator) ![][]u8 {
    return switch (builtin.os.tag) {
        .linux => @import("font_finder/linux.zig").list(allocator),
        else => error.FontFinderNotSupported,
    };
}
