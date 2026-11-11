const std = @import("std");
const ScrollAnimation = @import("tui").exports.ScrollAnimation;
const Pos = ScrollAnimation.Pos;

const eq = std.testing.expectEqual;
const expect = std.testing.expect;

const us_per_ms = std.time.us_per_ms;
const cell_px = 20;

fn timing(now_ms: i64) ScrollAnimation.Timing {
    return .{ .now_us = now_ms * us_per_ms, .min_lag_ms = 0, .max_lag_ms = 50, .curve = .linear };
}

fn at_ms(anim: *ScrollAnimation, now_ms: i64) Pos {
    anim.update(now_ms * us_per_ms, cell_px);
    return anim.pos;
}

test "scroll_animation glide reaches dest at the end of the lag" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(10), timing(10_000));
    try expect(anim.animating());
    // the max lag (50ms) is the duration, linear: half way at 25ms
    try eq(Pos{ .cell = 5 }, at_ms(&anim, 10_025));
    try eq(Pos.at(10), at_ms(&anim, 10_050));
    try expect(!anim.animating());
}

test "scroll_animation glide moves by pixels between cells" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(1), timing(10_000));
    try eq(Pos{ .cell = 0, .offset = 8 }, at_ms(&anim, 10_020));
}

test "scroll_animation glides up without overshoot" {
    var anim: ScrollAnimation = .{};
    anim.jump_to(.at(100));
    anim.glide_to(.at(3), timing(10_000));
    var now: i64 = 10_000;
    var prev = anim.pos;
    while (anim.animating()) : (now += 5) {
        const pos = at_ms(&anim, now);
        try expect(pos.order(prev) != .gt and pos.order(.at(3)) != .lt);
        prev = pos;
    }
    try eq(Pos.at(3), anim.pos);
}

test "scroll_animation a new glide continues from the current position" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(10), timing(10_000));
    _ = at_ms(&anim, 10_025);
    // 25ms after the previous glide, so this one takes 25ms
    anim.glide_to(.at(20), timing(10_025));
    try eq(Pos.at(5), at_ms(&anim, 10_025));
    // 12ms of 25ms, 100px + 0.48 * 300px = 244px
    try eq(Pos{ .cell = 12, .offset = 4 }, at_ms(&anim, 10_037));
    try eq(Pos.at(20), at_ms(&anim, 10_050));
}

test "scroll_animation quick repeats shorten the glide" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(3), timing(10_000));
    anim.glide_to(.at(6), timing(10_016));
    try eq(16 * us_per_ms, anim.motion.glide.duration_us);
}

test "scroll_animation min_lag above max_lag uses min_lag" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(60), .{ .now_us = 10 * std.time.us_per_s, .min_lag_ms = 500, .max_lag_ms = 50, .curve = .linear });
    try eq(500 * us_per_ms, anim.motion.glide.duration_us);
}

test "scroll_animation zero duration jumps at the next update" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(5), .{ .now_us = 10 * std.time.us_per_s, .min_lag_ms = 0, .max_lag_ms = 0, .curve = .ease_out_cubic });
    try eq(Pos.at(5), at_ms(&anim, 10_000));
    try expect(!anim.animating());
}

test "scroll_animation jump_to stops a glide" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(100), timing(10_000));
    _ = at_ms(&anim, 10_010);
    anim.jump_to(.at(7));
    try expect(!anim.animating());
    try eq(Pos.at(7), anim.pos);
}

test "scroll_animation clamp while animating" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(100), timing(10_000));
    _ = at_ms(&anim, 10_010);
    anim.clamp(.at(10));
    try eq(Pos.at(10), anim.dest());
    try expect(anim.pos.order(.at(10)) != .gt);
    try eq(Pos.at(10), at_ms(&anim, 10_050));
}

test "scroll_animation retarget keeps the glide timing" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(.at(10), timing(10_000));
    anim.retarget(.at(20));
    try eq(Pos.at(10), at_ms(&anim, 10_025));
    try eq(Pos.at(20), at_ms(&anim, 10_050));
}

test "scroll_animation an offset that does not fit a smaller cell rounds up" {
    var anim: ScrollAnimation = .{};
    anim.jump_to(.{ .cell = 4, .offset = 15 });
    anim.update(0, 16);
    try eq(Pos{ .cell = 4, .offset = 15 }, anim.pos);
    anim.update(0, 12);
    try eq(Pos.at(5), anim.pos);
}

test "scroll_animation curves at the start, the middle and the end" {
    const curves = [_]struct { ScrollAnimation.Curve, f64 }{
        .{ .linear, 0.5 },
        .{ .ease_out_quad, 0.75 },
        .{ .ease_out_cubic, 0.875 },
        .{ .ease_in_out_cubic, 0.5 },
    };
    for (curves) |c| {
        try eq(0.0, ScrollAnimation.ease(c[0], 0));
        try std.testing.expectApproxEqAbs(c[1], ScrollAnimation.ease(c[0], 0.5), 1e-9);
        try eq(1.0, ScrollAnimation.ease(c[0], 1));
    }
}
