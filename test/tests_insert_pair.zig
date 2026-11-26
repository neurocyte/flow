const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;
const Selection = Buffer.Selection;

const editor = @import("tui").exports.editor;
const Editor = editor.Editor;
const CurSel = editor.CurSel;
const Inserter = Editor.test_internal.CurSelsInserter;

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

const Close = enum { open, close };

const Case = struct {
    text: []const u8,
    sel: Selection,
    cursor: Cursor,
    close: Close = .open,
    left: []const u8 = "(",
    right: []const u8 = ")",
    expected_text: []const u8,
    expected_sel: Selection,
    expected_cursor: Cursor,
};

fn pos(row: usize, col: usize) Cursor {
    return .{ .row = row, .col = col };
}

fn sel(begin: Cursor, end: Cursor) Selection {
    return .{ .begin = begin, .end = end };
}

fn run(case: Case) !void {
    const now = std.Io.Clock.real.now(std.testing.io);
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(case.text, &eol_mode, &sanitized), now);

    var cursels = [_]?CurSel{.{ .cursor = case.cursor, .selection = case.sel }};
    const cursel = &(cursels[0].?);
    const inserter: Inserter = .{ .cursels = &cursels, .metrics = metrics() };
    const root = switch (case.close) {
        .open => try Editor.insert_pair_around_selection(inserter, buffer.root, cursel, case.left, case.right, buffer.allocator),
        .close => try Editor.insert_pair_around_selection_close(inserter, buffer.root, cursel, case.left, case.right, buffer.allocator),
    };
    buffer.update(root, now);

    try std.testing.expectEqualStrings(case.expected_text, buffer.store_to_string_cached(buffer.root, eol_mode));
    const result_sel = cursel.selection orelse return error.TestExpectedSelection;
    try std.testing.expectEqual(case.expected_sel.begin.row, result_sel.begin.row);
    try std.testing.expectEqual(case.expected_sel.begin.col, result_sel.begin.col);
    try std.testing.expectEqual(case.expected_sel.end.row, result_sel.end.row);
    try std.testing.expectEqual(case.expected_sel.end.col, result_sel.end.col);
    try std.testing.expectEqual(case.expected_cursor.row, cursel.cursor.row);
    try std.testing.expectEqual(case.expected_cursor.col, cursel.cursor.col);
}

test "smart_insert_pair wraps a forward selection and keeps it on the text" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 0), pos(0, 7)),
        .cursor = pos(0, 7),
        .expected_text = "(abc def)\n",
        .expected_sel = sel(pos(0, 1), pos(0, 8)),
        .expected_cursor = pos(0, 8),
    });
}

test "smart_insert_pair wraps a reversed selection and keeps it on the text" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 7), pos(0, 0)),
        .cursor = pos(0, 0),
        .expected_text = "(abc def)\n",
        .expected_sel = sel(pos(0, 8), pos(0, 1)),
        .expected_cursor = pos(0, 1),
    });
}

test "smart_insert_pair wraps a selection inside a line" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 1), pos(0, 3)),
        .cursor = pos(0, 3),
        .expected_text = "a(bc) def\n",
        .expected_sel = sel(pos(0, 2), pos(0, 4)),
        .expected_cursor = pos(0, 4),
    });
}

test "smart_insert_pair wraps a selection across lines" {
    try run(.{
        .text = "abc def\nghi\n",
        .sel = sel(pos(0, 4), pos(1, 2)),
        .cursor = pos(1, 2),
        .expected_text = "abc (def\ngh)i\n",
        .expected_sel = sel(pos(0, 5), pos(1, 2)),
        .expected_cursor = pos(1, 2),
    });
}

test "smart_insert_pair wraps a selection in identical quotes" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 4), pos(0, 7)),
        .cursor = pos(0, 7),
        .left = "\"",
        .right = "\"",
        .expected_text = "abc \"def\"\n",
        .expected_sel = sel(pos(0, 5), pos(0, 8)),
        .expected_cursor = pos(0, 8),
    });
}

test "smart_insert_pair leaves an empty selection between the pair" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 3), pos(0, 3)),
        .cursor = pos(0, 3),
        .left = "\"",
        .right = "\"",
        .expected_text = "abc\"\" def\n",
        .expected_sel = sel(pos(0, 4), pos(0, 4)),
        .expected_cursor = pos(0, 4),
    });
}

test "smart_insert_pair_close moves the cursor past the closing char of a forward selection" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 0), pos(0, 7)),
        .cursor = pos(0, 7),
        .close = .close,
        .expected_text = "(abc def)\n",
        .expected_sel = sel(pos(0, 1), pos(0, 9)),
        .expected_cursor = pos(0, 9),
    });
}

test "smart_insert_pair_close keeps the cursor inside the opening char of a reversed selection" {
    try run(.{
        .text = "abc def\n",
        .sel = sel(pos(0, 7), pos(0, 0)),
        .cursor = pos(0, 0),
        .close = .close,
        .expected_text = "(abc def)\n",
        .expected_sel = sel(pos(0, 8), pos(0, 1)),
        .expected_cursor = pos(0, 1),
    });
}

test "smart_insert_pair nudges another cursor after the selection" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string("abc def\n", &eol_mode, &sanitized), now);

    var cursels = [_]?CurSel{
        .{ .cursor = pos(0, 3), .selection = sel(pos(0, 0), pos(0, 3)) },
        .{ .cursor = pos(0, 5) },
    };
    const inserter: Inserter = .{ .cursels = &cursels, .metrics = metrics() };
    const root = try Editor.insert_pair_around_selection(inserter, buffer.root, &(cursels[0].?), "(", ")", buffer.allocator);
    buffer.update(root, now);

    try std.testing.expectEqualStrings("(abc) def\n", buffer.store_to_string_cached(buffer.root, eol_mode));
    try std.testing.expectEqual(7, cursels[1].?.cursor.col);
}
