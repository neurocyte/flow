const std = @import("std");
const builtin = @import("builtin");
const Buffer = @import("Buffer");

const ArrayList = std.ArrayList;
const a = std.testing.allocator;

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

fn get_big_doc(eol_mode: *Buffer.EolMode) !*Buffer {
    const nl_lines = 10000;

    var doc: std.Io.Writer.Allocating = .init(a);
    defer doc.deinit();

    for (0..nl_lines) |line_num| {
        try doc.writer.print("this is line {d}\n", .{line_num});
    }

    const now = std.Io.Clock.real.now(std.testing.io);
    var buf = try Buffer.create(a, now);
    var sanitized: bool = false;
    buf.update(try buf.load_from_string(doc.written(), eol_mode, &sanitized), now);
    return buf;
}

test "buffer" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    const root = try buffer.load_from_string(doc, &eol_mode, &sanitized);

    try std.testing.expect(root.is_balanced());
    buffer.update(root, now);

    const result: []const u8 = buffer.store_to_string_cached(buffer.root, eol_mode);
    try std.testing.expectEqualDeep(result, doc);
    try std.testing.expectEqual(doc.len, result.len);
    try std.testing.expectEqual(doc.len, buffer.root.length());
}

fn get_line(buf: *const Buffer, line: usize) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(a);
    try buf.root.get_line(line, &result.writer, metrics());
    return result.toOwnedSlice();
}

test "walk_from_line" {
    var eol_mode: Buffer.EolMode = .lf;
    const buffer = try get_big_doc(&eol_mode);
    defer buffer.deinit();

    const lines = buffer.root.lines();
    try std.testing.expectEqual(lines, 10001);

    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "this is line 0"));

    const line1 = try get_line(buffer, 1);
    defer a.free(line1);
    try std.testing.expect(std.mem.eql(u8, line1, "this is line 1"));

    const line100 = try get_line(buffer, 100);
    defer a.free(line100);
    try std.testing.expect(std.mem.eql(u8, line100, "this is line 100"));

    const line9999 = try get_line(buffer, 9999);
    defer a.free(line9999);
    try std.testing.expectEqualDeep("this is line 9999", line9999);
}

test "line_len" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    try std.testing.expectEqual(try buffer.root.line_width(0, metrics()), 8);
    try std.testing.expectEqual(try buffer.root.line_width(1, metrics()), 5);
}

