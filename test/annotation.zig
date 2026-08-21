//! Helix-style selection annotations for test fixtures.
//!
//! A fixture is the document text with the primary selection marked inline,
//! using the same syntax as helix's test suite (helix-core/src/test.rs), so
//! upstream helix test cases can be transcribed verbatim:
//!
//!   #[foo|]#   selection covering "foo", head after the anchor (forward)
//!   #[|foo]#   selection covering "foo", head before the anchor (reversed)
//!   #[|]#      zero-width cursor
//!
//! `parse` strips the markers and returns the plain text plus the anchor and
//! head positions; `render` reinserts markers, so a whole assertion is one
//! `expectEqualStrings` and a failure shows the full annotated document.
//!
//! Positions are (row, col) in characters. ASCII fixtures only: columns are
//! byte offsets within the line, matching the identity metrics the flow test
//! suite uses.
//!
//! A malformed fixture is always a hard error, never a best-effort parse.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pos = struct {
    row: usize,
    col: usize,

    pub fn before(self: Pos, other: Pos) bool {
        return self.row < other.row or (self.row == other.row and self.col < other.col);
    }
};

pub const Error = error{
    MissingSelection,
    MultipleSelections,
    UnterminatedSelection,
    MalformedSelection,
    OutOfMemory,
};

pub const Annotated = struct {
    alloc: Allocator,
    /// The document with markers stripped.
    text: []u8,
    anchor: Pos,
    head: Pos,

    pub fn deinit(self: *Annotated) void {
        self.alloc.free(self.text);
    }

    /// The position a point cursor sits at: the start of the selection, so a
    /// one-character selection `#[x|]#` reads as "the cursor is on x".
    pub fn cursor(self: *const Annotated) Pos {
        return if (self.head.before(self.anchor)) self.head else self.anchor;
    }
};

pub fn parse(alloc: Allocator, src: []const u8) Error!Annotated {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);

    var anchor: ?Pos = null;
    var head: ?Pos = null;
    var open: ?Pos = null; // position where "#[" was seen
    var reversed = false;

    var pos: Pos = .{ .row = 0, .col = 0 };
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "#[")) {
            if (open != null) return Error.MalformedSelection;
            if (anchor != null) return Error.MultipleSelections;
            open = pos;
            i += 2;
            if (std.mem.startsWith(u8, src[i..], "|")) {
                reversed = true;
                head = pos;
                i += 1;
            }
            continue;
        }
        if (open != null and !reversed and std.mem.startsWith(u8, src[i..], "|]#")) {
            anchor = open.?;
            head = pos;
            open = null;
            i += 3;
            continue;
        }
        if (open != null and reversed and std.mem.startsWith(u8, src[i..], "]#")) {
            anchor = pos;
            open = null;
            i += 2;
            continue;
        }
        try text.append(alloc, src[i]);
        if (src[i] == '\n') {
            pos.row += 1;
            pos.col = 0;
        } else {
            pos.col += 1;
        }
        i += 1;
    }

    if (open != null) return Error.UnterminatedSelection;
    if (anchor == null) return Error.MissingSelection;

    return .{
        .alloc = alloc,
        .text = try text.toOwnedSlice(alloc),
        .anchor = anchor.?,
        .head = head.?,
    };
}

/// Split a before/after test case on its `=>` separator line. A blank line
/// cannot be the separator: fixture documents may contain blank lines.
pub fn splitCase(src: []const u8) error{ MissingSeparator, MultipleSeparators }!struct {
    input: []const u8,
    expected: []const u8,
} {
    const sep = "\n=>\n";
    const idx = std.mem.indexOf(u8, src, sep) orelse return error.MissingSeparator;
    if (std.mem.indexOfPos(u8, src, idx + sep.len, sep) != null) return error.MultipleSeparators;
    return .{ .input = src[0..idx], .expected = src[idx + sep.len ..] };
}

