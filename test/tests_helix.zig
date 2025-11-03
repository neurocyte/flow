const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = @import("Buffer").Cursor;
const Result = @import("command").Result;
const fmt_command = @import("command").fmt;

const helix = @import("tui").exports.mode.helix;
const Editor = @import("tui").exports.editor.Editor;

const a = std.testing.allocator;

fn apply_movements(movements: []const u8, root: Buffer.Root, cursor: *Cursor, the_metrics: Buffer.Metrics, row: usize, col: usize) Result {
    for (movements) |move| {
        switch (move) {
            'W' => {
                try helix.test_internal.move_cursor_long_word_right(root, cursor, the_metrics);
            },
            'B' => {
                try helix.test_internal.move_cursor_long_word_left(root, cursor, the_metrics);
            },
            'E' => {
                try helix.test_internal.move_cursor_long_word_right_end(root, cursor, the_metrics);
            },
            'w' => {
                try Editor.move_cursor_word_right_vim(root, cursor, the_metrics);
            },
            'b' => {
                try helix.test_internal.move_cursor_word_left_helix(root, cursor, the_metrics);
            },
            'e' => {
                try helix.test_internal.move_cursor_word_right_end_helix(root, cursor, the_metrics);
            },
            else => {
                return error.Stop;
            },
        }
    }
    try std.testing.expectEqual(col, cursor.col);
    try std.testing.expectEqual(row, cursor.row);
}

const MoveExpected = struct {
    moves: []const u8,
    row: usize,
    col: usize,
};

fn metrics() Buffer.Metrics {
    return .{
        .ctx = undefined,
        .egc_length = struct {
            fn f(_: Buffer.Metrics, _: []const u8, colcount: *c_int, _: usize) usize {
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
const doc: []const u8 =
    \\gawk '{print length($0) }' testflowhelixwbe.txt  | tr '\n' ' 'i
    \\
    \\Allows you to know what is the length of each line ^^^^
    \\a small $% Test.here,   with.things()to demo
    \\ with surrounding.space    a bb  AA   a small and long
    \\
    \\  
    \\nospace.
    \\   try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 0 }, buffer.root.byte_offset_to_line_and_col(0, test_metrics(), eol_mode));
    \\
    \\
    \\  $$%.  []{{}. dart de
    \\da
;

var eol_mode: Buffer.EolMode = .lf;
var sanitized: bool = false;

test "words_movement" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    var the_cursor = Cursor{ .row = 1, .col = 1, .target = 0 };

    the_cursor.col = 1;
    the_cursor.row = 0;

    const movements: [12]MoveExpected = .{
        .{ .moves = "b", .row = 0, .col = 0 },
        .{ .moves = "w", .row = 0, .col = 5 },
        .{ .moves = "b", .row = 0, .col = 1 },
        .{ .moves = "ww", .row = 0, .col = 7 },
        .{ .moves = "bb", .row = 0, .col = 1 },
        .{ .moves = "www", .row = 0, .col = 13 },
        .{ .moves = "bbb", .row = 0, .col = 1 },
        .{ .moves = "wwww", .row = 0, .col = 19 },
        .{ .moves = "bbbb", .row = 0, .col = 1 },
        .{ .moves = "wb", .row = 0, .col = 1 },
        .{ .moves = "e", .row = 0, .col = 4 },
        .{ .moves = "b", .row = 0, .col = 1 },
    };
    for (movements) |move| {
        try apply_movements(move.moves, root, &the_cursor, metrics(), move.row, move.col);
    }
    the_cursor.row = 11;
    the_cursor.col = 1;

    const more_movements: [2]MoveExpected = .{
        .{ .moves = "b", .row = 8, .col = 135 },
        .{ .moves = "w", .row = 11, .col = 2 },
    };
    for (more_movements) |move| {
        try apply_movements(move.moves, root, &the_cursor, metrics(), move.row, move.col);
    }
}

test "edge_word_movements" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    var cursor = Cursor{ .row = 1, .col = 1, .target = 0 };
    cursor.col = 0;
    cursor.row = 0;
    const expected_error = error.Stop;
    var result = helix.test_internal.move_cursor_word_left_helix(root, &cursor, metrics());
    try std.testing.expectError(expected_error, result);
    try std.testing.expectEqual(0, cursor.row);
    try std.testing.expectEqual(0, cursor.col);

    result = helix.test_internal.move_cursor_long_word_left(root, &cursor, metrics());
    try std.testing.expectError(expected_error, result);
    try std.testing.expectEqual(0, cursor.row);
    try std.testing.expectEqual(0, cursor.col);
}

test "long_words_movement" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    var the_cursor = Cursor{ .row = 1, .col = 1, .target = 0 };

    the_cursor.col = 1;
    the_cursor.row = 0;

    const movements: [12]MoveExpected = .{
        .{ .moves = "B", .row = 0, .col = 0 },
        .{ .moves = "W", .row = 0, .col = 5 },
        .{ .moves = "B", .row = 0, .col = 1 },
        .{ .moves = "WW", .row = 0, .col = 13 },
        .{ .moves = "BB", .row = 0, .col = 1 },
        .{ .moves = "WWW", .row = 0, .col = 24 },
        .{ .moves = "BBB", .row = 0, .col = 1 },
        .{ .moves = "WWWW", .row = 0, .col = 27 },
        .{ .moves = "BBBB", .row = 0, .col = 1 },
        .{ .moves = "WB", .row = 0, .col = 1 },
        .{ .moves = "E", .row = 0, .col = 4 },
        .{ .moves = "B", .row = 0, .col = 1 },
    };

    for (movements) |move| {
        try apply_movements(move.moves, root, &the_cursor, metrics(), move.row, move.col);
    }
}