test "get_byte_pos" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    try std.testing.expectEqual(0, try buffer.root.get_byte_pos(.{ .row = 0, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(9, try buffer.root.get_byte_pos(.{ .row = 1, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(11, try buffer.root.get_byte_pos(.{ .row = 1, .col = 2 }, metrics(), eol_mode));
    try std.testing.expectEqual(33, try buffer.root.get_byte_pos(.{ .row = 4, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(66, try buffer.root.get_byte_pos(.{ .row = 8, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(97, try buffer.root.get_byte_pos(.{ .row = 11, .col = 2 }, metrics(), eol_mode));

    eol_mode = .crlf;
    try std.testing.expectEqual(0, try buffer.root.get_byte_pos(.{ .row = 0, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(10, try buffer.root.get_byte_pos(.{ .row = 1, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(12, try buffer.root.get_byte_pos(.{ .row = 1, .col = 2 }, metrics(), eol_mode));
    try std.testing.expectEqual(37, try buffer.root.get_byte_pos(.{ .row = 4, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(74, try buffer.root.get_byte_pos(.{ .row = 8, .col = 0 }, metrics(), eol_mode));
    try std.testing.expectEqual(108, try buffer.root.get_byte_pos(.{ .row = 11, .col = 2 }, metrics(), eol_mode));
}

test "delete_bytes" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    buffer.update(try buffer.root.delete_bytes(3, try buffer.root.line_width(3, metrics()) - 1, 1, buffer.allocator, metrics()), now);
    const line3 = try get_line(buffer, 3);
    defer a.free(line3);
    try std.testing.expect(std.mem.eql(u8, line3, "us"));

    buffer.update(try buffer.root.delete_bytes(3, 0, 7, buffer.allocator, metrics()), now);
    const line3_1 = try get_line(buffer, 3);
    defer a.free(line3_1);
    try std.testing.expect(std.mem.eql(u8, line3_1, "your"));

    try std.testing.expect(buffer.root.is_balanced());
    buffer.update(try buffer.root.rebalance(buffer.allocator, buffer.allocator), now);
    try std.testing.expect(buffer.root.is_balanced());

    buffer.update(try buffer.root.delete_bytes(0, try buffer.root.line_width(0, metrics()) - 1, 2, buffer.allocator, metrics()), now);
    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "All youropes"));
}

fn check_line(buffer: *const Buffer, line_no: usize, expect: []const u8) !void {
    const line = try get_line(buffer, line_no);
    defer a.free(line);
    try std.testing.expect(std.mem.eql(u8, line, expect));
}

test "delete_bytes2" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    buffer.update(try buffer.root.delete_bytes(2, try buffer.root.line_width(2, metrics()) - 3, 6, buffer.allocator, metrics()), now);

    try check_line(buffer, 2, "are belong!");
    try check_line(buffer, 3, "All your");
    try check_line(buffer, 4, "ropes");
}

test "delete_bytes_with_tab_issue83" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\\t
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    const len = blk: {
        const line2 = try get_line(buffer, 2);
        const line3 = try get_line(buffer, 3);
        const line4 = try get_line(buffer, 4);
        defer a.free(line2);
        defer a.free(line3);
        defer a.free(line4);
        break :blk line2.len + 1 +
            line3.len + 1 +
            line4.len + 1;
    };

    buffer.update(try buffer.root.delete_bytes(2, 0, len, buffer.allocator, metrics()), now);

    try check_line(buffer, 2, "ropes");
}

test "insert_chars" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\B
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "B"));

    _, _, var root = try buffer.root.insert_chars(0, 0, "1", buffer.allocator, metrics());
    buffer.update(root, now);

    const line1 = try get_line(buffer, 0);
    defer a.free(line1);
    try std.testing.expect(std.mem.eql(u8, line1, "1B"));

    _, _, root = try root.insert_chars(0, 1, "2", buffer.allocator, metrics());
    buffer.update(root, now);

    const line2 = try get_line(buffer, 0);
    defer a.free(line2);
    try std.testing.expect(std.mem.eql(u8, line2, "12B"));

    _, _, root = try root.insert_chars(0, 2, "3", buffer.allocator, metrics());
    buffer.update(root, now);

    const line3 = try get_line(buffer, 0);
    defer a.free(line3);
    try std.testing.expect(std.mem.eql(u8, line3, "123B"));

    _, _, root = try root.insert_chars(0, 3, "4", buffer.allocator, metrics());
    buffer.update(root, now);

    const line4 = try get_line(buffer, 0);
    defer a.free(line4);
    try std.testing.expect(std.mem.eql(u8, line4, "1234B"));

    _, _, root = try root.insert_chars(0, 4, "5", buffer.allocator, metrics());
    buffer.update(root, now);

    const line5 = try get_line(buffer, 0);
    defer a.free(line5);
    try std.testing.expect(std.mem.eql(u8, line5, "12345B"));

    _, _, root = try root.insert_chars(0, 5, "6", buffer.allocator, metrics());
    buffer.update(root, now);

    const line6 = try get_line(buffer, 0);
    defer a.free(line6);
    try std.testing.expect(std.mem.eql(u8, line6, "123456B"));

    _, _, root = try root.insert_chars(0, 6, "7", buffer.allocator, metrics());
    buffer.update(root, now);

    const line7 = try get_line(buffer, 0);
    defer a.free(line7);
    try std.testing.expect(std.mem.eql(u8, line7, "1234567B"));

    const line, const col, root = try buffer.root.insert_chars(0, 7, "8\n9", buffer.allocator, metrics());
    buffer.update(root, now);

    const line8 = try get_line(buffer, 0);
    defer a.free(line8);
    const line9 = try get_line(buffer, 1);
    defer a.free(line9);
    try std.testing.expect(std.mem.eql(u8, line8, "12345678"));
    try std.testing.expect(std.mem.eql(u8, line9, "9B"));
    try std.testing.expectEqual(line, 1);
    try std.testing.expectEqual(col, 1);
}

test "get_from_pos" {
    const now = std.Io.Clock.real.now(std.testing.io);
    var eol_mode: Buffer.EolMode = .lf;
    const buffer = try get_big_doc(&eol_mode);
    defer buffer.deinit();

    const lines = buffer.root.lines();
    try std.testing.expectEqual(lines, 10001);

    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    const line1 = try get_line(buffer, 1);
    defer a.free(line1);

    var result_buf: [1024]u8 = undefined;
    const result1 = buffer.root.get_from_pos(.{ .row = 0, .col = 0 }, &result_buf, metrics());
    try std.testing.expectEqualDeep(result1[0..line0.len], line0);

    const result2 = buffer.root.get_from_pos(.{ .row = 1, .col = 5 }, &result_buf, metrics());
    try std.testing.expectEqualDeep(result2[0 .. line1.len - 5], line1[5..]);

    _, _, const root = try buffer.root.insert_chars(1, 3, " ", buffer.allocator, metrics());
    buffer.update(root, now);

    const result3 = buffer.root.get_from_pos(.{ .row = 1, .col = 5 }, &result_buf, metrics());
    try std.testing.expectEqualDeep(result3[0 .. line1.len - 4], line1[4..]);
}

test "byte_offset_to_line_and_col" {
    const now = std.Io.Clock.real.now(std.testing.io);
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 0 }, buffer.root.byte_offset_to_line_and_col(0, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 8 }, buffer.root.byte_offset_to_line_and_col(8, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 1, .col = 0 }, buffer.root.byte_offset_to_line_and_col(9, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 1, .col = 2 }, buffer.root.byte_offset_to_line_and_col(11, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 4, .col = 0 }, buffer.root.byte_offset_to_line_and_col(33, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 8, .col = 0 }, buffer.root.byte_offset_to_line_and_col(66, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 11, .col = 2 }, buffer.root.byte_offset_to_line_and_col(97, metrics(), eol_mode));

    eol_mode = .crlf;

    try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 0 }, buffer.root.byte_offset_to_line_and_col(0, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 8 }, buffer.root.byte_offset_to_line_and_col(8, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 8 }, buffer.root.byte_offset_to_line_and_col(9, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 1, .col = 0 }, buffer.root.byte_offset_to_line_and_col(10, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 1, .col = 2 }, buffer.root.byte_offset_to_line_and_col(12, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 4, .col = 0 }, buffer.root.byte_offset_to_line_and_col(37, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 8, .col = 0 }, buffer.root.byte_offset_to_line_and_col(74, metrics(), eol_mode));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 11, .col = 2 }, buffer.root.byte_offset_to_line_and_col(108, metrics(), eol_mode));
}

fn test_reflow(input: []const u8, width: usize, expected: []const u8) !void {
    const out = try Buffer.reflow(a, input, width, .unicode, .spaces, metrics());
    defer a.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

fn test_reflow_tabs(input: []const u8, width: usize, expected: []const u8) !void {
    const out = try Buffer.reflow(a, input, width, .unicode, .tabs, metrics());
    defer a.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "reflow: prefix never contains alphas" {
    try test_reflow(
        "This is text\nThat is text\n",
        40,
        "This is text That is text\n",
    );
}

test "reflow: single paragraph detects non-alphanumeric prefix" {
    try test_reflow(
        "// this is a long comment that should wrap somewhere\n",
        30,
        "// this is a long comment\n// that should wrap somewhere\n",
    );
    try test_reflow(
        "    indented paragraph that wraps here please thanks\n",
        30,
        "    indented paragraph that\n    wraps here please thanks\n",
    );
    try test_reflow(
        "   // this is a long comment that should wrap somewhere\n",
        30,
        "   // this is a long comment\n   // that should wrap\n   // somewhere\n",
    );
}

test "reflow: markdown bullet section re-wraps each bullet" {
    try test_reflow(
        "- a long first bullet that wraps\n- second bullet\n- third\n",
        20,
        "- a long first\n  bullet that wraps\n- second bullet\n- third\n",
    );
    try test_reflow(
        "  - first item that is rather long\n  - second\n",
        20,
        "  - first item that\n    is rather long\n  - second\n",
    );
    try test_reflow(
        "- one long single bullet that should wrap around\n",
        20,
        "- one long single\n  bullet that\n  should wrap\n  around\n",
    );
}

test "reflow: bullets accept -, * and + markers" {
    try test_reflow(
        "* a long first bullet that wraps\n* second bullet\n",
        20,
        "* a long first\n  bullet that wraps\n* second bullet\n",
    );
    try test_reflow(
        "+ a long first bullet that wraps\n+ second bullet\n",
        20,
        "+ a long first\n  bullet that wraps\n+ second bullet\n",
    );
}

test "reflow: github task list bullets" {
    try test_reflow(
        "- [ ] a long first task item that wraps\n- [x] done item\n",
        25,
        "- [ ] a long first task\n      item that wraps\n- [x] done item\n",
    );
}

test "reflow: multi-byte unicode bullets align by column" {
    try test_reflow(
        "• a long first bullet that wraps\n• second\n",
        20,
        "• a long first\n  bullet that wraps\n• second\n",
    );
}

test "reflow: wraps on display width, not byte length" {
    try test_reflow(
        "日本 日本 日本\n",
        10,
        "日本 日本\n日本\n",
    );
}

test "reflow: tab indentation counts as tab_width columns" {
    try test_reflow_tabs(
        "\tword1 word2 word3\n",
        20,
        "\tword1 word2\n\tword3\n",
    );
}

test "reflow: indentation is regenerated in the document indent style" {
    try test_reflow(
        "\tword1 word2 word3\n",
        20,
        "        word1 word2\n        word3\n",
    );
    try test_reflow_tabs(
        "          word1 word2 word3\n",
        40,
        "\t  word1 word2 word3\n",
    );
}

test "reflow: bullet continuation keeps prefix tabs and pads with spaces" {
    try test_reflow_tabs(
        "\t- one two three four\n",
        24,
        "\t- one two three\n\t  four\n",
    );
}

fn test_nudge_delete(cursor_: Buffer.Cursor, nudge: Buffer.Selection, expected: ?Buffer.Cursor) !void {
    var cursor = cursor_;
    const survived = cursor.nudge_delete(.{ .sel = nudge });
    if (expected) |expected_| {
        try std.testing.expect(survived);
        try std.testing.expectEqual(expected_.row, cursor.row);
        try std.testing.expectEqual(expected_.col, cursor.col);
    } else try std.testing.expect(!survived);
}

test "nudge_delete: cursor before the deleted range is unchanged" {
    try test_nudge_delete(
        .{ .row = 2, .col = 3 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } },
        .{ .row = 2, .col = 3 },
    );
}

test "nudge_delete: cursor inside the deleted range is removed" {
    try test_nudge_delete(
        .{ .row = 4, .col = 1 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } },
        null,
    );
}

test "nudge_delete: single line delete shifts cursor left" {
    try test_nudge_delete(
        .{ .row = 3, .col = 10 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } },
        .{ .row = 3, .col = 8 },
    );
}

test "nudge_delete: multi line delete shifts cursor on a later row up" {
    try test_nudge_delete(
        .{ .row = 7, .col = 10 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } },
        .{ .row = 5, .col = 10 },
    );
}

test "nudge_delete: multi line delete joins cursor on the last deleted row" {
    try test_nudge_delete(
        .{ .row = 5, .col = 10 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } },
        .{ .row = 3, .col = 8 },
    );
}

test "nudge_delete: multi line delete with cursor at the range end" {
    try test_nudge_delete(
        .{ .row = 5, .col = 6 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } },
        .{ .row = 3, .col = 4 },
    );
}

test "nudge_delete: cursor at the range begin survives" {
    try test_nudge_delete(
        .{ .row = 3, .col = 4 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } },
        .{ .row = 3, .col = 4 },
    );
    try test_nudge_delete(
        .{ .row = 3, .col = 4 },
        .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } },
        .{ .row = 3, .col = 4 },
    );
}

