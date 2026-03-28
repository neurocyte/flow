// GlyphRasterizer — comptime interface specification.
//
// Zig's duck-typing means no vtable is needed. This file documents the
// interface that every rasterizer implementation must satisfy and can be
// used as a comptime checker.
//
// A rasterizer implementation must provide:
//
//   pub const Font = <type>;        // font handle (scale, metrics, etc.)
//   pub const Fonts = <type>;       // font enumeration (for UI font picker)
//
//   pub fn init(allocator: std.mem.Allocator) !Self
//   pub fn deinit(self: *Self) void
//
//   pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font
//       Load a named font at a given pixel height. The returned Font
//       contains pre-computed metrics (cell_size, scale, ascent_px).
//
//   pub fn render(
//       self: *const Self,
//       font: Font,
//       codepoint: u21,
//       kind: enum { single, left, right },
//       staging_buf: []u8,
//   ) void
//       Rasterize a single glyph into the caller-provided A8 staging buffer.
//       - staging_buf is zero-filled by the caller before each call.
//       - For `single`: buffer is cell_size.x * cell_size.y bytes.
//       - For `left`/`right`: buffer is 2*cell_size.x * cell_size.y bytes.
//         `left` rasterizes at double width into the full buffer.
//         `right` places the glyph offset by cell_size.x so that the right
//         half of the buffer contains the right portion of the glyph.

const std = @import("std");

pub fn check(comptime Rasterizer: type) void {
    const has_Font = @hasDecl(Rasterizer, "Font");
    const has_Fonts = @hasDecl(Rasterizer, "Fonts");
    const has_init = @hasDecl(Rasterizer, "init");
    const has_deinit = @hasDecl(Rasterizer, "deinit");
    const has_loadFont = @hasDecl(Rasterizer, "loadFont");
    const has_render = @hasDecl(Rasterizer, "render");

    if (!has_Font) @compileError("Rasterizer missing: pub const Font");
    if (!has_Fonts) @compileError("Rasterizer missing: pub const Fonts");
    if (!has_init) @compileError("Rasterizer missing: pub fn init");
    if (!has_deinit) @compileError("Rasterizer missing: pub fn deinit");
    if (!has_loadFont) @compileError("Rasterizer missing: pub fn loadFont");
    if (!has_render) @compileError("Rasterizer missing: pub fn render");
}
