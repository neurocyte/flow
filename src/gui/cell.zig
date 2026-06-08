// Shared GPU cell types used by all GPU renderer backends.

const RGBA = @import("color").RGBA;

pub const Cell = extern struct {
    glyph_index: u32,
    background: RGBA,
    foreground: RGBA,
    underline: RGBA,
    ul_style: u8,
    strikethrough: u8,
    /// Rasterizer face index: 0=regular, 1=bold, 2=italic, 3=bold_italic.
    face: u8 = 0,
    /// Bit 0 = glyph_alpha_from_bg (cell α taken from bg.a in shader).
    flags: u8 = 0,
};

pub const flag_glyph_alpha_from_bg: u8 = 1 << 0;
