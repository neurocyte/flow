/// Combined rasterizer — wraps TrueType and FreeType backends with runtime switching.
/// Satisfies the GlyphRasterizer interface (see GlyphRasterizer.zig).
///
/// The active backend is changed via setBackend().  Callers must reload fonts
/// after switching (the Font struct's .backend tag must match the active backend).
const std = @import("std");
const XY = @import("xy").XY;
const TT = @import("tt_rasterizer");
const FT = @import("ft_rasterizer");

pub const GlyphKind = TT.GlyphKind;
pub const Fonts = struct {};
pub const font_finder = TT.font_finder;

pub const Backend = @import("gui_config").RasterizerBackend;

/// Backend-specific font data.
pub const BackendFont = union(Backend) {
    truetype: TT.Font,
    freetype: FT.Font,
};

/// Combined font handle.  `cell_size` is hoisted to the top level so all
/// existing callers that do `font.cell_size.x / .y` continue to work without
/// change.  Backend-specific data lives in `backend`.
pub const Font = struct {
    cell_size: XY(u16),
    backend: BackendFont,
};

/// Set emboldening weight on a font (0 = normal).
/// For TrueType: number of morphological dilation passes.
/// For FreeType: outline inflation at 32 units per weight step (0.5px each).
pub fn setFontWeight(font: *Font, w: u8) void {
    switch (font.backend) {
        .truetype => |*f| f.weight = w,
        .freetype => |*f| f.weight_strength = @as(i64, w) * 32,
    }
}

const Self = @This();

active: Backend = .truetype,
tt: TT,
ft: FT,

pub fn init(allocator: std.mem.Allocator) !Self {
    const tt = try TT.init(allocator);
    const ft = try FT.init(allocator);
    return .{ .tt = tt, .ft = ft };
}

pub fn deinit(self: *Self) void {
    self.tt.deinit();
    self.ft.deinit();
}

pub fn setBackend(self: *Self, backend: Backend) void {
    self.active = backend;
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    switch (self.active) {
        .truetype => {
            const f = try self.tt.loadFont(name, size_px);
            return .{ .cell_size = f.cell_size, .backend = .{ .truetype = f } };
        },
        .freetype => {
            const f = try self.ft.loadFont(name, size_px);
            return .{ .cell_size = f.cell_size, .backend = .{ .freetype = f } };
        },
    }
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    kind: GlyphKind,
    staging_buf: []u8,
) void {
    switch (font.backend) {
        .truetype => |f| self.tt.render(f, codepoint, kind, staging_buf),
        .freetype => |f| self.ft.render(f, codepoint, @enumFromInt(@intFromEnum(kind)), staging_buf),
    }
}
