// Shared GPU cell types used by all GPU renderer backends.

const RGBA = @import("color").RGBA;

pub const Cell = extern struct {
    glyph_index: u32,
    background: RGBA,
    foreground: RGBA,
    underline: RGBA,
    ul_style: u8,
    strikethrough: u8,
    _pad: [2]u8 = .{ 0, 0 },
};
