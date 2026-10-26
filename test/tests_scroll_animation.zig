const std = @import("std");
const ScrollAnimation = @import("tui").exports.ScrollAnimation;

const eq = std.testing.expectEqual;

const us_per_ms = std.time.us_per_ms;

fn timing(now_ms: i64) ScrollAnimation.Timing {
    return .{ .now_us = now_ms * us_per_ms, .frame_rate = 60, .min_lag_ms = 0, .max_lag_ms = 50 };
}

fn run(anim: *ScrollAnimation) !usize {
    var frames: usize = 0;
    while (anim.animating()) : (frames += 1) {
        if (frames > 10_000) return error.NotConverging;
        const prev = anim.pos;
        anim.advance();
        try std.testing.expect(anim.pos != prev);
        try std.testing.expect(@min(prev, anim.dest) <= anim.pos and anim.pos <= @max(prev, anim.dest));
    }
    return frames;
}

test "scroll_animation glide reaches dest exactly" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(36, timing(10_000));
    const frames = try run(&anim);
    try eq(36, anim.pos);
    // max lag (50ms) at 60 fps is 3 frames
    try eq(3, frames);
    // a distance that does not divide evenly takes one more frame
    anim.glide_to(73, timing(20_000));
    try eq(4, try run(&anim));
    try eq(73, anim.pos);
}

test "scroll_animation glides up without overshoot" {
    var anim: ScrollAnimation = .{};
    anim.jump_to(100);
    anim.glide_to(3, timing(10_000));
    _ = try run(&anim);
    try eq(3, anim.pos);
}

test "scroll_animation step is at least 1" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(2, .{ .now_us = 10 * std.time.us_per_s, .frame_rate = 60, .min_lag_ms = 1000, .max_lag_ms = 1000 });
    try eq(1, anim.step);
    try eq(2, try run(&anim));
}

test "scroll_animation quick repeats shorten the lag" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(30, timing(10_000));
    try eq(10, anim.step);
    // 16ms after the previous glide: one frame
    anim.glide_to(60, timing(10_016));
    try eq(60, anim.step);
}

test "scroll_animation min_lag above max_lag uses min_lag" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(60, .{ .now_us = 10 * std.time.us_per_s, .frame_rate = 60, .min_lag_ms = 500, .max_lag_ms = 50 });
    try eq(2, anim.step);
}

test "scroll_animation zero frame_rate does not divide by zero" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(5, .{ .now_us = 10 * std.time.us_per_s, .frame_rate = 0, .min_lag_ms = 0, .max_lag_ms = 50 });
    try eq(5, anim.step);
}

test "scroll_animation jump_to stops a glide" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(100, timing(10_000));
    anim.advance();
    try std.testing.expect(anim.animating());
    anim.jump_to(7);
    try std.testing.expect(!anim.animating());
    try eq(7, anim.pos);
}

test "scroll_animation clamp while animating" {
    var anim: ScrollAnimation = .{};
    anim.glide_to(100, timing(10_000));
    anim.advance();
    anim.clamp(20);
    try eq(20, anim.dest);
    try std.testing.expect(anim.pos <= 20);
    _ = try run(&anim);
    try eq(20, anim.pos);
}
