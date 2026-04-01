const std = @import("std");
const TrueType = @import("TrueType");
const XY = @import("xy").XY;
pub const font_finder = @import("font_finder.zig");

const Self = @This();

pub const GlyphKind = enum {
    single,
    left,
    right,
};

pub const Font = struct {
    cell_size: XY(u16),
    scale: f32 = 0,
    ascent_px: i32 = 0,
    tt: ?TrueType = null,
};

pub const Fonts = struct {};

allocator: std.mem.Allocator,
font_data: std.ArrayListUnmanaged([]u8),

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .font_data = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.font_data.items) |data| {
        self.allocator.free(data);
    }
    self.font_data.deinit(self.allocator);
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const path = try font_finder.findFont(self.allocator, name);
    defer self.allocator.free(path);

    const data = try std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024);
    errdefer self.allocator.free(data);

    const tt = try TrueType.load(data);

    const scale = tt.scaleForPixelHeight(@floatFromInt(size_px));
    const vm = tt.verticalMetrics();

    // Use the full block glyph (U+2588) to derive exact cell dimensions.
    // Its rasterized bbox defines exactly how many pixels tall a full-height
    // character is, and where the baseline sits within the cell.  Using font
    // metrics (vm.ascent/vm.descent) produces a cell_h that may differ from
    // the glyph because the font bbox can diverge from nominal metrics.
    const full_block_glyph = tt.codepointGlyphIndex('█');
    const block_bbox = tt.glyphBitmapBox(full_block_glyph, scale, scale);
    const has_block = full_block_glyph != .notdef and block_bbox.y1 > block_bbox.y0;
    const ascent_px: i32 = if (has_block)
        -@as(i32, block_bbox.y0)
    else
        @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(vm.ascent)) * scale)));
    const cell_h: u16 = if (has_block)
        @intCast(@max(block_bbox.y1 - block_bbox.y0, 1))
    else blk: {
        const d: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(vm.descent)) * scale));
        break :blk @intCast(@max(ascent_px - d, 1));
    };

    const m_glyph = tt.codepointGlyphIndex('M');
    const m_hmetrics = tt.glyphHMetrics(m_glyph);
    const cell_w_f: f32 = @as(f32, @floatFromInt(m_hmetrics.advance_width)) * scale;
    const cell_w: u16 = @max(1, @as(u16, @intFromFloat(@ceil(cell_w_f))));

    try self.font_data.append(self.allocator, data);

    return Font{
        .tt = tt, // TrueType holds a slice into `data` which is now owned by self.font_data
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .scale = scale,
        .ascent_px = ascent_px,
    };
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    kind: GlyphKind,
    staging_buf: []u8,
) void {
    // Always use 2*cell_w as the row stride so it matches the staging buffer
    // width allocated by generateGlyph (which always allocates 2*cell_w wide).
    const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
    const buf_h: i32 = @intCast(font.cell_size.y);
    const x_offset: i32 = switch (kind) {
        .single, .left => 0,
        .right => @intCast(font.cell_size.x),
    };
    const cw: i32 = @intCast(font.cell_size.x);
    const ch: i32 = @intCast(font.cell_size.y);

    // Block element characters (U+2580–U+259F) are rasterized geometrically
    // rather than through the TrueType anti-aliasing path.  Anti-aliased edges
    // produce partial-alpha pixels at cell boundaries, creating visible seams
    // between adjacent cells when fg ≠ bg.
    if (renderBlockElement(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tt = font.tt orelse return;

    var pixels = std.ArrayListUnmanaged(u8){};

    const glyph = tt.codepointGlyphIndex(codepoint);
    const dims = tt.glyphBitmap(alloc, &pixels, glyph, font.scale, font.scale) catch return;

    if (dims.width == 0 or dims.height == 0) return;

    for (0..dims.height) |row| {
        const dst_y: i32 = font.ascent_px + @as(i32, dims.off_y) + @as(i32, @intCast(row));
        if (dst_y < 0 or dst_y >= buf_h) continue;

        for (0..dims.width) |col| {
            const dst_x: i32 = x_offset + @as(i32, dims.off_x) + @as(i32, @intCast(col));
            if (dst_x < 0 or dst_x >= buf_w) continue;

            const src_idx = row * dims.width + col;
            const dst_idx: usize = @intCast(dst_y * buf_w + dst_x);

            if (src_idx < pixels.items.len and dst_idx < staging_buf.len) {
                staging_buf[dst_idx] = pixels.items[src_idx];
            }
        }
    }
}

/// Fill a solid rectangle [x0, x1) × [y0, y1) in the staging buffer.
fn fillRect(buf: []u8, buf_w: i32, buf_h: i32, x0: i32, y0: i32, x1: i32, y1: i32) void {
    const cx0 = @max(0, x0);
    const cy0 = @max(0, y0);
    const cx1 = @min(buf_w, x1);
    const cy1 = @min(buf_h, y1);
    if (cx0 >= cx1 or cy0 >= cy1) return;
    var y = cy0;
    while (y < cy1) : (y += 1) {
        var x = cx0;
        while (x < cx1) : (x += 1) {
            buf[@intCast(y * buf_w + x)] = 255;
        }
    }
}

/// Render a block element character (U+2580–U+259F) geometrically.
/// Returns true if the character was handled, false if it should fall through
/// to the normal TrueType rasterizer.
fn renderBlockElement(
    cp: u21,
    buf: []u8,
    buf_w: i32,
    buf_h: i32,
    x0: i32,
    cw: i32,
    ch: i32,
) bool {
    if (cp < 0x2580 or cp > 0x259F) return false;

    const x1 = x0 + cw;
    const half_w = @divTrunc(cw, 2);
    const half_h = @divTrunc(ch, 2);
    const mid_x = x0 + half_w;

    switch (cp) {
        0x2580 => fillRect(buf, buf_w, buf_h, x0, 0, x1, half_h), // ▀ upper half
        0x2581 => fillRect(buf, buf_w, buf_h, x0, ch - @divTrunc(ch, 8), x1, ch), // ▁ lower 1/8
        0x2582 => fillRect(buf, buf_w, buf_h, x0, ch - @divTrunc(ch, 4), x1, ch), // ▂ lower 1/4
        0x2583 => fillRect(buf, buf_w, buf_h, x0, ch - @divTrunc(ch * 3, 8), x1, ch), // ▃ lower 3/8
        0x2584 => fillRect(buf, buf_w, buf_h, x0, ch - half_h, x1, ch), // ▄ lower half
        0x2585 => fillRect(buf, buf_w, buf_h, x0, ch - @divTrunc(ch * 5, 8), x1, ch), // ▅ lower 5/8
        0x2586 => fillRect(buf, buf_w, buf_h, x0, ch - @divTrunc(ch * 3, 4), x1, ch), // ▆ lower 3/4
        0x2587 => fillRect(buf, buf_w, buf_h, x0, ch - @divTrunc(ch * 7, 8), x1, ch), // ▇ lower 7/8
        0x2588 => fillRect(buf, buf_w, buf_h, x0, 0, x1, ch), // █ full block
        0x2589 => fillRect(buf, buf_w, buf_h, x0, 0, x0 + @divTrunc(cw * 7, 8), ch), // ▉ left 7/8
        0x258A => fillRect(buf, buf_w, buf_h, x0, 0, x0 + @divTrunc(cw * 3, 4), ch), // ▊ left 3/4
        0x258B => fillRect(buf, buf_w, buf_h, x0, 0, x0 + @divTrunc(cw * 5, 8), ch), // ▋ left 5/8
        0x258C => fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch), // ▌ left half
        0x258D => fillRect(buf, buf_w, buf_h, x0, 0, x0 + @divTrunc(cw * 3, 8), ch), // ▍ left 3/8
        0x258E => fillRect(buf, buf_w, buf_h, x0, 0, x0 + @divTrunc(cw, 4), ch), // ▎ left 1/4
        0x258F => fillRect(buf, buf_w, buf_h, x0, 0, x0 + @divTrunc(cw, 8), ch), // ▏ left 1/8
        0x2590 => fillRect(buf, buf_w, buf_h, mid_x, 0, x1, ch), // ▐ right half
        0x2591 => { // ░ light shade — approximate with alternating pixels
            var y: i32 = 0;
            while (y < ch) : (y += 1) {
                var x = x0 + @mod(y, 2);
                while (x < x1) : (x += 2) {
                    if (x >= 0 and x < buf_w and y >= 0 and y < buf_h)
                        buf[@intCast(y * buf_w + x)] = 255;
                }
            }
        },
        0x2592 => { // ▒ medium shade — alternate rows fully/empty
            var y: i32 = 0;
            while (y < ch) : (y += 2) {
                fillRect(buf, buf_w, buf_h, x0, y, x1, y + 1);
            }
        },
        0x2593 => { // ▓ dark shade — fill all except alternating sparse pixels
            fillRect(buf, buf_w, buf_h, x0, 0, x1, ch);
            var y: i32 = 0;
            while (y < ch) : (y += 2) {
                var x = x0 + @mod(y, 2);
                while (x < x1) : (x += 2) {
                    if (x >= 0 and x < buf_w and y >= 0 and y < buf_h)
                        buf[@intCast(y * buf_w + x)] = 0;
                }
            }
        },
        0x2594 => fillRect(buf, buf_w, buf_h, x0, 0, x1, @divTrunc(ch, 8)), // ▔ upper 1/8
        0x2595 => fillRect(buf, buf_w, buf_h, x1 - @divTrunc(cw, 8), 0, x1, ch), // ▕ right 1/8
        else => return false,
    }
    return true;
}
