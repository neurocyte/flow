const std = @import("std");

pub const Curve = @import("config").ScrollAnimationCurve;

const Self = @This();

pos: Pos = .{},
motion: Motion = .none,
last_glide_us: i64 = 0,

pub const Pos = struct {
    cell: usize = 0,
    offset: u16 = 0,

    pub fn at(cell: usize) Pos {
        return .{ .cell = cell };
    }

    pub fn order(a: Pos, b: Pos) std.math.Order {
        return switch (std.math.order(a.cell, b.cell)) {
            .eq => std.math.order(a.offset, b.offset),
            else => |o| o,
        };
    }

    pub fn eql(a: Pos, b: Pos) bool {
        return a.order(b) == .eq;
    }

    pub fn min(a: Pos, b: Pos) Pos {
        return if (a.order(b) == .gt) b else a;
    }

    pub fn fit(self: Pos, cell_px: u16) Pos {
        return if (self.offset >= cell_px) .{ .cell = self.cell + 1 } else self;
    }

    pub fn to_px(self: Pos, cell_px: u16) i64 {
        return @as(i64, @intCast(self.cell)) * cell_px + self.offset;
    }

    pub fn from_px(px: i64, cell_px: u16) Pos {
        const size: i64 = @max(1, cell_px);
        const clamped = @max(0, px);
        return .{ .cell = @intCast(@divFloor(clamped, size)), .offset = @intCast(@mod(clamped, size)) };
    }
};

pub const Motion = union(enum) {
    none,
    glide: Glide,
};

pub const Glide = struct {
    from: Pos,
    dest: Pos,
    start_us: i64,
    duration_us: i64,
    curve: Curve,

    pub fn pos_at(self: Glide, now_us: i64, cell_px: u16) Pos {
        if (self.done(now_us)) return self.dest;
        const elapsed: f64 = @floatFromInt(@max(0, now_us - self.start_us));
        const t = elapsed / @as(f64, @floatFromInt(self.duration_us));
        const from_px: f64 = @floatFromInt(self.from.to_px(cell_px));
        const dest_px: f64 = @floatFromInt(self.dest.to_px(cell_px));
        return Pos.from_px(@intFromFloat(@round(from_px + (dest_px - from_px) * ease(self.curve, t))), cell_px);
    }

    pub fn done(self: Glide, now_us: i64) bool {
        return now_us - self.start_us >= self.duration_us;
    }
};

pub const Timing = struct {
    now_us: i64,
    min_lag_ms: usize,
    max_lag_ms: usize,
    curve: Curve,
};

pub fn ease(curve: Curve, t_: f64) f64 {
    const t = std.math.clamp(t_, 0, 1);
    return switch (curve) {
        .linear => t,
        .ease_out_quad => 1 - (1 - t) * (1 - t),
        .ease_out_cubic => 1 - (1 - t) * (1 - t) * (1 - t),
        .ease_in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2,
    };
}

pub fn dest(self: *const Self) Pos {
    return switch (self.motion) {
        .none => self.pos,
        .glide => |g| g.dest,
    };
}

pub fn animating(self: *const Self) bool {
    return self.motion != .none;
}

pub fn jump_to(self: *Self, pos: Pos) void {
    self.pos = pos;
    self.motion = .none;
}

pub fn glide_to(self: *Self, dest_: Pos, timing: Timing) void {
    const elapsed_us = timing.now_us - self.last_glide_us;
    self.last_glide_us = timing.now_us;
    if (self.pos.eql(dest_)) {
        self.motion = .none;
        return;
    }
    const min_lag_us: i64 = @intCast(timing.min_lag_ms * std.time.us_per_ms);
    const max_lag_us: i64 = @intCast(timing.max_lag_ms * std.time.us_per_ms);
    self.motion = .{ .glide = .{
        .from = self.pos,
        .dest = dest_,
        .start_us = timing.now_us,
        .duration_us = @max(@min(elapsed_us, max_lag_us), min_lag_us),
        .curve = timing.curve,
    } };
}

pub fn retarget(self: *Self, dest_: Pos) void {
    switch (self.motion) {
        .none => self.jump_to(dest_),
        .glide => |*g| g.dest = dest_,
    }
}

pub fn update(self: *Self, now_us: i64, cell_px: u16) void {
    self.fit(cell_px);
    switch (self.motion) {
        .none => {},
        .glide => |g| {
            self.pos = g.pos_at(now_us, cell_px);
            if (g.done(now_us)) self.motion = .none;
        },
    }
}

pub fn fit(self: *Self, cell_px: u16) void {
    self.pos = self.pos.fit(cell_px);
    switch (self.motion) {
        .none => {},
        .glide => |*g| {
            g.from = g.from.fit(cell_px);
            g.dest = g.dest.fit(cell_px);
        },
    }
}

pub fn clamp(self: *Self, max: Pos) void {
    self.pos = self.pos.min(max);
    switch (self.motion) {
        .none => {},
        .glide => |*g| {
            g.from = g.from.min(max);
            g.dest = g.dest.min(max);
            if (self.pos.eql(g.dest)) self.motion = .none;
        },
    }
}
