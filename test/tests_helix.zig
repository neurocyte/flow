const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = @import("Buffer").Cursor;
const Result = @import("command").Result;

const helix = @import("tui").exports.mode.helix;
const Editor = @import("tui").exports.editor.Editor;

const a = std.testing.allocator;

fn apply_movements(movements: []const u8, root: Buffer.Root, cursor: *Cursor, the_metrics: Buffer.Metrics, row: usize, col: usize) Result {
    for (movements) |move| {
        switch (move) {
            'W' => {
                try helix.move_cursor_long_word_right(root, cursor, the_metrics);
            },
            'B' => {
                try helix.move_cursor_long_word_left(root, cursor, the_metrics);
            },
            'E' => {
                try helix.move_cursor_long_word_right_end(root, cursor, the_metrics);
            },
            'w' => {
                try Editor.move_cursor_word_right_vim(root, cursor, the_metrics);
            },
            'b' => {
                try helix.move_cursor_word_left_helix(root, cursor, the_metrics);
            },
            'e' => {
                try helix.move_cursor_word_right_end_helix(root, cursor, the_metrics);
            },
            else => {},
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
    \\gawk '{print length($0) }' testflowhelixwbe.txt  | tr '\n' ' '
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
//60 44 54 0 2 8 138 0 0 22 2 0

var eol_mode: Buffer.EolMode = .lf;
var sanitized: bool = false;
var the_cursor = Cursor{ .row = 1, .col = 1, .target = 0 };

// To run a specific test
// zig build test -Dtest-filter=word_movement

test "words_movement" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    the_cursor.col = 1;
    the_cursor.row = 0;

    const movements: [12]MoveExpected = .{
        .{ .moves = "b", .row = 0, .col = 0 },
        .{ .moves = "w", .row = 0, .col = 5 },
        .{ .moves = "b", .row = 0, .col = 1 },
        // TODO: Review the following line, an Stop is raising
        // .{ .moves = "bb", .row = 0, .col = 0 },
        .{ .moves = "ww", .row = 0, .col = 7 },
        .{ .moves = "bb", .row = 0, .col = 1 },
        .{ .moves = "www", .row = 0, .col = 13 },
        .{ .moves = "bbb", .row = 0, .col = 1 },
        .{ .moves = "wwww", .row = 0, .col = 19 },
        .{ .moves = "bbbb", .row = 0, .col = 1 },
        .{ .moves = "wb", .row = 0, .col = 1 },
        .{ .moves = "e", .row = 0, .col = 4 },
        .{ .moves = "b", .row = 0, .col = 1 },
        // TODO: b has a bug when at the end of the view, it's
        // not getting back.
        //
        // TODO: Another bug detected is when there are multiple
        // lines, b is not able to get to the first non
        // newline.
    };

    for (movements) |move| {
        try apply_movements(move.moves, root, &the_cursor, metrics(), move.row, move.col);
    }
}

test "long_words_movement" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    the_cursor.col = 1;
    the_cursor.row = 0;

    const movements: [12]MoveExpected = .{
        .{ .moves = "B", .row = 0, .col = 0 },
        .{ .moves = "W", .row = 0, .col = 5 },
        .{ .moves = "B", .row = 0, .col = 1 },
        // TODO: Review the following line, an Stop is raising
        // .{ .moves = "BB", .row = 0, .col = 0 },
        .{ .moves = "WW", .row = 0, .col = 13 },
        .{ .moves = "BB", .row = 0, .col = 1 },
        .{ .moves = "WWW", .row = 0, .col = 24 },
        .{ .moves = "BBB", .row = 0, .col = 1 },
        .{ .moves = "WWWW", .row = 0, .col = 27 },
        .{ .moves = "BBBB", .row = 0, .col = 1 },
        // TODO:
        // WWWWW should report 48, is reporting 49, when changing modes
        // the others report 48.  This is an specific hx mode
        // .{ .moves = "WWWWW", .row = 0, .col = 48 },
        // Same bugs detected in b are in B
        .{ .moves = "WB", .row = 0, .col = 1 },
        .{ .moves = "E", .row = 0, .col = 4 },
        .{ .moves = "B", .row = 0, .col = 1 },
    };

    for (movements) |move| {
        try apply_movements(move.moves, root, &the_cursor, metrics(), move.row, move.col);
    }
}
