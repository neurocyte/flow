//! Word segmentation rules for the vim mode, in the spirit of Neovim's word/WORD split.
//!
//! Pure functions over UTF-8 text: no editor state, no allocator, no I/O.
//! This module is intentionally NOT wired into the editor yet; wiring is a
//! follow-up task (the current editor heuristics live in
//! src/tui/editor.zig: is_word_boundary_left_vim / is_word_boundary_right_vim).
//!
//! ## Ceiling (what this does and does not cover)
//!
//! Current coverage:
//! - ASCII only for the word/symbol distinction: letters, digits and
//!   underscore are "word"; other ASCII punctuation is "symbol";
//!   space/tab/newline/carriage-return are "separator".
//! - Word boundaries are decided from the classes of the two characters
//!   adjacent to a byte position: a boundary exists when the two sides have
//!   different classes, or when either side is a separator. Only adjacent
//!   characters are inspected (no lookahead); out-of-range positions and
//!   position 0 return false instead of panicking, and so do truncated
//!   multibyte sequences (a leading byte without its full set of
//!   continuation bytes is clamped to the available input).
//!
//! Known divergence from Neovim:
//! - Every non-ASCII character is classified as "word", so non-ASCII
//!   punctuation (e.g. CJK full-width punctuation such as U+FF0C "," or
//!   U+3002 "?") is treated as part of a word instead of its own symbol
//!   class. This is a deliberate approximation.
//!
//! What Neovim actually does: for non-ASCII characters it consults a
//! hand-maintained table of codepoint ranges, `utf_class_tab()` in
//! src/nvim/mbyte.c — roughly 75 ranges, about 80 lines of C, compiled into
//! the binary at well under 4 KB, with no external data files and no
//! build-time generation. Its ASCII half just follows vim's 'iskeyword'
//! default of "@,48-57,_" (letters, digits, underscore), which is exactly
//! what this module's ASCII rule implements.
//!
//! To fully align with Neovim we would port that range table. Neither
//! Neovim nor vim derives these classes from the Unicode database — vim's
//! 'iskeyword' "@"/locale semantics are their own thing (e.g. "_" must
//! stay a word character no matter what). Until the range table is ported,
//! treat non-ASCII "word" as a deliberate approximation, not as a claim of
//! vim compatibility.

/// How a single character is classified when splitting text into words.
pub const WordClass = enum {
    /// Letters, digits and underscore. These make up a vim "word".
    word,
    /// Whitespace. A vim "WORD" is a run of non-whitespace.
    separator,
    /// Other punctuation. In vim these form their own word.
    symbol,
};

/// Classify one UTF-8 encoded character.
pub fn classify(char: []const u8) WordClass {
    if (char.len == 0) return .separator;
    const c = char[0];
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return .separator;
    if (c < 0x80) {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_') return .word;
        return .symbol;
    }
    // Non-ASCII: approximation, see the ceiling note above.
    return .word;
}

/// Length in bytes of the UTF-8 character starting at byte 0 of `text`.
fn utf8CharLen(text: []const u8) usize {
    const c = text[0];
    if (c < 0x80) return 1;
    if (c < 0xE0) return 2;
    if (c < 0xF0) return 3;
    return 4;
}

/// The character immediately to the left of `byte_pos`, or null when
/// `byte_pos` is 0 or past the end of `text`.
fn charLeft(text: []const u8, byte_pos: usize) ?[]const u8 {
    if (byte_pos == 0 or byte_pos > text.len) return null;
    var start = byte_pos - 1;
    while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
    return text[start..byte_pos];
}

/// The character starting at `byte_pos`, or null when `byte_pos` is past
/// the end of `text`. A truncated multibyte sequence (a leading byte
/// without its full set of continuation bytes) is clamped to the available
/// input instead of panicking; the caller sees the fragment as-is.
fn charRight(text: []const u8, byte_pos: usize) ?[]const u8 {
    if (byte_pos >= text.len) return null;
    const rest = text[byte_pos..];
    return rest[0..@min(utf8CharLen(rest), rest.len)];
}

/// True when the position at byte_pos starts a new word going left.
///
/// A boundary exists when the classes of the characters on either side
/// differ, or when either side is a separator. Only adjacent characters are
/// considered; positions 0 and >= text.len return false.
pub fn isWordBoundaryLeft(text: []const u8, byte_pos: usize) bool {
    const left = charLeft(text, byte_pos) orelse return false;
    const right = charRight(text, byte_pos) orelse return false;
    const left_class = classify(left);
    const right_class = classify(right);
    return left_class != right_class or left_class == .separator or right_class == .separator;
}

/// True when the position at byte_pos starts a new word going right.
///
/// Same definition as isWordBoundaryLeft, mirrored: the two functions only
/// differ in which side may be missing (position 0 has no left character,
/// position >= text.len has no right character).
pub fn isWordBoundaryRight(text: []const u8, byte_pos: usize) bool {
    const left = charLeft(text, byte_pos) orelse return false;
    const right = charRight(text, byte_pos) orelse return false;
    const left_class = classify(left);
    const right_class = classify(right);
    return left_class != right_class or left_class == .separator or right_class == .separator;
}
