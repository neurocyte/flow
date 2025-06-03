const std = @import("std");
const Plane = @import("renderer").Plane;
const Widget = @import("Widget.zig");

const px = "▀";

const Fire = @This();

allocator: std.mem.Allocator,
plane: Plane,
prng: std.Random.DefaultPrng,

//scope cache - spread fire
spread_px: u8 = 0,
spread_rnd_idx: u8 = 0,
spread_dst: usize = 0,

FIRE_H: u16,
FIRE_W: u16,
FIRE_SZ: usize,
FIRE_LAST_ROW: usize,

screen_buf: []u8,

const MAX_COLOR = 256;
const LAST_COLOR = MAX_COLOR - 1;

pub fn init(allocator: std.mem.Allocator, plane: Plane) !Fire {
    const pos = Widget.Box.from(plane);
    const FIRE_H = @as(u16, @intCast(pos.h)) * 2;
    const FIRE_W = @as(u16, @intCast(pos.w));
    var self: Fire = .{
        .allocator = allocator,
        .plane = plane,
        .prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        }),
        .FIRE_H = FIRE_H,
        .FIRE_W = FIRE_W,
        .FIRE_SZ = @as(usize, @intCast(FIRE_H)) * FIRE_W,
        .FIRE_LAST_ROW = @as(usize, @intCast(FIRE_H - 1)) * FIRE_W,
        .screen_buf = try allocator.alloc(u8, @as(usize, @intCast(FIRE_H)) * FIRE_W),
    };

    var buf_idx: usize = 0;
    while (buf_idx < self.FIRE_SZ) : (buf_idx += 1) {
        self.screen_buf[buf_idx] = fire_black;
    }

    // last row is white...white is "fire source"
    buf_idx = 0;
    while (buf_idx < self.FIRE_W) : (buf_idx += 1) {
        self.screen_buf[self.FIRE_LAST_ROW + buf_idx] = fire_white;
    }
    return self;
}

pub fn deinit(self: *Fire) void {
    self.allocator.free(self.screen_buf);
}

const fire_palette = [_]u8{ 0, 233, 234, 52, 53, 88, 89, 94, 95, 96, 130, 131, 132, 133, 172, 214, 215, 220, 220, 221, 3, 226, 227, 230, 195, 230 };
const fire_black: u8 = 0;
const fire_white: u8 = fire_palette.len - 1;

pub fn render(self: *Fire) void {
    self.plane.home();
    const transparent = self.plane.transparent;
    self.plane.transparent = false;
    defer self.plane.transparent = transparent;

    var rand = self.prng.random();

    //update fire buf
    var doFire_x: u16 = 0;
    while (doFire_x < self.FIRE_W) : (doFire_x += 1) {
        var doFire_y: u16 = 0;
        while (doFire_y < self.FIRE_H) : (doFire_y += 1) {
            const doFire_idx = @as(usize, @intCast(doFire_y)) * self.FIRE_W + doFire_x;

            //spread fire
            self.spread_px = self.screen_buf[doFire_idx];

            //bounds checking
            if ((self.spread_px == 0) and (doFire_idx >= self.FIRE_W)) {
                self.screen_buf[doFire_idx - self.FIRE_W] = 0;
            } else {
                self.spread_rnd_idx = rand.intRangeAtMost(u8, 0, 3);
                if (doFire_idx >= (self.spread_rnd_idx + 1)) {
                    self.spread_dst = doFire_idx - self.spread_rnd_idx + 1;
                } else {
                    self.spread_dst = doFire_idx;
                }
                if (self.spread_dst >= self.FIRE_W) {
                    if (self.spread_px > (self.spread_rnd_idx & 1)) {
                        self.screen_buf[self.spread_dst - self.FIRE_W] = self.spread_px - (self.spread_rnd_idx & 1);
                    } else {
                        self.screen_buf[self.spread_dst - self.FIRE_W] = 0;
                    }
                }
            }
        }
    }

    //scope cache - fire 2 screen buffer
    var frame_x: u16 = 0;
    var frame_y: u16 = 0;

    // for each row
    frame_y = 0;
    while (frame_y < self.FIRE_H) : (frame_y += 2) { // 'paint' two rows at a time because of half height char
        // for each col
        frame_x = 0;
        while (frame_x < self.FIRE_W) : (frame_x += 1) {
            //each character rendered is actually to rows of 'pixels'
            // - "hi" (current px row => fg char)
            // - "low" (next row => bg color)
            const px_hi = self.screen_buf[@as(usize, @intCast(frame_y)) * self.FIRE_W + frame_x];
            const px_lo = self.screen_buf[@as(usize, @intCast(frame_y + 1)) * self.FIRE_W + frame_x];

            self.plane.set_fg_palindex(fire_palette[px_hi]) catch {};
            self.plane.set_bg_palindex(fire_palette[px_lo]) catch {};
            _ = self.plane.putchar(px);
        }
        self.plane.cursor_move_yx(-1, 0) catch {};
        self.plane.cursor_move_rel(1, 0) catch {};
    }
}
