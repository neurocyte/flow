/// Geometric rendering of Unicode block elements, box-drawing, and extended
/// block characters.  These are rasterized as solid pixel fills rather than
/// through any font rasterizer, so they have no anti-aliased edges and tile
/// perfectly between adjacent cells.
///
/// All functions take the same parameter set:
///   cp      — Unicode codepoint
///   buf     — A8 staging buffer (width = buf_w, height = buf_h)
///   buf_w   — buffer row stride in pixels (always 2*cell_w for wide glyphs)
///   buf_h   — buffer height in pixels (= cell height)
///   x0      — left edge of this cell within buf (0 for left/single, cell_w for right)
///   cw, ch  — cell width / height in pixels
///
/// Returns true if the codepoint was handled, false to fall through to the
/// font rasterizer.
/// Fill a solid rectangle [x0, x1) × [y0, y1) in the staging buffer.
pub fn fillRect(buf: []u8, buf_w: i32, buf_h: i32, x0: i32, y0: i32, x1: i32, y1: i32) void {
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

/// Draw the stroke×stroke corner area for a rounded box-drawing corner (╭╮╯╰).
/// Fills pixels in [x_start..x_end, y_start..y_end] where distance from
/// (corner_fx, corner_fy) is >= r_clip.
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

/// Render a block element character (U+2580–U+259F) geometrically.
pub fn renderBlockElement(
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
        0x2591 => { // ░ light shade
            var y: i32 = 0;
            while (y < ch) : (y += 1) {
                var x = x0 + @mod(y, 2);
                while (x < x1) : (x += 2) {
                    if (x >= 0 and x < buf_w and y >= 0 and y < buf_h)
                        buf[@intCast(y * buf_w + x)] = 255;
                }
            }
        },
        0x2592 => { // ▒ medium shade
            var y: i32 = 0;
            while (y < ch) : (y += 2) {
                fillRect(buf, buf_w, buf_h, x0, y, x1, y + 1);
            }
        },
        0x2593 => { // ▓ dark shade
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
        0x2596 => fillRect(buf, buf_w, buf_h, x0, half_h, mid_x, ch), // ▖ lower-left
        0x2597 => fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch), // ▗ lower-right
        0x2598 => fillRect(buf, buf_w, buf_h, x0, 0, mid_x, half_h), // ▘ upper-left
        0x2599 => {
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch);
            fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch);
        },
        0x259A => {
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, half_h);
            fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch);
        },
        0x259B => {
            fillRect(buf, buf_w, buf_h, x0, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, x0, half_h, mid_x, ch);
        },
        0x259C => {
            fillRect(buf, buf_w, buf_h, x0, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, mid_x, half_h, x1, ch);
        },
        0x259D => fillRect(buf, buf_w, buf_h, mid_x, 0, x1, half_h), // ▝ upper-right
        0x259E => {
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, x0, half_h, mid_x, ch);
        },
        0x259F => {
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, half_h);
            fillRect(buf, buf_w, buf_h, x0, half_h, x1, ch);
        },
        else => return false,
    }
    return true;
}

