//! CPU blits for the rasterizer backends.

const std = @import("std");

/// Half-open source column/row ranges that land inside the destination when a
/// gw*gh bitmap is placed at (dst_x0, dst_y0) in a buf_w*buf_h buffer. Clipping
/// once up front keeps the inner loops free of per-pixel bounds branches; with
/// the ranges applied, every destination index is provably in bounds.
pub const Range = struct { col0: i32, col1: i32, row0: i32, row1: i32 };

pub inline fn clip(buf_w: i32, buf_h: i32, gw: i32, gh: i32, dst_x0: i32, dst_y0: i32) Range {
    return .{
        .col0 = @max(0, -dst_x0),
        .col1 = @min(gw, buf_w - dst_x0),
        .row0 = @max(0, -dst_y0),
        .row1 = @min(gh, buf_h - dst_y0),
    };
}

/// Copy a tightly-packed 8-bit alpha bitmap (gw*gh bytes) into the red channel.
pub fn alpha8(staging: []u8, buf_w: i32, buf_h: i32, src: []const u8, gw: i32, gh: i32, dst_x0: i32, dst_y0: i32) void {
    if (gw <= 0 or gh <= 0) return;
    const r = clip(buf_w, buf_h, gw, gh, dst_x0, dst_y0);
    var row = r.row0;
    while (row < r.row1) : (row += 1) {
        const src_row: usize = @intCast(row * gw);
        const dst_row: usize = @intCast((dst_y0 + row) * buf_w);
        var col = r.col0;
        while (col < r.col1) : (col += 1) {
            staging[(dst_row + @as(usize, @intCast(dst_x0 + col))) * 4] = src[src_row + @as(usize, @intCast(col))];
        }
    }
}

/// Copy a tightly-packed 3-byte-per-pixel (subpixel) bitmap into RGB.
pub fn subpixel3(staging: []u8, buf_w: i32, buf_h: i32, src: []const u8, gw: i32, gh: i32, dst_x0: i32, dst_y0: i32) void {
    if (gw <= 0 or gh <= 0) return;
    const r = clip(buf_w, buf_h, gw, gh, dst_x0, dst_y0);
    var row = r.row0;
    while (row < r.row1) : (row += 1) {
        const src_row: usize = @as(usize, @intCast(row * gw)) * 3;
        const dst_row: usize = @intCast((dst_y0 + row) * buf_w);
        var col = r.col0;
        while (col < r.col1) : (col += 1) {
            const src_idx = src_row + @as(usize, @intCast(col)) * 3;
            const dst_idx = (dst_row + @as(usize, @intCast(dst_x0 + col))) * 4;
            staging[dst_idx + 0] = src[src_idx + 0];
            staging[dst_idx + 1] = src[src_idx + 1];
            staging[dst_idx + 2] = src[src_idx + 2];
        }
    }
}

/// Downscale-to-fit + bilinear blit of a color bitmap into the RGBA staging
/// buffer, centered within a target_w x buf_h area. Internal: callers use the
/// format-specific colorBGRA / colorRGBA wrappers below, which supply the
/// sampler. `sample(ctx, gw, gh, fx, fy)` returns RGBA at a fractional source
/// coordinate.
fn colorDownscale(
    staging: []u8,
    buf_w: i32,
    buf_h: i32,
    gw: i32,
    gh: i32,
    target_w: i32,
    ctx: anytype,
    comptime sample: fn (@TypeOf(ctx), i32, i32, f32, f32) [4]u8,
) void {
    if (gw <= 0 or gh <= 0) return;
    const s: f32 = @min(
        @as(f32, @floatFromInt(target_w)) / @as(f32, @floatFromInt(gw)),
        @as(f32, @floatFromInt(buf_h)) / @as(f32, @floatFromInt(gh)),
    );
    const sw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(gw)) * s))));
    const sh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(gh)) * s))));
    const dst_x0: i32 = @divTrunc(target_w - sw, 2);
    const dst_y0: i32 = @divTrunc(buf_h - sh, 2);
    const inv_s: f32 = 1.0 / s;
    const r = clip(buf_w, buf_h, sw, sh, dst_x0, dst_y0);
    var dy = r.row0;
    while (dy < r.row1) : (dy += 1) {
        const dst_row: usize = @intCast((dst_y0 + dy) * buf_w);
        const fsy = (@as(f32, @floatFromInt(dy)) + 0.5) * inv_s - 0.5;
        var dx = r.col0;
        while (dx < r.col1) : (dx += 1) {
            const fsx = (@as(f32, @floatFromInt(dx)) + 0.5) * inv_s - 0.5;
            const rgba = sample(ctx, gw, gh, fsx, fsy);
            const dst_idx = (dst_row + @as(usize, @intCast(dst_x0 + dx))) * 4;
            staging[dst_idx + 0] = rgba[0];
            staging[dst_idx + 1] = rgba[1];
            staging[dst_idx + 2] = rgba[2];
            staging[dst_idx + 3] = rgba[3];
        }
    }
}

/// Blit a tightly-packed alpha texture, choosing 1 byte/px (aliased) or 3
/// bytes/px (ClearType subpixel) packing. Dispatch helper for backends whose
/// texture format is only known at runtime.
pub fn packedTexture(staging: []u8, buf_w: i32, buf_h: i32, src: []const u8, gw: i32, gh: i32, dst_x0: i32, dst_y0: i32, subpixel: bool) void {
    if (subpixel)
        subpixel3(staging, buf_w, buf_h, src, gw, gh, dst_x0, dst_y0)
    else
        alpha8(staging, buf_w, buf_h, src, gw, gh, dst_x0, dst_y0);
}

