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

    // Block element characters, box-drawing, and related Unicode symbols are
    // rasterized geometrically rather than through the TrueType anti-aliasing path.
    // Anti-aliased edges produce partial-alpha pixels at cell boundaries, creating
    // visible seams between adjacent cells when fg ≠ bg.
    if (renderBlockElement(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;
    if (renderBoxDrawing(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;
    if (renderExtendedBlocks(codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch)) return;

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
    if (true) return false;
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
        0x2596 => fillRect(buf, buf_w, buf_h, x0, half_h, mid_x, ch), // ▖ lower-left quadrant
        0x2597 => fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch), // ▗ lower-right quadrant
        0x2598 => fillRect(buf, buf_w, buf_h, x0, 0, mid_x, half_h), // ▘ upper-left quadrant
        0x2599 => { // ▙ upper-left + lower-left + lower-right
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch);
            fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch);
        },
        0x259A => { // ▚ upper-left + lower-right (diagonal)
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, half_h);
            fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch);
        },
        0x259B => { // ▛ upper-left + upper-right + lower-left
            fillRect(buf, buf_w, buf_h, x0, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, x0, half_h, mid_x, ch);
        },
        0x259C => { // ▜ upper-left + upper-right + lower-right
            fillRect(buf, buf_w, buf_h, x0, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch);
        },
        0x259D => fillRect(buf, buf_w, buf_h, mid_x, 0, x1, half_h), // ▝ upper-right quadrant
        0x259E => { // ▞ upper-right + lower-left (diagonal)
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, x0, half_h, mid_x, ch);
        },
        0x259F => { // ▟ upper-right + lower-left + lower-right
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, x0, half_h, x1, ch);
        },
        else => return false,
    }
    return true;
}

/// Draw the stroke×stroke corner area for a rounded box-drawing corner (╭╮╯╰).
/// ╭╮╯╰ are identical to ┌┐└┘ in structure (L-shaped strokes meeting at center)
/// but with the sharp outer corner vertex rounded off by a circular clip.
///
/// Fills pixels in [x_start..x_end, y_start..y_end] where distance from
/// (corner_fx, corner_fy) is >= r_clip.  r_clip = max(0, stroke/2 - 0.5):
///   stroke=1 → r_clip=0 → all pixels filled (no visible rounding, ≡ sharp corner)
///   stroke=2 → r_clip=0.5 → clips the one diagonal corner pixel
///   stroke=3 → r_clip=1.0 → removes a 2-pixel notch, etc.
fn drawRoundedCornerArea(
    buf: []u8,
    buf_w: i32,
    x_start: i32,
    y_start: i32,
    x_end: i32,
    y_end: i32,
    corner_fx: f32,
    corner_fy: f32,
    r_clip: f32,
) void {
    const r2 = r_clip * r_clip;
    var cy: i32 = y_start;
    while (cy < y_end) : (cy += 1) {
        const dy: f32 = @as(f32, @floatFromInt(cy)) + 0.5 - corner_fy;
        var cx: i32 = x_start;
        while (cx < x_end) : (cx += 1) {
            const dx: f32 = @as(f32, @floatFromInt(cx)) + 0.5 - corner_fx;
            if (dx * dx + dy * dy >= r2) {
                const idx = cy * buf_w + cx;
                if (idx >= 0 and idx < @as(i32, @intCast(buf.len)))
                    buf[@intCast(idx)] = 255;
            }
        }
    }
}