/// Both positions must lie within `text`; one past the final character is
/// the highest valid position.
pub fn render(alloc: Allocator, text: []const u8, anchor: Pos, head: Pos) Allocator.Error![]u8 {
    const forward = !head.before(anchor);
    const first = if (forward) anchor else head;
    const last = if (forward) head else anchor;
    const first_off = posToOffset(text, first) orelse unreachable;
    const last_off = posToOffset(text, last) orelse unreachable;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, text[0..first_off]);
    try out.appendSlice(alloc, if (forward) "#[" else "#[|");
    try out.appendSlice(alloc, text[first_off..last_off]);
    try out.appendSlice(alloc, if (forward) "|]#" else "]#");
    try out.appendSlice(alloc, text[last_off..]);
    return out.toOwnedSlice(alloc);
}

fn posToOffset(text: []const u8, pos: Pos) ?usize {
    var cur: Pos = .{ .row = 0, .col = 0 };
    for (text, 0..) |c, off| {
        if (cur.row == pos.row and cur.col == pos.col) return off;
        if (c == '\n') {
            cur.row += 1;
            cur.col = 0;
        } else {
            cur.col += 1;
        }
    }
    // One past the end is a valid marker position.
    if (cur.row == pos.row and cur.col == pos.col) return text.len;
    return null;
}

const a = std.testing.allocator;

fn expect_round_trip(src: []const u8, text: []const u8, anchor: Pos, head: Pos) !void {
    var ann = try parse(a, src);
    defer ann.deinit();
    try std.testing.expectEqualStrings(text, ann.text);
    try std.testing.expectEqual(anchor, ann.anchor);
    try std.testing.expectEqual(head, ann.head);
    const rendered = try render(a, ann.text, ann.anchor, ann.head);
    defer a.free(rendered);
    try std.testing.expectEqualStrings(src, rendered);
}

test "annotation round trips" {
    try expect_round_trip("#[foo|]# bar", "foo bar", .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 3 });
    try expect_round_trip("f#[|oo]# bar", "foo bar", .{ .row = 0, .col = 3 }, .{ .row = 0, .col = 1 });
    try expect_round_trip("foo #[|]#bar", "foo bar", .{ .row = 0, .col = 4 }, .{ .row = 0, .col = 4 });
    try expect_round_trip("foo bar#[|]#", "foo bar", .{ .row = 0, .col = 7 }, .{ .row = 0, .col = 7 });
    try expect_round_trip("one\ntw#[o\nthr|]#ee", "one\ntwo\nthree", .{ .row = 1, .col = 2 }, .{ .row = 2, .col = 3 });
}

test "splitCase" {
    const case = try splitCase("a#[b|]#c\n=>\n#[abc|]#");
    try std.testing.expectEqualStrings("a#[b|]#c", case.input);
    try std.testing.expectEqualStrings("#[abc|]#", case.expected);
    try std.testing.expectError(error.MissingSeparator, splitCase("a\n\nb"));
    try std.testing.expectError(error.MultipleSeparators, splitCase("a\n=>\nb\n=>\nc"));
}

test "annotation rejects malformed fixtures" {
    try std.testing.expectError(Error.MissingSelection, parse(a, "no markers"));
    try std.testing.expectError(Error.UnterminatedSelection, parse(a, "#[foo"));
    try std.testing.expectError(Error.MultipleSelections, parse(a, "#[a|]# #[b|]#"));
    try std.testing.expectError(Error.MalformedSelection, parse(a, "#[a #[b|]#"));
}

fn fuzz_render_inverts_parse(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    // Weighted toward the marker alphabet so random inputs actually form
    // (and nearly form) selections instead of being all plain text.
    var buf: [256]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 2),
        .value(u8, '#', 8),
        .value(u8, '[', 8),
        .value(u8, '|', 8),
        .value(u8, ']', 8),
        .value(u8, '\n', 4),
        .value(u8, '\\', 2),
    });
    const input = buf[0..len];

    // Rejecting an input is always fine; accepting one obliges render to
    // invert parse exactly.
    var ann = parse(a, input) catch return;
    defer ann.deinit();
    const rendered = try render(a, ann.text, ann.anchor, ann.head);
    defer a.free(rendered);
    try std.testing.expectEqualStrings(input, rendered);
}

test "annotation fuzz: render inverts parse" {
    try std.testing.fuzz({}, fuzz_render_inverts_parse, .{ .corpus = &.{
        "#[foo|]# bar",
        "f#[|oo]# bar",
        "one\ntw#[o\nthr|]#ee",
        "#[|]#",
        "a \"b \\\" #[c|]#\" d",
    } });
}
