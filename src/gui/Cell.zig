// Shared GPU cell types used by all GPU renderer backends.

pub const Rgba8 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,
    pub fn initRgb(r: u8, g: u8, b: u8) Rgba8 {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    pub fn initRgba(r: u8, g: u8, b: u8, a: u8) Rgba8 {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Cell = extern struct {
    glyph_index: u32,
    background: Rgba8,
    foreground: Rgba8,
};
