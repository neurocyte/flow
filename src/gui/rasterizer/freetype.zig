/// FreeType-based glyph rasterizer

const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});
const XY = @import("xy").XY;
const geometric = @import("geometric");
pub const font_finder = @import("font_finder");

const Self = @This();

pub const GlyphKind = enum { single, left, right };

pub const Fonts = struct {};

pub const Font = struct {
    cell_size: XY(u16) = .{ .x = 8, .y = 16 },
    ascent_px: i32 = 0,
    /// Top edge of the underline bar, in pixels from the top of the cell.
    underline_position: i32 = 0,
    /// Thickness of the underline bar, in pixels (>= 1).
    underline_thickness: u16 = 1,
    face: c.FT_Face = null,
    /// apply a 12° shear before rasterization
    /// Used as a fallback when no real italic is available
    italic_synth: bool = false,
};

library: c.FT_Library,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Self {
    var library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    return .{ .library = library, .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    _ = c.FT_Done_FreeType(self.library);
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const path = try font_finder.findFont(self.allocator, name);
    defer self.allocator.free(path);
    return self.loadFontFromPath(path, size_px);
}

pub fn loadFontFromPath(self: *Self, path: []const u8, size_px: u16) !Font {
    const path_z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(self.library, path_z.ptr, 0, &face) != 0)
        return error.FaceLoadFailed;
    errdefer _ = c.FT_Done_Face(face);

    if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0)
        return error.SetSizeFailed;

    // Derive cell metrics from the full block glyph (U+2588), same strategy
    // as truetype.zig: the rendered bitmap defines exact cell dimensions.
    var ascent_px: i32 = @intCast((face.*.size.*.metrics.ascender + 32) >> 6);
    var cell_h: u16 = size_px;
    if (c.FT_Load_Char(face, 0x2588, c.FT_LOAD_RENDER) == 0) {
        const bm = face.*.glyph.*.bitmap;
        if (bm.rows > 0) {
            cell_h = @intCast(bm.rows);
            ascent_px = face.*.glyph.*.bitmap_top;
        }
    }

    // Cell width from advance of 'M'.
    var cell_w: u16 = @max(1, size_px / 2);
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0) {
        const adv: i32 = @intCast((face.*.glyph.*.advance.x + 32) >> 6);
        if (adv > 0) cell_w = @intCast(adv);
    }

    // Underline metrics: face fields are in font units. y_scale is 16.16 fixed
    // and produces 26.6 pixel values when multiplied with font units >> 16.
    // underline_position is the *centre* of the bar, with the y-axis pointing
    // up from the baseline (negative = below baseline, the usual case).
    const y_scale: i64 = @intCast(face.*.size.*.metrics.y_scale);
    const ul_pos_units: i64 = @intCast(face.*.underline_position);
    const ul_thk_units: i64 = @intCast(face.*.underline_thickness);
    const ul_pos_q6: i64 = @divFloor(ul_pos_units * y_scale, 1 << 16);
    const ul_thk_q6: i64 = @divFloor(ul_thk_units * y_scale, 1 << 16);
    const ul_pos_px: i32 = @intCast(@divFloor(ul_pos_q6 + 32, 64));
    const ul_thk_px_raw: i32 = @intCast(@divFloor(ul_thk_q6 + 32, 64));
    const ul_thk_px: u16 = @intCast(@max(1, ul_thk_px_raw));
    // Convert from baseline-up centre to cell-top-down top-edge.
    const ul_centre_from_top: i32 = ascent_px - ul_pos_px;
    const ul_top_unclamped: i32 = ul_centre_from_top - @divTrunc(@as(i32, ul_thk_px), 2);
    const cell_h_i: i32 = @intCast(cell_h);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_top_unclamped));

    return .{
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .ascent_px = ascent_px,
        .underline_position = ul_top,
        .underline_thickness = ul_thk_px,
        .face = face,
    };
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    kind: GlyphKind,
    staging_buf: []u8,
) void {
    _ = self;

    const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
    const buf_h: i32 = @intCast(font.cell_size.y);
    const x_offset: i32 = switch (kind) {
        .single, .left => 0,
        .right => @intCast(font.cell_size.x),
    };
    const cw: i32 = @intCast(font.cell_size.x);
    const ch: i32 = @intCast(font.cell_size.y);

    if (geometric.renderBlockElement(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;
    if (geometric.renderBoxDrawing(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;
    if (geometric.renderExtendedBlocks(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;

    const face = font.face orelse return;

    // Load with FT_LOAD_NO_BITMAP so we always get an outline (needed for
    // FT_Outline_EmboldenXY; also avoids embedded bitmap strikes which may
    // not match our computed cell metrics).
    const load_flags: c.FT_Int32 = c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_BITMAP;
    if (c.FT_Load_Char(face, codepoint, load_flags) != 0) return;

    // Synthetic italic: 12 degree shear of the outline
    if (font.italic_synth) {
        var shear: c.FT_Matrix = .{
            .xx = 0x10000,
            .xy = 13932,
            .yx = 0,
            .yy = 0x10000,
        };
        c.FT_Outline_Transform(&face.*.glyph.*.outline, &shear);
    }

    if (c.FT_Render_Glyph(face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0) return;

    const bm = face.*.glyph.*.bitmap;
    if (bm.rows == 0 or bm.width == 0) return;
    if (bm.pitch <= 0) return; // skip bottom-up bitmaps (unusual for normal mode)

    const pitch: u32 = @intCast(bm.pitch);
    const off_x: i32 = face.*.glyph.*.bitmap_left;
    const off_y: i32 = font.ascent_px - face.*.glyph.*.bitmap_top;

    var row: u32 = 0;
    while (row < bm.rows) : (row += 1) {
        const dst_y = off_y + @as(i32, @intCast(row));
        if (dst_y < 0 or dst_y >= buf_h) continue;

        var col: u32 = 0;
        while (col < bm.width) : (col += 1) {
            const dst_x = x_offset + off_x + @as(i32, @intCast(col));
            if (dst_x < 0 or dst_x >= buf_w) continue;

            const src_idx = row * pitch + col;
            const dst_idx: usize = @intCast(dst_y * buf_w + dst_x);
            if (dst_idx < staging_buf.len)
                staging_buf[dst_idx] = bm.buffer[src_idx];
        }
    }
}
