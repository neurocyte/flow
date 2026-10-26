const std = @import("std");
const placement = @import("tui").exports.info_box_placement;

const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;

test "info_box_placement prefers the right if the box fits there" {
    try eqDeep(placement.Horizontal{ .side = .right, .x = 50, .w = 60 }, placement.horizontal(120, 30, 50, 60, 40));
}

test "info_box_placement goes left if only the left has room for the box" {
    try eqDeep(placement.Horizontal{ .side = .left, .x = 10, .w = 60 }, placement.horizontal(120, 70, 90, 60, 40));
}

test "info_box_placement wraps on the side with more room" {
    try eqDeep(placement.Horizontal{ .side = .right, .x = 50, .w = 50 }, placement.horizontal(100, 40, 50, 80, 40));
    try eqDeep(placement.Horizontal{ .side = .left, .x = 0, .w = 55 }, placement.horizontal(100, 55, 60, 80, 40));
}

test "info_box_placement has no side below the minimum width" {
    try eq(null, placement.horizontal(80, 30, 50, 60, 40));
}

test "info_box_placement clamped shifts the box left to stay on screen" {
    try eqDeep(placement.Horizontal{ .side = .right, .x = 20, .w = 60 }, placement.clamped(80, 50, 60));
    try eqDeep(placement.Horizontal{ .side = .right, .x = 0, .w = 80 }, placement.clamped(80, 50, 100));
    try eqDeep(placement.Horizontal{ .side = .right, .x = 5, .w = 30 }, placement.clamped(80, 5, 30));
}

test "info_box_placement vertical goes below if the box fits there" {
    try eqDeep(placement.Vertical{ .y = 11, .h = 8 }, placement.vertical(.{ .start = 11, .below = 9, .above_end = 10, .above = 10 }, 8));
}

test "info_box_placement vertical goes above if below is too small" {
    try eqDeep(placement.Vertical{ .y = 22, .h = 8 }, placement.vertical(.{ .start = 31, .below = 4, .above_end = 30, .above = 30 }, 8));
    try eqDeep(placement.Vertical{ .y = 0, .h = 6 }, placement.vertical(.{ .start = 7, .below = 4, .above_end = 6, .above = 6 }, 8));
}

test "info_box_placement vertical with no room above shrinks below" {
    try eqDeep(placement.Vertical{ .y = 30, .h = 4 }, placement.vertical(.{ .start = 30, .below = 4 }, 8));
}
