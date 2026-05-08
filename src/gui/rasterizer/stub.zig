// Stub rasterizer for M2 testing — renders blank (zeroed) glyphs.
const std = @import("std");
const XY = @import("xy").XY;

const Self = @This();

pub const Font = struct {
    cell_size: XY(u16),
};

pub const Fonts = struct {};

pub const GlyphSplit = enum {
    single,
    left,
    right,
};

pub const RasterFormat = enum(u2) {
    alpha = 0,
    subpixel = 1,
    color = 2,
};

pub const RenderResult = struct { format: RasterFormat };

pub fn init(allocator: std.mem.Allocator) !Self {
    _ = allocator;
    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    _ = self;
    _ = name;
    const cell_h = @max(size_px, 4);
    const cell_w = @max(cell_h / 2, 2);
    return Font{ .cell_size = .{ .x = cell_w, .y = cell_h } };
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    _ = self;
    _ = font;
    _ = codepoint;
    _ = split;
    // Blank glyph — caller has already zeroed staging_buf.
    _ = staging_buf;
    return .{ .format = .alpha };
}
