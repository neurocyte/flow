const builtin = @import("builtin");

fontface: []const u8 = builtin_fontface,
fontsize: u8 = 14,
fontweight: u16 = 500,
fontweight_bold_offset: u16 = 300,
fontbackend: RasterizerBackend = default_backend,
fonthinting: Hinting = .normal,
lineheight: u8 = 100,
block_and_line_symbols: SymbolRasterizer = .default,
allow_color_glyphs: bool = true,

gui_glyph_atlas_budget_mb: u16 = 96,
gui_glyph_atlas_page_mb: u16 = 4,

initial_window_x: u16 = 1087,
initial_window_y: u16 = 1014,

gui_window_transparency: bool = default_window_transparency,
gui_background_opacity: f32 = 0.95,
gui_ignore_theme_alpha: bool = true,

include_files: []const u8 = "",

/// Reserved family name for the Iosevka bundled into the binary.
pub const builtin_fontface = "Iosevka (built-in)";

pub const RasterizerBackend = switch (builtin.os.tag) {
    .windows => enum { dwrite },
    .macos => enum { truetype },
    else => enum { truetype, freetype },
};

const default_backend: RasterizerBackend = switch (builtin.os.tag) {
    .windows => .dwrite,
    .macos => .truetype,
    else => .freetype,
};

const default_window_transparency = builtin.os.tag != .macos;

pub const Hinting = enum {
    none,
    slight,
    normal,
    mono,
};

pub const SymbolRasterizer = enum {
    font,
    sprite,

    pub const default = .sprite;
};
