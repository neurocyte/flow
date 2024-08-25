const builtin = @import("builtin");

frame_rate: usize = 60,
theme: []const u8 = "default",
input_mode: []const u8 = "flow",
gutter_line_numbers: bool = true,
gutter_line_numbers_relative: bool = false,
vim_normal_gutter_line_numbers_relative: bool = true,
vim_visual_gutter_line_numbers_relative: bool = true,
vim_insert_gutter_line_numbers_relative: bool = false,
enable_terminal_cursor: bool = false,
enable_terminal_color_scheme: bool = builtin.os.tag != .windows,
highlight_current_line: bool = true,
highlight_current_line_gutter: bool = true,
show_whitespace: bool = false,
animation_min_lag: usize = 0, //milliseconds
animation_max_lag: usize = 150, //milliseconds

top_bar: []const u8 = "",
bottom_bar: []const u8 = "mode file log selection diagnostics linenumber",
