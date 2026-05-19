const builtin = @import("builtin");

fontface: []const u8 = if (builtin.os.tag == .windows)
    "Cascadia Mono"
else
    "IosevkaTerm Nerd Font Mono",
fontsize: u8 = 14,
fontweight: u16 = 500,
fontweight_bold_offset: u16 = 300,
fontbackend: RasterizerBackend = default_backend,
fonthinting: Hinting = .normal,
lineheight: u8 = 100,
block_and_line_symbols: SymbolRasterizer = .geometric,

initial_window_x: u16 = 1087,
initial_window_y: u16 = 1014,

include_files: []const u8 = "",

pub const RasterizerBackend = if (builtin.os.tag == .windows)
    enum { dwrite }
else
    enum { truetype, freetype };

const default_backend: RasterizerBackend = if (builtin.os.tag == .windows) .dwrite else .freetype;

pub const Hinting = enum {
    none,
    slight,
    normal,
    mono,
};

pub const SymbolRasterizer = enum {
    font,
    geometric,
};
