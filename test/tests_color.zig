const std = @import("std");
const color = @import("color");

const RGB = color.RGB;
const rgb = RGB.from_u24;

test "contrast white/yellow" {
    const a: u24 = 0xFFFFFF; // white
    const b: u24 = 0x00FFFF; // yellow
    const ratio = RGB.contrast(rgb(a), rgb(b));
    try std.testing.expectApproxEqAbs(ratio, 1.25388109, 0.000001);
}

test "contrast white/blue" {
    const a: u24 = 0xFFFFFF; // white
    const b: u24 = 0x0000FF; // blue
    const ratio = RGB.contrast(rgb(a), rgb(b));
    try std.testing.expectApproxEqAbs(ratio, 8.59247135, 0.000001);
}

test "contrast black/yellow" {
    const a: u24 = 0x000000; // black
    const b: u24 = 0x00FFFF; // yellow
    const ratio = RGB.contrast(rgb(a), rgb(b));
    try std.testing.expectApproxEqAbs(ratio, 16.7479991, 0.000001);
}

test "contrast black/blue" {
    const a: u24 = 0x000000; // black
    const b: u24 = 0x0000FF; // blue
    const ratio = RGB.contrast(rgb(a), rgb(b));
    try std.testing.expectApproxEqAbs(ratio, 2.444, 0.000001);
}

test "best contrast black/white to yellow" {
    const best = color.max_contrast(0x00FFFF, 0xFFFFFF, 0x000000);
    try std.testing.expectEqual(best, 0x000000);
}

test "best contrast black/white to blue" {
    const best = color.max_contrast(0x0000FF, 0xFFFFFF, 0x000000);
    try std.testing.expectEqual(best, 0xFFFFFF);
}
