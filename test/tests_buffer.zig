const std = @import("std");
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

    var buf = try Buffer.create(a);
    var sanitized: bool = false;
    buf.update(try buf.load_from_string(doc.written(), eol_mode, &sanitized));
    return buf;
}

test "buffer" {
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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    const root = try buffer.load_from_string(doc, &eol_mode, &sanitized);

    try std.testing.expect(root.is_balanced());
    buffer.update(root);

    const result: []const u8 = buffer.store_to_string_cached(buffer.root, eol_mode);
    try std.testing.expectEqualDeep(result, doc);
    try std.testing.expectEqual(doc.len, result.len);
    try std.testing.expectEqual(doc.len, buffer.root.length());
}

test "buffer.store_to_file_and_clean" {
    const local = struct {
        fn read_file(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
            const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
            defer file.close();
            const stat = try file.stat();
            const buf = try allocator.alloc(u8, @intCast(stat.size));
            errdefer allocator.free(buf);
            const read_size = try file.readAll(buf);
            try std.testing.expectEqual(read_size, stat.size);
            return buf;
        }
    };

    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    try buffer.load_from_file_and_update("test/tests_buffer_input.txt");
    try buffer.store_to_file_and_clean("test/tests_buffer_output.txt");

    const input = try local.read_file(a, "test/tests_buffer_input.txt");
    defer a.free(input);
    const output = try local.read_file(a, "test/tests_buffer_output.txt");
    defer a.free(output);
    try std.testing.expectEqualStrings(input, output);
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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

    try std.testing.expectEqual(try buffer.root.line_width(0, metrics()), 8);
    try std.testing.expectEqual(try buffer.root.line_width(1, metrics()), 5);
}

test "get_byte_pos" {
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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

    buffer.update(try buffer.root.delete_bytes(3, try buffer.root.line_width(3, metrics()) - 1, 1, buffer.allocator, metrics()));
    const line3 = try get_line(buffer, 3);
    defer a.free(line3);
    try std.testing.expect(std.mem.eql(u8, line3, "us"));

    buffer.update(try buffer.root.delete_bytes(3, 0, 7, buffer.allocator, metrics()));
    const line3_1 = try get_line(buffer, 3);
    defer a.free(line3_1);
    try std.testing.expect(std.mem.eql(u8, line3_1, "your"));

    try std.testing.expect(buffer.root.is_balanced());
    buffer.update(try buffer.root.rebalance(buffer.allocator, buffer.allocator));
    try std.testing.expect(buffer.root.is_balanced());

    buffer.update(try buffer.root.delete_bytes(0, try buffer.root.line_width(0, metrics()) - 1, 2, buffer.allocator, metrics()));
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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

    buffer.update(try buffer.root.delete_bytes(2, try buffer.root.line_width(2, metrics()) - 3, 6, buffer.allocator, metrics()));

    try check_line(buffer, 2, "are belong!");
    try check_line(buffer, 3, "All your");
    try check_line(buffer, 4, "ropes");
}

test "delete_bytes_with_tab_issue83" {
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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

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

    buffer.update(try buffer.root.delete_bytes(2, 0, len, buffer.allocator, metrics()));

    try check_line(buffer, 2, "ropes");
}

test "insert_chars" {
    const doc: []const u8 =
        \\B
    ;
    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "B"));

    _, _, var root = try buffer.root.insert_chars(0, 0, "1", buffer.allocator, metrics());
    buffer.update(root);

    const line1 = try get_line(buffer, 0);
    defer a.free(line1);
    try std.testing.expect(std.mem.eql(u8, line1, "1B"));

    _, _, root = try root.insert_chars(0, 1, "2", buffer.allocator, metrics());
    buffer.update(root);

    const line2 = try get_line(buffer, 0);
    defer a.free(line2);
    try std.testing.expect(std.mem.eql(u8, line2, "12B"));

    _, _, root = try root.insert_chars(0, 2, "3", buffer.allocator, metrics());
    buffer.update(root);

    const line3 = try get_line(buffer, 0);
    defer a.free(line3);
    try std.testing.expect(std.mem.eql(u8, line3, "123B"));

    _, _, root = try root.insert_chars(0, 3, "4", buffer.allocator, metrics());
    buffer.update(root);

    const line4 = try get_line(buffer, 0);
    defer a.free(line4);
    try std.testing.expect(std.mem.eql(u8, line4, "1234B"));

    _, _, root = try root.insert_chars(0, 4, "5", buffer.allocator, metrics());
    buffer.update(root);

    const line5 = try get_line(buffer, 0);
    defer a.free(line5);
    try std.testing.expect(std.mem.eql(u8, line5, "12345B"));

    _, _, root = try root.insert_chars(0, 5, "6", buffer.allocator, metrics());
    buffer.update(root);

    const line6 = try get_line(buffer, 0);
    defer a.free(line6);
    try std.testing.expect(std.mem.eql(u8, line6, "123456B"));

    _, _, root = try root.insert_chars(0, 6, "7", buffer.allocator, metrics());
    buffer.update(root);

    const line7 = try get_line(buffer, 0);
    defer a.free(line7);
    try std.testing.expect(std.mem.eql(u8, line7, "1234567B"));

    const line, const col, root = try buffer.root.insert_chars(0, 7, "8\n9", buffer.allocator, metrics());
    buffer.update(root);

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
    buffer.update(root);

    const result3 = buffer.root.get_from_pos(.{ .row = 1, .col = 5 }, &result_buf, metrics());
    try std.testing.expectEqualDeep(result3[0 .. line1.len - 4], line1[4..]);
}

test "byte_offset_to_line_and_col" {
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
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));

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