test "nudge_delete: selection ending at the range begin survives" {
    var sel: Buffer.Selection = .{ .begin = .{ .row = 3, .col = 1 }, .end = .{ .row = 3, .col = 4 } };
    try std.testing.expect(sel.nudge_delete(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } } }));
    try std.testing.expectEqual(1, sel.begin.col);
    try std.testing.expectEqual(4, sel.end.col);
}

test "nudge_delete: selection equal to the range is removed" {
    var sel: Buffer.Selection = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } };
    try std.testing.expect(!sel.nudge_delete(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } } }));
}

test "nudge_delete: selection extending beyond the range is shrunk" {
    var sel: Buffer.Selection = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 9 } };
    try std.testing.expect(sel.nudge_delete(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } } }));
    try std.testing.expectEqual(4, sel.begin.col);
    try std.testing.expectEqual(7, sel.end.col);
}

test "nudge_delete: selection overlapping the range begin is removed" {
    var sel: Buffer.Selection = .{ .begin = .{ .row = 3, .col = 1 }, .end = .{ .row = 3, .col = 5 } };
    try std.testing.expect(!sel.nudge_delete(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } } }));
}

test "nudge_delete: selection beginning at the range end survives" {
    var sel: Buffer.Selection = .{ .begin = .{ .row = 3, .col = 6 }, .end = .{ .row = 3, .col = 9 } };
    try std.testing.expect(sel.nudge_delete(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 3, .col = 6 } } }));
    try std.testing.expectEqual(4, sel.begin.col);
    try std.testing.expectEqual(7, sel.end.col);
}

