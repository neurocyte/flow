const std = @import("std");
pub const buffer = @import("tests_buffer.zig");
pub const color = @import("tests_color.zig");

test {
    std.testing.refAllDecls(@This());
}
