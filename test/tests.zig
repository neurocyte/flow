const std = @import("std");
pub const buffer = @import("tests_buffer.zig");
pub const color = @import("tests_color.zig");
pub const helix = @import("tests_helix.zig");
pub const project_manager = @import("tests_project_manager.zig");

test {
    std.testing.refAllDecls(@This());
}