test "nudge_insert: cursor on a later row keeps its target column" {
    var cursor: Buffer.Cursor = .{ .row = 7, .col = 10, .target = 20 };
    cursor.nudge_insert(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } } });
    try std.testing.expectEqual(Buffer.Cursor{ .row = 9, .col = 10, .target = 20 }, cursor);
}

test "nudge_delete: cursor on a later row keeps its target column" {
    var cursor: Buffer.Cursor = .{ .row = 7, .col = 10, .target = 20 };
    try std.testing.expect(cursor.nudge_delete(.{ .sel = .{ .begin = .{ .row = 3, .col = 4 }, .end = .{ .row = 5, .col = 6 } } }));
    try std.testing.expectEqual(Buffer.Cursor{ .row = 5, .col = 10, .target = 20 }, cursor);
}

fn tab_metrics() Buffer.Metrics {
    var metrics_ = metrics();
    metrics_.egc_length = struct {
        fn f(self: Buffer.Metrics, egcs: []const u8, colcount: *usize, abs_col: usize) usize {
            colcount.* = if (egcs[0] == '\t') self.tab_width - (abs_col % self.tab_width) else 1;
            return 1;
        }
    }.f;
    metrics_.egc_chunk_width = struct {
        fn f(self: Buffer.Metrics, chunk_: []const u8, abs_col_: usize) usize {
            var abs_col = abs_col_;
            for (chunk_) |c| abs_col += if (c == '\t') self.tab_width - (abs_col % self.tab_width) else 1;
            return abs_col - abs_col_;
        }
    }.f;
    return metrics_;
}