test "to_char_right_beyond_eol" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    var the_cursor = Cursor{ .row = 1, .col = 1, .target = 0 };

    the_cursor.col = 0;
    the_cursor.row = 0;
    const expected_error = error.Stop;

    // Not found to begin of file
    var result = helix.test_internal.move_cursor_to_char_left_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"a"}));
    try std.testing.expectError(expected_error, result);
    try std.testing.expectEqual(0, the_cursor.row);
    try std.testing.expectEqual(0, the_cursor.col);

    // Move found in the next line
    try helix.test_internal.move_cursor_to_char_right_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"T"}));
    try std.testing.expectEqual(3, the_cursor.row);
    try std.testing.expectEqual(11, the_cursor.col);

    // Move found in the previous line
    try helix.test_internal.move_cursor_to_char_left_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"t"}));
    try std.testing.expectEqual(2, the_cursor.row);
    try std.testing.expectEqual(35, the_cursor.col);

    // Not found to end of buffer, cursor not moved
    result = helix.test_internal.move_cursor_to_char_right_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"Z"}));
    try std.testing.expectError(expected_error, result);
    try std.testing.expectEqual(2, the_cursor.row);
    try std.testing.expectEqual(35, the_cursor.col);

    // Not found to begin of buffer
    result = helix.test_internal.move_cursor_to_char_left_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"Z"}));
    try std.testing.expectError(expected_error, result);
    try std.testing.expectEqual(2, the_cursor.row);
    try std.testing.expectEqual(35, the_cursor.col);

    // till char difference
    // Move found in the next line
    try helix.test_internal.move_cursor_till_char_right_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"T"}));
    try std.testing.expectEqual(3, the_cursor.row);
    try std.testing.expectEqual(10, the_cursor.col);

    // Move found in the previous line
    try helix.test_internal.move_cursor_till_char_left_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"t"}));
    try std.testing.expectEqual(2, the_cursor.row);
    try std.testing.expectEqual(36, the_cursor.col);

    // Move found in the same line
    try helix.test_internal.move_cursor_till_char_left_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"u"}));
    try std.testing.expectEqual(2, the_cursor.row);
    try std.testing.expectEqual(10, the_cursor.col);

    // Move found in the same line
    try helix.test_internal.move_cursor_till_char_right_beyond_eol(root, &the_cursor, metrics(), fmt_command(.{"t"}));
    try std.testing.expectEqual(2, the_cursor.row);
    try std.testing.expectEqual(21, the_cursor.col);
}

// TODO: When at end of file, enter sel mode makes
// difficult to get back and is confusing for users.
// Related to that is the fact that when a selection
// is made, then trying to move to the right, the
// first movement is swallowed
