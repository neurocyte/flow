fontface: []const u8 = "IosevkaTerm Nerd Font Mono",
fontsize: u8 = 14,
fontweight: u8 = 0,
fontbackend: RasterizerBackend = .freetype,

initial_window_x: u16 = 1087,
initial_window_y: u16 = 1014,

include_files: []const u8 = "",

pub const RasterizerBackend = enum {
    truetype,
    freetype,
};
