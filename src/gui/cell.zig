// Shared GPU cell types used by all GPU renderer backends.

const RGBA = @import("color").RGBA;

pub const Cell = extern struct {
    glyph_index: u32,
    background: RGBA,
    foreground: RGBA,
};