/// Render a box-drawing character (U+2500–U+257F) geometrically.
fn renderBoxDrawing(
    cp: u21,
    buf: []u8,
    buf_w: i32,
    buf_h: i32,
    x0: i32,
    cw: i32,
    ch: i32,
) bool {
    if (cp < 0x2500 or cp > 0x257F) return false;

    const x1 = x0 + cw;

    // Single-line stroke thickness: base on cell width so horizontal and vertical
    // strokes appear equally thick (cells are typically ~2× taller than wide, so
    // using ch/8 would make horizontal strokes twice as thick as vertical ones).
    const stroke: i32 = @max(1, @divTrunc(cw, 8));

    // Single-line center positions
    const hy0: i32 = @divTrunc(ch - stroke, 2);
    const hy1: i32 = hy0 + stroke;
    const vx0: i32 = x0 + @divTrunc(cw - stroke, 2);
    const vx1: i32 = vx0 + stroke;

    // Double-line: two strokes offset from center by doff each side.
    // Use cw-based spacing for both so horizontal and vertical double lines
    // appear with the same visual gap regardless of cell aspect ratio.
    const doff: i32 = @max(stroke + 1, @divTrunc(cw, 4));
    const doff_h: i32 = doff;
    const doff_w: i32 = doff;
    // Horizontal double strokes (top = closer to top of cell):
    const dhy0t: i32 = @divTrunc(ch, 2) - doff_h;
    const dhy1t: i32 = dhy0t + stroke;
    const dhy0b: i32 = @divTrunc(ch, 2) + doff_h - stroke;
    const dhy1b: i32 = dhy0b + stroke;
    // Vertical double strokes (left = closer to left of cell):
    const dvx0l: i32 = x0 + @divTrunc(cw, 2) - doff_w;
    const dvx1l: i32 = dvx0l + stroke;
    const dvx0r: i32 = x0 + @divTrunc(cw, 2) + doff_w - stroke;
    const dvx1r: i32 = dvx0r + stroke;

    switch (cp) {
        // ─ light horizontal
        0x2500 => fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1),
        // │ light vertical
        0x2502 => fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch),
        // ┌ down+right (NW corner)
        0x250C => {
            fillRect(buf, buf_w, buf_h, vx0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy0, vx1, ch);
        },
        // ┐ down+left (NE corner)
        0x2510 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, vx1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy0, vx1, ch);
        },
        // └ up+right (SW corner)
        0x2514 => {
            fillRect(buf, buf_w, buf_h, vx0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy1);
        },
        // ┘ up+left (SE corner)
        0x2518 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, vx1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy1);
        },
        // ├ vertical + right
        0x251C => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, vx0, hy0, x1, hy1);
        },
        // ┤ vertical + left
        0x2524 => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, x0, hy0, vx1, hy1);
        },
        // ┬ horizontal + down
        0x252C => {
            fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy0, vx1, ch);
        },
        // ┴ horizontal + up
        0x2534 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy1);
        },
        // ┼ cross
        0x253C => {
            fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
        },
        // ═ double horizontal
        0x2550 => {
            fillRect(buf, buf_w, buf_h, x0, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, x1, dhy1b);
        },
        // ║ double vertical
        0x2551 => {
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, ch);
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, ch);
        },
        // ╔ double NW corner (down+right)
        0x2554 => {
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0t, x1, dhy1t); // outer horiz →
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0b, x1, dhy1b); // inner horiz →
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0t, dvx1l, ch); // outer vert ↓
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0b, dvx1r, ch); // inner vert ↓
        },
        // ╗ double NE corner (down+left)
        0x2557 => {
            fillRect(buf, buf_w, buf_h, x0, dhy0t, dvx1r, dhy1t); // outer horiz ←
            fillRect(buf, buf_w, buf_h, x0, dhy0b, dvx1l, dhy1b); // inner horiz ←
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0t, dvx1r, ch); // outer vert ↓
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0b, dvx1l, ch); // inner vert ↓
        },
        // ╚ double SW corner (up+right)
        0x255A => {
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0t, x1, dhy1t); // outer horiz →
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0b, x1, dhy1b); // inner horiz →
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, dhy1t); // outer vert ↑
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, dhy1b); // inner vert ↑
        },
        // ╝ double SE corner (up+left)
        0x255D => {
            fillRect(buf, buf_w, buf_h, x0, dhy0t, dvx1r, dhy1t); // outer horiz ←
            fillRect(buf, buf_w, buf_h, x0, dhy0b, dvx1l, dhy1b); // inner horiz ←
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, dhy1t); // outer vert ↑
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, dhy1b); // inner vert ↑
        },
        // ╞ single vert + double right
        0x255E => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, vx0, dhy0b, x1, dhy1b);
        },
        // ╡ single vert + double left
        0x2561 => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, x0, dhy0t, vx1, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, vx1, dhy1b);
        },
        // ╒ down single, right double
        0x2552 => {
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, vx1, ch); // single vert ↓
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, x1, dhy1t); // outer horiz →
            fillRect(buf, buf_w, buf_h, vx0, dhy0b, x1, dhy1b); // inner horiz →
        },
        // ╕ down single, left double
        0x2555 => {
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, vx1, ch); // single vert ↓
            fillRect(buf, buf_w, buf_h, x0, dhy0t, vx1, dhy1t); // outer horiz ←
            fillRect(buf, buf_w, buf_h, x0, dhy0b, vx1, dhy1b); // inner horiz ←
        },
        // ╘ up single, right double
        0x2558 => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, dhy1b); // single vert ↑
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, x1, dhy1t); // outer horiz →
            fillRect(buf, buf_w, buf_h, vx0, dhy0b, x1, dhy1b); // inner horiz →
        },
        // ╛ up single, left double
        0x255B => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, dhy1b); // single vert ↑
            fillRect(buf, buf_w, buf_h, x0, dhy0t, vx1, dhy1t); // outer horiz ←
            fillRect(buf, buf_w, buf_h, x0, dhy0b, vx1, dhy1b); // inner horiz ←
        },
        // ╓ down double, right single
        0x2553 => {
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, x1, hy1); // single horiz →
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, dvx1l, ch); // left double vert ↓
            fillRect(buf, buf_w, buf_h, dvx0r, hy0, dvx1r, ch); // right double vert ↓
        },
        // ╖ down double, left single
        0x2556 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, dvx1r, hy1); // single horiz ←
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, dvx1l, ch); // left double vert ↓
            fillRect(buf, buf_w, buf_h, dvx0r, hy0, dvx1r, ch); // right double vert ↓
        },
        // ╙ up double, right single
        0x2559 => {
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, x1, hy1); // single horiz →
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, hy1); // left double vert ↑
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, hy1); // right double vert ↑
        },
        // ╜ up double, left single
        0x255C => {
            fillRect(buf, buf_w, buf_h, x0, hy0, dvx1r, hy1); // single horiz ←
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, hy1); // left double vert ↑
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, hy1); // right double vert ↑
        },
        // ╭╮╯╰ rounded corners: same L-shape as ┌┐└┘ but with the outer
        // corner vertex clipped by a circle.  The corner area (vx0..vx1, hy0..hy1)
        // is drawn pixel-by-pixel; everything else uses fillRect.
        // r_clip = max(0, stroke/2 - 0.5): no rounding for 1px, small notch for 2px+.
        0x256D => { // ╭ NW: down+right
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, vx1, hy0, x1, hy1); // horizontal right of corner
            fillRect(buf, buf_w, buf_h, vx0, hy1, vx1, ch); // vertical below corner
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx0), @floatFromInt(hy0), r_clip);
        },
        0x256E => { // ╮ NE: down+left
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, x0, hy0, vx0, hy1); // horizontal left of corner
            fillRect(buf, buf_w, buf_h, vx0, hy1, vx1, ch); // vertical below corner
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx1), @floatFromInt(hy0), r_clip);
        },
        0x256F => { // ╯ SE: up+left
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, x0, hy0, vx0, hy1); // horizontal left of corner
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy0); // vertical above corner
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx1), @floatFromInt(hy1), r_clip);
        },
        0x2570 => { // ╰ SW: up+right
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, vx1, hy0, x1, hy1); // horizontal right of corner
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy0); // vertical above corner
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx0), @floatFromInt(hy1), r_clip);
        },
        else => return false,
    }
    return true;
}