fn test_nudge_delete_doc(doc: []const u8, sel: Buffer.Selection, cursor_: Buffer.Cursor) !void {
    const now = std.Io.Clock.real.now(std.testing.io);
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    const pos = try buffer.root.get_byte_pos(cursor_, tab_metrics(), eol_mode);
    var size: usize = 0;
    const root, _ = try buffer.root.delete_range_char(sel, buffer.allocator, &size, tab_metrics());
    const expected = root.byte_offset_to_line_and_col(pos - size, tab_metrics(), eol_mode);

    var cursor = cursor_;
    try std.testing.expect(cursor.nudge_delete(.delete(sel, buffer.root, root, tab_metrics())));
    try std.testing.expectEqual(expected.row, cursor.row);
    try std.testing.expectEqual(expected.col, cursor.col);
}

fn test_nudge_insert_doc(doc: []const u8, at: Buffer.Cursor, text: []const u8, cursor_: Buffer.Cursor) !void {
    const now = std.Io.Clock.real.now(std.testing.io);
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);

    const pos = try buffer.root.get_byte_pos(cursor_, tab_metrics(), eol_mode);
    const row, const col, const root = try buffer.root.insert_chars(at.row, at.col, text, buffer.allocator, tab_metrics());
    const expected = root.byte_offset_to_line_and_col(pos + text.len, tab_metrics(), eol_mode);

    var cursor = cursor_;
    cursor.nudge_insert(.insert(.{ .begin = at, .end = .{ .row = row, .col = col } }, buffer.root, root, tab_metrics()));
    try std.testing.expectEqual(expected.row, cursor.row);
    try std.testing.expectEqual(expected.col, cursor.col);
}

