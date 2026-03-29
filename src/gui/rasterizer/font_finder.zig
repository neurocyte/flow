const std = @import("std");
const builtin = @import("builtin");

pub fn findFont(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .linux => @import("font_finder/linux.zig").find(allocator, name),
        else => error.FontFinderNotSupported,
    };
}
