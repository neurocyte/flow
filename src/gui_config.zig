fontface: []const u8 = "IosevkaTerm Nerd Font Mono",
fontsize: u8 = 14,
fontweight: u16 = 500,
fontweight_bold_offset: u16 = 300,
fontbackend: RasterizerBackend = .freetype,
fonthinting: Hinting = .normal,
lineheight: u8 = 100,

initial_window_x: u16 = 1087,
initial_window_y: u16 = 1014,

include_files: []const u8 = "",

pub const RasterizerBackend = enum {
    truetype,
    freetype,
};

pub const Hinting = enum {
    none,
    slight,
    normal,
    mono,
};
