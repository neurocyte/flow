const std = @import("std");

const Self = @This();

pos: usize = 0,
dest: usize = 0,
step: usize = 1,
last_time_us: i64 = 0,

pub const Timing = struct {
    now_us: i64,
    frame_rate: usize,
    min_lag_ms: usize,
    max_lag_ms: usize,
};

pub fn jump_to(self: *Self, pos: usize) void {
    self.pos = pos;
    self.dest = pos;
}

pub fn glide_to(self: *Self, dest: usize, timing: Timing) void {
    self.dest = dest;
    const elapsed: f64 = @as(f64, @floatFromInt(timing.now_us - self.last_time_us)) / std.time.us_per_s;
    self.last_time_us = timing.now_us;
    const lag = @max(@min(elapsed, lag_seconds(timing.max_lag_ms)), lag_seconds(timing.min_lag_ms));
    const frame_rate: f64 = @floatFromInt(@max(1, timing.frame_rate));
    const frames = @max(1.0, lag * frame_rate);
    const distance: f64 = @floatFromInt(@max(dest, self.pos) - @min(dest, self.pos));
    self.step = @max(1, @as(usize, @intFromFloat(distance / frames)));
}

fn lag_seconds(ms: usize) f64 {
    const ms_: f64 = @floatFromInt(ms);
    return @max(ms_ * 0.001, 0.001);
}

pub fn advance(self: *Self) void {
    self.pos = if (self.pos < self.dest)
        @min(self.dest, self.pos + self.step)
    else
        @max(self.dest, self.pos -| self.step);
}

pub fn animating(self: *const Self) bool {
    return self.pos != self.dest;
}

pub fn clamp(self: *Self, max: usize) void {
    self.pos = @min(self.pos, max);
    self.dest = @min(self.dest, max);
}
