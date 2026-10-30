const std = @import("std");
pub const buffer = @import("tests_buffer.zig");
pub const color = @import("tests_color.zig");
pub const file_link = @import("tests_file_link.zig");
pub const helix = @import("tests_helix.zig");
pub const info_box_placement = @import("tests_info_box_placement.zig");
pub const link_dispatch = @import("tests_link_dispatch.zig");
pub const jump_labels = @import("tests_jump_labels.zig");
pub const lsp = @import("tests_lsp.zig");
pub const mini_buffer = @import("tests_mini_buffer.zig");
pub const project_manager = @import("tests_project_manager.zig");
pub const scroll_animation = @import("tests_scroll_animation.zig");
pub const snippet = @import("tests_snippet.zig");
pub const soft_root = @import("tests_soft_root.zig");
pub const surround = @import("tests_surround.zig");
pub const text_manip = @import("tests_text_manip.zig");

test {
    std.testing.refAllDecls(@This());
}
