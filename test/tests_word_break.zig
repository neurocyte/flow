const std = @import("std");
const word_break = @import("tui").exports.mode.word_break;

const WordClass = word_break.WordClass;

// Task V-2: word segmentation rules for the vim mode as pure functions.
// The cases below pin down the semantics of classify/ isWordBoundaryLeft /
// isWordBoundaryRight before the implementation lands in word_break.zig.

test "classify: letters, digits and underscore are word" {
    try std.testing.expectEqual(WordClass.word, word_break.classify("a"));
    try std.testing.expectEqual(WordClass.word, word_break.classify("Z"));
    try std.testing.expectEqual(WordClass.word, word_break.classify("0"));
    try std.testing.expectEqual(WordClass.word, word_break.classify("9"));
    try std.testing.expectEqual(WordClass.word, word_break.classify("_"));
}

test "classify: space and tab are separator" {
    try std.testing.expectEqual(WordClass.separator, word_break.classify(" "));
    try std.testing.expectEqual(WordClass.separator, word_break.classify("\t"));
}

test "classify: period, comma and parentheses are symbol" {
    try std.testing.expectEqual(WordClass.symbol, word_break.classify("."));
    try std.testing.expectEqual(WordClass.symbol, word_break.classify(","));
    try std.testing.expectEqual(WordClass.symbol, word_break.classify("("));
    try std.testing.expectEqual(WordClass.symbol, word_break.classify(")"));
}

test "classify: non-ASCII characters are word (approximation)" {
    // NOTE: approximation. Neovim treats non-ASCII punctuation as its own
    // symbol class (see the ceiling note in word_break.zig); here every
    // non-ASCII character is treated as word.
    try std.testing.expectEqual(WordClass.word, word_break.classify("é"));
    try std.testing.expectEqual(WordClass.word, word_break.classify("中"));
}

test "boundaries: dot in foo.bar is a boundary on both sides" {
    const text = "foo.bar";
    const dot = std.mem.indexOf(u8, text, ".").?;
    try std.testing.expect(word_break.isWordBoundaryLeft(text, dot));
    try std.testing.expect(word_break.isWordBoundaryRight(text, dot));
}

test "boundaries: inside foo there is no boundary" {
    const text = "foo";
    try std.testing.expect(!word_break.isWordBoundaryLeft(text, 1));
    try std.testing.expect(!word_break.isWordBoundaryRight(text, 1));
    try std.testing.expect(!word_break.isWordBoundaryLeft(text, 2));
    try std.testing.expect(!word_break.isWordBoundaryRight(text, 2));
}

test "boundaries: run of punctuation ... is one symbol segment" {
    const text = "a...b";
    const first_dot = std.mem.indexOf(u8, text, ".").?;
    const last_dot = std.mem.lastIndexOf(u8, text, ".").?;
    // boundary between the word char 'a' and the first '.', on both sides
    try std.testing.expect(word_break.isWordBoundaryLeft(text, first_dot));
    try std.testing.expect(word_break.isWordBoundaryRight(text, first_dot));
    // boundary between the last '.' and the word char 'b', on both sides
    try std.testing.expect(word_break.isWordBoundaryLeft(text, last_dot + 1));
    try std.testing.expect(word_break.isWordBoundaryRight(text, last_dot + 1));
    // middle of the run is not
    try std.testing.expect(!word_break.isWordBoundaryLeft(text, first_dot + 1));
    try std.testing.expect(!word_break.isWordBoundaryRight(text, first_dot + 1));
}

test "boundaries: empty string and out-of-range positions do not panic" {
    try std.testing.expect(!word_break.isWordBoundaryLeft("", 0));
    try std.testing.expect(!word_break.isWordBoundaryRight("", 0));
    try std.testing.expect(!word_break.isWordBoundaryLeft("foo", 99));
    try std.testing.expect(!word_break.isWordBoundaryRight("foo", 99));
    try std.testing.expect(!word_break.isWordBoundaryLeft("foo", 3));
    try std.testing.expect(!word_break.isWordBoundaryRight("foo", 3));
}

test "boundaries: position 0 is not a boundary (no char on the left)" {
    const text = "foo";
    try std.testing.expect(!word_break.isWordBoundaryLeft(text, 0));
    // looking right from 0: 'f' and 'o' are both word -> no boundary
    try std.testing.expect(!word_break.isWordBoundaryRight(text, 0));
}

test "boundaries: whitespace next to a word char is a boundary" {
    const text = "foo bar";
    const space = std.mem.indexOf(u8, text, " ").?;
    try std.testing.expect(word_break.isWordBoundaryLeft(text, space));
    try std.testing.expect(word_break.isWordBoundaryRight(text, space));
    try std.testing.expect(word_break.isWordBoundaryLeft(text, space + 1));
    try std.testing.expect(word_break.isWordBoundaryRight(text, space + 1));
}

test "boundaries: newline separates words" {
    const text = "foo\nbar";
    const nl = std.mem.indexOf(u8, text, "\n").?;
    try std.testing.expect(word_break.isWordBoundaryLeft(text, nl));
    try std.testing.expect(word_break.isWordBoundaryRight(text, nl));
}

test "boundaries: truncated multibyte sequence at end of text does not panic" {
    // Regression for ISSUE-2: a trailing incomplete UTF-8 sequence must not
    // panic. The leading byte 0xf0 announces a 4-byte char, but the string
    // ends after it, so the slice used to overshoot text.len.
    const s = "a\xf0";
    try std.testing.expect(!word_break.isWordBoundaryRight(s, 1));
    try std.testing.expect(!word_break.isWordBoundaryLeft(s, 1));
    try std.testing.expect(!word_break.isWordBoundaryRight(s, 2));
    try std.testing.expect(!word_break.isWordBoundaryLeft(s, 2));
}

test "boundaries: truncated multibyte sequence in the middle of text does not panic" {
    // 0xe4 announces a 3-byte char; only one continuation byte follows
    // before an ASCII char, so the sequence is truncated mid-text.
    const s = "a\xe4\xb7b";
    try std.testing.expect(!word_break.isWordBoundaryRight(s, 3));
    try std.testing.expect(!word_break.isWordBoundaryLeft(s, 3));
}
