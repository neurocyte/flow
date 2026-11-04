//! The key that a chord (ctrl, alt or super) reports, from the keyboard layout and the physical key.
//! It follows the Windows virtual-key model: letters follow the layout, the digit row keeps its digits,
//! and the other keys follow the layout if it gives a printable ASCII character.

pub const Key = struct {
    codepoint: u21,
    shifted: u21,
};

/// `char` and `shifted_char` come from the layout (0 if unknown), `physical` and
/// `physical_shifted` are the US PC-101 characters at the key's position.
pub fn chord_key(char: u21, shifted_char: u21, physical: u21, physical_shifted: u21) Key {
    if (is_letter(char)) {
        const lower = char | 0x20;
        return .{ .codepoint = lower, .shifted = if (shifted_char != 0) shifted_char else lower - 0x20 };
    }
    if (physical >= '0' and physical <= '9')
        return .{ .codepoint = physical, .shifted = physical_shifted };
    if (char > ' ' and char < 0x7f)
        return .{ .codepoint = char, .shifted = if (shifted_char != 0) shifted_char else char };
    return .{ .codepoint = physical, .shifted = physical_shifted };
}

fn is_letter(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

const std = @import("std");

fn expect_key(expected: Key, actual: Key) !void {
    try std.testing.expectEqual(expected.codepoint, actual.codepoint);
    try std.testing.expectEqual(expected.shifted, actual.shifted);
}

test "letters follow the layout" {
    // German QWERTZ: the key labelled Z sits at the US Y position
    try expect_key(.{ .codepoint = 'z', .shifted = 'Z' }, chord_key('z', 'Z', 'y', 'Y'));
    // Dvorak: the key labelled Q sits at the US X position
    try expect_key(.{ .codepoint = 'q', .shifted = 'Q' }, chord_key('q', 'Q', 'x', 'X'));
    // an upper case layout character and an unknown shifted character
    try expect_key(.{ .codepoint = 'a', .shifted = 'A' }, chord_key('A', 0, 'q', 'Q'));
}

test "the digit row keeps its digits" {
    // French AZERTY: the 1 key gives & without shift
    try expect_key(.{ .codepoint = '1', .shifted = '!' }, chord_key('&', '1', '1', '!'));
    // é is not ASCII, the physical digit wins anyway
    try expect_key(.{ .codepoint = '2', .shifted = '@' }, chord_key(0xe9, '2', '2', '@'));
}

test "other keys follow the layout if it gives ASCII" {
    // Dvorak: the key labelled ' sits at the US Q position
    try expect_key(.{ .codepoint = '\'', .shifted = '"' }, chord_key('\'', '"', 'q', 'Q'));
    // German on an Apple ISO keyboard: ^ (a dead key) left of 1
    try expect_key(.{ .codepoint = '^', .shifted = 0xb0 }, chord_key('^', 0xb0, '`', '~'));
    // German: the key labelled - sits at the US / position
    try expect_key(.{ .codepoint = '-', .shifted = '_' }, chord_key('-', '_', '/', '?'));
}

test "the physical key is the fallback" {
    // German: ö sits at the US ; position
    try expect_key(.{ .codepoint = ';', .shifted = ':' }, chord_key(0xf6, 0xd6, ';', ':'));
    // Russian: с sits at the US C position
    try expect_key(.{ .codepoint = 'c', .shifted = 'C' }, chord_key(0x441, 0x421, 'c', 'C'));
    // no layout information
    try expect_key(.{ .codepoint = 'y', .shifted = 'Y' }, chord_key(0, 0, 'y', 'Y'));
    try expect_key(.{ .codepoint = '7', .shifted = '&' }, chord_key(0, 0, '7', '&'));
    // space is not taken from the layout
    try expect_key(.{ .codepoint = ' ', .shifted = ' ' }, chord_key(' ', ' ', ' ', ' '));
}
