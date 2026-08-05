const std = @import("std");
const vaxis = @import("vaxis");

/// Encode a mouse event and write it to the pty.
///
/// SGR (mode 1006): CSI < Cb ; Cx ; Cy M  (press/motion/drag)
///                  CSI < Cb ; Cx ; Cy m  (release)
///
/// SGR-Pixels (mode 1016): same framing as SGR, but Cx/Cy are pixel offsets
///   from the top-left of the terminal (`cell * cell_size + in-cell offset`).
///
/// Normal (X10):    ESC [ M <cb+32> <cx+32> <cy+32>
///   Limited to coordinates 1-223. Release uses button code 3.
pub fn encode(writer: *std.Io.Writer, m: vaxis.Mouse, sgr: bool, pixel: bool, cell_w: u16, cell_h: u16) !void {
    // Base button code per X10/SGR spec
    const btn_base: u8 = switch (m.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_right => 66,
        .wheel_left => 67,
        .button_8 => 128,
        .button_9 => 129,
        .button_10 => 130,
        .button_11 => 131,
    };

    // For release events in X10/normal mode, button code is always 3 regardless of button
    var cb: u8 = if (!sgr and m.type == .release) 3 else btn_base;

    // Modifier bits
    if (m.mods.shift) cb |= 4;
    if (m.mods.alt) cb |= 8;
    if (m.mods.ctrl) cb |= 16;
    // Motion/drag bit
    if (m.type == .motion or m.type == .drag) cb |= 32;

    // SGR-Pixels (mode 1016): pixel coordinates in the same SGR framing.
    if (pixel) {
        const px: i32 = @as(i32, m.col) * @as(i32, cell_w) + @as(i32, m.xoffset) + 1;
        const py: i32 = @as(i32, m.row) * @as(i32, cell_h) + @as(i32, m.yoffset) + 1;
        if (px < 1 or py < 1) return;
        const final: u8 = if (m.type == .release) 'm' else 'M';
        try writer.print("\x1b[<{d};{d};{d}{c}", .{ cb, px, py, final });
        return;
    }

    // 1-based cell coordinates
    const cx: i32 = m.col + 1;
    const cy: i32 = m.row + 1;
    if (cx < 1 or cy < 1) return;

    if (sgr) {
        // SGR encoding: press/motion/drag = 'M', release = 'm'
        const final: u8 = if (m.type == .release) 'm' else 'M';
        try writer.print("\x1b[<{d};{d};{d}{c}", .{ cb, cx, cy, final });
    } else {
        // X10/normal: ESC [ M <cb+32> <cx+32> <cy+32>
        // Coordinates must fit in a byte with +32 offset (max 223)
        if (cx > 223 or cy > 223) return;
        try writer.print("\x1b[M{c}{c}{c}", .{
            cb + 32,
            @as(u8, @intCast(cx + 32)),
            @as(u8, @intCast(cy + 32)),
        });
    }
}
