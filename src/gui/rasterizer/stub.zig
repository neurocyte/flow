// Stub rasterizer for M2 testing — renders blank (zeroed) glyphs.
const std = @import("std");
const XY = @import("xy").XY;

const Self = @This();

pub const Font = struct {
    cell_size: XY(u16),
};

pub const Fonts = struct {};

pub const GlyphKind = enum {
    single,
    left,
    right,
};

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
    kind: GlyphKind,
    staging_buf: []u8,
) void {
    _ = self;
    _ = font;
    _ = codepoint;
    _ = kind;
    // Blank glyph — caller has already zeroed staging_buf.
    _ = staging_buf;
}
