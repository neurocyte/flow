const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = @import("Buffer").Cursor;

const vim = @import("tui").exports.mode.vim;

const a = std.testing.allocator;

var eol_mode: Buffer.EolMode = .lf;
var sanitized: bool = false;

fn metrics() Buffer.Metrics {
    return .{
        .ctx = undefined,
        .egc_length = struct {
            fn f(_: Buffer.Metrics, _: []const u8, colcount: *usize, _: usize) usize {
                colcount.* = 1;
                return 1;
            }
        }.f,
        .egc_chunk_width = struct {
            fn f(_: Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                return chunk_.len;
            }
        }.f,
        .egc_last = struct {
            fn f(_: Buffer.Metrics, _: []const u8) []const u8 {
                @panic("not implemented");
            }
        }.f,
        .tab_width = 8,
    };
}

const Selection = struct {
    begin_row: usize,
    begin_col: usize,
    end_row: usize,
    end_col: usize,
};

fn expect_long_word_selection(doc: []const u8, row: usize, col: usize, around: bool, expected: Selection) !void {
    const now = std.Io.Clock.real.now(std.testing.io);
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);
    const root: Buffer.Root = buffer.root;

    var cursel = @import("tui").exports.editor.CurSel{ .cursor = .{ .row = row, .col = col } };
    if (around) {
        try vim.test_internal.select_around_long_word_textobject(root, &cursel, metrics());
    } else {
        try vim.test_internal.select_inside_long_word_textobject(root, &cursel, metrics());
    }

    const sel = cursel.selection orelse return error.TestExpectedSelection;
    try std.testing.expectEqual(expected.begin_row, sel.begin.row);
    try std.testing.expectEqual(expected.begin_col, sel.begin.col);
    try std.testing.expectEqual(expected.end_row, sel.end.row);
    try std.testing.expectEqual(expected.end_col, sel.end.col);
    try std.testing.expectEqual(expected.end_row, cursel.cursor.row);
    try std.testing.expectEqual(expected.end_col, cursel.cursor.col);
}

test "select inside long word: cursor on first, middle and last char selects the whole WORD" {
    //                01234567890123456789012345678901234
    const doc = "foo.bar baz.qux +one-two* last";
    // inside
    try expect_long_word_selection(doc, 0, 0, false, .{ .begin_row = 0, .begin_col = 0, .end_row = 0, .end_col = 7 });
    try expect_long_word_selection(doc, 0, 3, false, .{ .begin_row = 0, .begin_col = 0, .end_row = 0, .end_col = 7 });
    try expect_long_word_selection(doc, 0, 6, false, .{ .begin_row = 0, .begin_col = 0, .end_row = 0, .end_col = 7 });
    // around selects the same WORD, no trailing whitespace after it
    try expect_long_word_selection(doc, 0, 3, true, .{ .begin_row = 0, .begin_col = 0, .end_row = 0, .end_col = 8 });
    // last WORD on the line, no trailing whitespace
    try expect_long_word_selection(doc, 0, 28, false, .{ .begin_row = 0, .begin_col = 26, .end_row = 0, .end_col = 30 });
    try expect_long_word_selection(doc, 0, 28, true, .{ .begin_row = 0, .begin_col = 25, .end_row = 0, .end_col = 30 });
}

test "select inside long word: a.b is a single WORD unlike word textobject" {
    //                01234567
    const doc = "xx a.b yy";
    try expect_long_word_selection(doc, 0, 4, false, .{ .begin_row = 0, .begin_col = 3, .end_row = 0, .end_col = 6 });
    try expect_long_word_selection(doc, 0, 4, true, .{ .begin_row = 0, .begin_col = 3, .end_row = 0, .end_col = 7 });
}

test "select inside long word: cursor on whitespace takes the whitespace run" {
    //                0123456789012
    const doc = "foo.bar  baz";
    // like vim, the whitespace run the cursor is in is the unit
    try expect_long_word_selection(doc, 0, 7, false, .{ .begin_row = 0, .begin_col = 7, .end_row = 0, .end_col = 9 });
    try expect_long_word_selection(doc, 0, 8, false, .{ .begin_row = 0, .begin_col = 7, .end_row = 0, .end_col = 9 });
    // around takes the whitespace run plus the WORD that follows it
    try expect_long_word_selection(doc, 0, 7, true, .{ .begin_row = 0, .begin_col = 7, .end_row = 0, .end_col = 12 });
}

test "select around long word: leading whitespace at line start is left out" {
    //                0123456
    const doc = "  foo";
    // the WORD is at the end of the line and the leading whitespace reaches the
    // start of the line: vim does not include any of it
    try expect_long_word_selection(doc, 0, 2, true, .{ .begin_row = 0, .begin_col = 2, .end_row = 0, .end_col = 5 });
    // with a word in front of the whitespace run, the whole run is included
    try expect_long_word_selection("ab  foo", 0, 4, true, .{ .begin_row = 0, .begin_col = 2, .end_row = 0, .end_col = 7 });
}

test "select around long word: includes trailing whitespace" {
    //                0123456789012345
    const doc = "aa bb.cc  dd";
    try expect_long_word_selection(doc, 0, 6, true, .{ .begin_row = 0, .begin_col = 3, .end_row = 0, .end_col = 10 });
    // around on WORD at end of line, preceded by whitespace: includes the leading whitespace run
    try expect_long_word_selection(doc, 0, 11, true, .{ .begin_row = 0, .begin_col = 8, .end_row = 0, .end_col = 12 });
}

test "select long word: line start and line end boundaries stay in bounds" {
    //                012345
    const doc = "abc ";
    try expect_long_word_selection(doc, 0, 0, false, .{ .begin_row = 0, .begin_col = 0, .end_row = 0, .end_col = 3 });
    try expect_long_word_selection(doc, 0, 0, true, .{ .begin_row = 0, .begin_col = 0, .end_row = 0, .end_col = 4 });
    // cursor on the trailing whitespace at end of line: inside takes that whitespace
    try expect_long_word_selection(doc, 0, 3, false, .{ .begin_row = 0, .begin_col = 3, .end_row = 0, .end_col = 4 });
    // around needs a WORD after the whitespace run, so vim selects nothing here
    try expect_long_word_selection(doc, 0, 3, true, .{ .begin_row = 0, .begin_col = 4, .end_row = 0, .end_col = 4 });
}

test "select long word: only the current WORD is selected" {
    //                0123456789012
    const doc = "aa bb.cc dd";
    try expect_long_word_selection(doc, 0, 4, false, .{ .begin_row = 0, .begin_col = 3, .end_row = 0, .end_col = 8 });
    try expect_long_word_selection(doc, 0, 10, false, .{ .begin_row = 0, .begin_col = 9, .end_row = 0, .end_col = 11 });
}