test "nudge_delete: cursor follows its character" {
    try test_nudge_delete_doc(
        "ab ab Q\n",
        .{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 2 } },
        .{ .row = 0, .col = 6 },
    );
    try test_nudge_delete_doc(
        "abcd\nef Q\n",
        .{ .begin = .{ .row = 0, .col = 4 }, .end = .{ .row = 1, .col = 2 } },
        .{ .row = 1, .col = 3 },
    );
}

test "nudge_delete: cursor follows its character across a tab" {
    try test_nudge_delete_doc(
        "ab\tab\tQ\n",
        .{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 2 } },
        .{ .row = 0, .col = 16 },
    );
}

test "nudge_delete: cursor follows its character across a tab on a joined row" {
    try test_nudge_delete_doc(
        "abcd\nef\tQ\n",
        .{ .begin = .{ .row = 0, .col = 4 }, .end = .{ .row = 1, .col = 2 } },
        .{ .row = 1, .col = 8 },
    );
}

test "nudge_insert: cursor follows its character" {
    try test_nudge_insert_doc(" Q\n", .{ .row = 0, .col = 0 }, "ab", .{ .row = 0, .col = 1 });
    try test_nudge_insert_doc(" Q\n", .{ .row = 0, .col = 0 }, "ab\ncd", .{ .row = 0, .col = 1 });
}

test "nudge_insert: cursor follows its character across a tab" {
    try test_nudge_insert_doc("\tQ\n", .{ .row = 0, .col = 0 }, "ab", .{ .row = 0, .col = 8 });
}

test "nudge_insert: cursor before a tab follows its character" {
    try test_nudge_insert_doc("xyQ\tz\n", .{ .row = 0, .col = 0 }, "ab", .{ .row = 0, .col = 2 });
    try test_nudge_insert_doc("x\tyQ\n", .{ .row = 0, .col = 0 }, "ab\tcd\n\t", .{ .row = 0, .col = 9 });
}