/// Render extended block characters: U+1FB82 (upper quarter block), and the
/// specific sextant/octant corner characters used by WidgetStyle thick-box borders.
/// Each character is rendered with the geometric shape that tiles correctly with
/// its adjacent border characters (▌, ▐, ▀, ▄, 🮂, ▂).
fn renderExtendedBlocks(
    cp: u21,
    buf: []u8,
    buf_w: i32,
    buf_h: i32,
    x0: i32,
    cw: i32,
    ch: i32,
) bool {
    const x1 = x0 + cw;
    const mid_x = x0 + @divTrunc(cw, 2);
    const qh = @divTrunc(ch, 4); // quarter height (for octant thick-box)
    const th = @divTrunc(ch, 3); // third height (for sextant thick-box)

    switch (cp) {
        // 🮂 U+1FB82 upper one-quarter block (north edge of octant thick-box)
        0x1FB82 => fillRect(buf, buf_w, buf_h, x0, 0, x1, qh),

        // Sextant thick-box characters (WidgetStyle "thick box (sextant)")
        // .n = 🬂, .s = 🬭, .nw = 🬕, .ne = 🬨, .sw = 🬲, .se = 🬷
        // Edges connect to ▌ (left half) and ▐ (right half) for left/right walls.
        0x1FB02 => fillRect(buf, buf_w, buf_h, x0, 0, x1, th), // 🬂 top third (N edge)
        0x1FB2D => fillRect(buf, buf_w, buf_h, x0, ch - th, x1, ch), // 🬭 bottom third (S edge)
        0x1FB15 => { // 🬕 NW corner: left-half + top-third
            fillRect(buf, buf_w, buf_h, x0, 0, x1, th);
            fillRect(buf, buf_w, buf_h, x0, th, mid_x, ch);
        },
        0x1FB28 => { // 🬨 NE corner: right-half + top-third
            fillRect(buf, buf_w, buf_h, x0, 0, x1, th);
            fillRect(buf, buf_w, buf_h, mid_x, th, x1, ch);
        },
        0x1FB32 => { // 🬲 SW corner: left-half + bottom-third
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch - th);
            fillRect(buf, buf_w, buf_h, x0, ch - th, x1, ch);
        },
        0x1FB37 => { // 🬷 SE corner: right-half + bottom-third
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, ch - th);
            fillRect(buf, buf_w, buf_h, x0, ch - th, x1, ch);
        },

        // Octant thick-box corner characters (WidgetStyle "thick box (octant)")
        // .n = 🮂 (qh), .s = ▂ (qh), .w = ▌ (half), .e = ▐ (half)
        0x1CD4A => { // 𜵊 NW corner: left-half + top-quarter
            fillRect(buf, buf_w, buf_h, x0, 0, x1, qh);
            fillRect(buf, buf_w, buf_h, x0, qh, mid_x, ch);
        },
        0x1CD98 => { // 𜶘 NE corner: right-half + top-quarter
            fillRect(buf, buf_w, buf_h, x0, 0, x1, qh);
            fillRect(buf, buf_w, buf_h, mid_x, qh, x1, ch);
        },
        0x1CDD5 => { // 𜷕 SE corner: right-half + bottom-quarter
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, ch - qh);
            fillRect(buf, buf_w, buf_h, x0, ch - qh, x1, ch);
        },
        0x1CDC0 => { // 𜷀 SW corner: left-half + bottom-quarter
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch - qh);
            fillRect(buf, buf_w, buf_h, x0, ch - qh, x1, ch);
        },

        else => return false,
    }
    return true;
}
