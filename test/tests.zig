const std = @import("std");
pub const buffer = @import("tests_buffer.zig");
pub const color = @import("tests_color.zig");
pub const file_link = @import("tests_file_link.zig");
pub const helix = @import("tests_helix.zig");
pub const project_manager = @import("tests_project_manager.zig");
pub const snippet = @import("tests_snippet.zig");

test {
    std.testing.refAllDecls(@This());
}