/// Render a box-drawing character (U+2500–U+257F) geometrically.
pub fn renderBoxDrawing(
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

    const stroke: i32 = @max(1, @divTrunc(cw, 8));
    const hy0: i32 = @divTrunc(ch - stroke, 2);
    const hy1: i32 = hy0 + stroke;
    const vx0: i32 = x0 + @divTrunc(cw - stroke, 2);
    const vx1: i32 = vx0 + stroke;

    const doff: i32 = @max(stroke + 1, @divTrunc(cw, 4));
    const doff_h: i32 = doff;
    const doff_w: i32 = doff;
    const dhy0t: i32 = @divTrunc(ch, 2) - doff_h;
    const dhy1t: i32 = dhy0t + stroke;
    const dhy0b: i32 = @divTrunc(ch, 2) + doff_h - stroke;
    const dhy1b: i32 = dhy0b + stroke;
    const dvx0l: i32 = x0 + @divTrunc(cw, 2) - doff_w;
    const dvx1l: i32 = dvx0l + stroke;
    const dvx0r: i32 = x0 + @divTrunc(cw, 2) + doff_w - stroke;
    const dvx1r: i32 = dvx0r + stroke;

    switch (cp) {
        0x2500 => fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1),
        0x2502 => fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch),
        0x250C => {
            fillRect(buf, buf_w, buf_h, vx0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy0, vx1, ch);
        },
        0x2510 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, vx1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy0, vx1, ch);
        },
        0x2514 => {
            fillRect(buf, buf_w, buf_h, vx0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy1);
        },
        0x2518 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, vx1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy1);
        },
        0x251C => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, vx0, hy0, x1, hy1);
        },
        0x2524 => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, x0, hy0, vx1, hy1);
        },
        0x252C => {
            fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy0, vx1, ch);
        },
        0x2534 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy1);
        },
        0x253C => {
            fillRect(buf, buf_w, buf_h, x0, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
        },
        0x2550 => {
            fillRect(buf, buf_w, buf_h, x0, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, x1, dhy1b);
        },
        0x2551 => {
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, ch);
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, ch);
        },
        0x2554 => {
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0b, x1, dhy1b);
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0t, dvx1l, ch);
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0b, dvx1r, ch);
        },
        0x2557 => {
            fillRect(buf, buf_w, buf_h, x0, dhy0t, dvx1r, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, dvx1l, dhy1b);
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0t, dvx1r, ch);
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0b, dvx1l, ch);
        },
        0x255A => {
            fillRect(buf, buf_w, buf_h, dvx0l, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, dvx0r, dhy0b, x1, dhy1b);
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, dhy1t);
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, dhy1b);
        },
        0x255D => {
            fillRect(buf, buf_w, buf_h, x0, dhy0t, dvx1r, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, dvx1l, dhy1b);
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, dhy1t);
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, dhy1b);
        },
        0x255E => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, vx0, dhy0b, x1, dhy1b);
        },
        0x2561 => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, ch);
            fillRect(buf, buf_w, buf_h, x0, dhy0t, vx1, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, vx1, dhy1b);
        },
        0x2552 => {
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, vx1, ch);
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, vx0, dhy0b, x1, dhy1b);
        },
        0x2555 => {
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, vx1, ch);
            fillRect(buf, buf_w, buf_h, x0, dhy0t, vx1, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, vx1, dhy1b);
        },
        0x2558 => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, dhy1b);
            fillRect(buf, buf_w, buf_h, vx0, dhy0t, x1, dhy1t);
            fillRect(buf, buf_w, buf_h, vx0, dhy0b, x1, dhy1b);
        },
        0x255B => {
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, dhy1b);
            fillRect(buf, buf_w, buf_h, x0, dhy0t, vx1, dhy1t);
            fillRect(buf, buf_w, buf_h, x0, dhy0b, vx1, dhy1b);
        },
        0x2553 => {
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, dvx1l, ch);
            fillRect(buf, buf_w, buf_h, dvx0r, hy0, dvx1r, ch);
        },
        0x2556 => {
            fillRect(buf, buf_w, buf_h, x0, hy0, dvx1r, hy1);
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, dvx1l, ch);
            fillRect(buf, buf_w, buf_h, dvx0r, hy0, dvx1r, ch);
        },
        0x2559 => {
            fillRect(buf, buf_w, buf_h, dvx0l, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, hy1);
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, hy1);
        },
        0x255C => {
            fillRect(buf, buf_w, buf_h, x0, hy0, dvx1r, hy1);
            fillRect(buf, buf_w, buf_h, dvx0l, 0, dvx1l, hy1);
            fillRect(buf, buf_w, buf_h, dvx0r, 0, dvx1r, hy1);
        },
        0x256D => { // ╭ NW: down+right
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, vx1, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy1, vx1, ch);
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx0), @floatFromInt(hy0), r_clip);
        },
        0x256E => { // ╮ NE: down+left
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, x0, hy0, vx0, hy1);
            fillRect(buf, buf_w, buf_h, vx0, hy1, vx1, ch);
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx1), @floatFromInt(hy0), r_clip);
        },
        0x256F => { // ╯ SE: up+left
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, x0, hy0, vx0, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy0);
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx1), @floatFromInt(hy1), r_clip);
        },
        0x2570 => { // ╰ SW: up+right
            const r_clip: f32 = @max(0.0, @as(f32, @floatFromInt(stroke)) * 0.5 - 0.5);
            fillRect(buf, buf_w, buf_h, vx1, hy0, x1, hy1);
            fillRect(buf, buf_w, buf_h, vx0, 0, vx1, hy0);
            drawRoundedCornerArea(buf, buf_w, vx0, hy0, vx1, hy1, @floatFromInt(vx0), @floatFromInt(hy1), r_clip);
        },
        else => return false,
    }
    return true;
}

/// Render extended block characters used by WidgetStyle borders.
pub fn renderExtendedBlocks(
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
    const qh = @divTrunc(ch, 4);
    const th = @divTrunc(ch, 3);

    switch (cp) {
        0x1FB82 => fillRect(buf, buf_w, buf_h, x0, 0, x1, qh),
        0x1FB02 => fillRect(buf, buf_w, buf_h, x0, 0, x1, th),
        0x1FB2D => fillRect(buf, buf_w, buf_h, x0, ch - th, x1, ch),
        0x1FB15 => {
            fillRect(buf, buf_w, buf_h, x0, 0, x1, th);
            fillRect(buf, buf_w, buf_h, x0, th, mid_x, ch);
        },
        0x1FB28 => {
            fillRect(buf, buf_w, buf_h, x0, 0, x1, th);
            fillRect(buf, buf_w, buf_h, mid_x, th, x1, ch);
        },
        0x1FB32 => {
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch - th);
            fillRect(buf, buf_w, buf_h, x0, ch - th, x1, ch);
        },
        0x1FB37 => {
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, ch - th);
            fillRect(buf, buf_w, buf_h, x0, ch - th, x1, ch);
        },
        0x1CD4A => {
            fillRect(buf, buf_w, buf_h, x0, 0, x1, qh);
            fillRect(buf, buf_w, buf_h, x0, qh, mid_x, ch);
        },
        0x1CD98 => {
            fillRect(buf, buf_w, buf_h, x0, 0, x1, qh);
            fillRect(buf, buf_w, buf_h, mid_x, qh, x1, ch);
        },
        0x1CDD5 => {
            fillRect(buf, buf_w, buf_h, mid_x, 0, x1, ch - qh);
            fillRect(buf, buf_w, buf_h, x0, ch - qh, x1, ch);
        },
        0x1CDC0 => {
            fillRect(buf, buf_w, buf_h, x0, 0, mid_x, ch - qh);
            fillRect(buf, buf_w, buf_h, x0, ch - qh, x1, ch);
        },
        else => return false,
    }
    return true;
}