/// Copy a pitched 8-bit-coverage bitmap into the red channel. `mono` selects a
/// 1-bit-per-pixel (MSB-first) source unpack instead of 1-byte-per-pixel; used
/// for FreeType bitmaps, which are row-pitched and may be bit-packed.
pub fn alphaPitched(staging: []u8, buf_w: i32, buf_h: i32, src: [*c]const u8, pitch: u32, gw: i32, gh: i32, dst_x0: i32, dst_y0: i32, mono: bool) void {
    if (gw <= 0 or gh <= 0) return;
    const r = clip(buf_w, buf_h, gw, gh, dst_x0, dst_y0);
    var row = r.row0;
    while (row < r.row1) : (row += 1) {
        const src_row: usize = @as(usize, @intCast(row)) * pitch;
        const dst_row: usize = @intCast((dst_y0 + row) * buf_w);
        var col = r.col0;
        while (col < r.col1) : (col += 1) {
            const ucol: u32 = @intCast(col);
            const px: u8 = if (mono) blk: {
                // 1 bit per pixel, MSB first within each byte.
                const byte = src[src_row + (ucol >> 3)];
                const bit: u3 = @intCast(7 - (ucol & 7));
                break :blk if ((byte >> bit) & 1 != 0) 0xFF else 0x00;
            } else src[src_row + ucol];
            staging[(dst_row + @as(usize, @intCast(dst_x0 + col))) * 4] = px;
        }
    }
}

/// Downscale-to-fit + bilinear blit of a pitched BGRA source into the staging
/// buffer (swizzling to RGBA), centered within a target_w x buf_h area.
pub fn colorBGRA(staging: []u8, buf_w: i32, buf_h: i32, src: [*c]const u8, pitch: u32, gw: i32, gh: i32, target_w: i32) void {
    const Ctx = struct { src: [*c]const u8, pitch: u32 };
    colorDownscale(staging, buf_w, buf_h, gw, gh, target_w, Ctx{ .src = src, .pitch = pitch }, struct {
        fn sample(cx: Ctx, w: i32, h: i32, fx: f32, fy: f32) [4]u8 {
            return sampleBGRA(cx.src, w, h, cx.pitch, fx, fy);
        }
    }.sample);
}

/// Downscale-to-fit + bilinear blit of a tightly-packed RGBA source into the
/// staging buffer, centered within a target_w x buf_h area.
pub fn colorRGBA(staging: []u8, buf_w: i32, buf_h: i32, src: []const u8, gw: i32, gh: i32, target_w: i32) void {
    colorDownscale(staging, buf_w, buf_h, gw, gh, target_w, src, struct {
        fn sample(s: []const u8, w: i32, h: i32, fx: f32, fy: f32) [4]u8 {
            return sampleRGBA(s, w, h, fx, fy);
        }
    }.sample);
}

fn bgraChannel(src: [*c]const u8, gw: i32, gh: i32, pitch: u32, x: i32, y: i32, ch: usize) u8 {
    const cx: u32 = @intCast(std.math.clamp(x, 0, gw - 1));
    const cy: u32 = @intCast(std.math.clamp(y, 0, gh - 1));
    return src[cy * pitch + cx * 4 + ch];
}

fn sampleBGRA(src: [*c]const u8, gw: i32, gh: i32, pitch: u32, fx: f32, fy: f32) [4]u8 {
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const tx: f32 = fx - @floor(fx);
    const ty: f32 = fy - @floor(fy);
    const src_ch = [4]usize{ 2, 1, 0, 3 };
    var out: [4]u8 = undefined;
    inline for (0..4) |oc| {
        const sc = src_ch[oc];
        const c00: f32 = @floatFromInt(bgraChannel(src, gw, gh, pitch, x0, y0, sc));
        const c10: f32 = @floatFromInt(bgraChannel(src, gw, gh, pitch, x0 + 1, y0, sc));
        const c01: f32 = @floatFromInt(bgraChannel(src, gw, gh, pitch, x0, y0 + 1, sc));
        const c11: f32 = @floatFromInt(bgraChannel(src, gw, gh, pitch, x0 + 1, y0 + 1, sc));
        const top = c00 * (1 - tx) + c10 * tx;
        const bot = c01 * (1 - tx) + c11 * tx;
        out[oc] = @intFromFloat(@round(std.math.clamp(top * (1 - ty) + bot * ty, 0, 255)));
    }
    return out;
}

fn rgbaChannel(src: []const u8, gw: i32, gh: i32, x: i32, y: i32, ch: usize) u8 {
    const cx: i32 = std.math.clamp(x, 0, gw - 1);
    const cy: i32 = std.math.clamp(y, 0, gh - 1);
    return src[@intCast((cy * gw + cx) * 4 + @as(i32, @intCast(ch)))];
}

fn sampleRGBA(src: []const u8, gw: i32, gh: i32, fx: f32, fy: f32) [4]u8 {
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const tx: f32 = fx - @floor(fx);
    const ty: f32 = fy - @floor(fy);
    var out: [4]u8 = undefined;
    inline for (0..4) |ch| {
        const c00: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0, y0, ch));
        const c10: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0 + 1, y0, ch));
        const c01: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0, y0 + 1, ch));
        const c11: f32 = @floatFromInt(rgbaChannel(src, gw, gh, x0 + 1, y0 + 1, ch));
        const top = c00 * (1 - tx) + c10 * tx;
        const bot = c01 * (1 - tx) + c11 * tx;
        out[ch] = @intFromFloat(@round(std.math.clamp(top * (1 - ty) + bot * ty, 0, 255)));
    }
    return out;
}
