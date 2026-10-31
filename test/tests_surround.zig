const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;

const surround = @import("tui").exports.surround;

const a = std.testing.allocator;

var eol_mode: Buffer.EolMode = .lf;
var sanitized: bool = false;

fn metrics() Buffer.Metrics {
    return .{
        .ctx = undefined,
        .egc_length = struct {
            fn f(_: Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
                colcount.* = 1;
                return @min(egcs.len, std.unicode.utf8ByteSequenceLength(egcs[0]) catch 1);
            }
        }.f,
        .egc_chunk_width = struct {
            fn f(_: Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                return std.unicode.utf8CountCodepoints(chunk_) catch chunk_.len;
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

fn find(text: []const u8, col: usize, target: []const u8) !surround.Span {
    const now = std.Io.Clock.real.now(std.testing.io);
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(text, &eol_mode, &sanitized), now);
    return surround.find(buffer.root, .{ .row = 0, .col = col }, target, metrics());
}

fn expect_find(text: []const u8, col: usize, target: []const u8, open: usize, close: usize) !void {
    const found = try find(text, col, target);
    try std.testing.expectEqual(open, found[0].col);
    try std.testing.expectEqual(close, found[1].col);
}

test "find the enclosing bracket past sibling pairs" {
    const text: []const u8 = "foo(a(1), b(2), x)\n";
    try expect_find(text, 16, "(", 3, 17);
    try expect_find(text, 16, ")", 3, 17);
    try expect_find(text, 16, "b", 3, 17);
}

test "find a pair from its delimiters" {
    const text: []const u8 = "foo(a(1), b(2), x)\n";
    try expect_find(text, 5, "(", 5, 7);
    try expect_find(text, 7, "(", 5, 7);
}

test "find the next pair when not inside one" {
    const text: []const u8 = "x f(a) [b]\n";
    try expect_find(text, 0, "(", 3, 5);
    try expect_find(text, 0, "[", 7, 9);
    try std.testing.expectError(error.Stop, find(text, 8, "("));
}

test "find quotes" {
    const text: []const u8 = "say \"hi\" ok\n";
    try expect_find(text, 5, "\"", 4, 7);
    try expect_find(text, 5, "q", 4, 7);
}

test "find the nearest pair of any kind" {
    const text: []const u8 = "x [(\"a\")] y\n";
    try expect_find(text, 5, "s", 4, 6);
    try expect_find(text, 3, "s", 3, 7);
    try expect_find(text, 0, "s", 2, 8);
}

test "the next pair is never one before the cursor" {
    const text: []const u8 = "\"a\" (b) x\n";
    try std.testing.expectError(error.Stop, find(text, 8, "s"));
    try std.testing.expectError(error.Stop, find(text, 8, "q"));
}

fn expect_pair(expected_open: []const u8, expected_close: []const u8, pair: surround.Pair) !void {
    try std.testing.expectEqualStrings(expected_open, pair[0]);
    try std.testing.expectEqualStrings(expected_close, pair[1]);
}

test "delimiters come from the builtin pair lists" {
    try expect_pair("( ", " )", surround.padded_delimiters("("));
    try expect_pair("< ", " >", surround.padded_delimiters("<"));
    try expect_pair("(", ")", surround.padded_delimiters(")"));
    try expect_pair("{", "}", surround.padded_delimiters("B"));
    try expect_pair("\"", "\"", surround.padded_delimiters("\""));
    try expect_pair("“", "”", surround.padded_delimiters("“"));
    try expect_pair("*", "*", surround.padded_delimiters("*"));
    try expect_pair("«", "»", surround.pair_for("»"));
    try std.testing.expect(surround.is_opening_bracket("["));
    try std.testing.expect(!surround.is_opening_bracket("“"));
}

test "the nearest pair includes the typographic pairs" {
    const text: []const u8 = "x “a (b) «c»” y\n";
    try expect_find(text, 3, "s", 2, 12);
    try expect_find(text, 10, "s", 9, 11);
    try expect_find(text, 10, "q", 9, 11);
    try expect_find(text, 6, "s", 5, 7);
    try expect_find(text, 3, "q", 2, 12);
}

test "¿ ? and ¡ ! are not nearest pair candidates" {
    const text: []const u8 = "why? (a) ok\n";
    try expect_find(text, 6, "s", 5, 7);
    try std.testing.expectError(error.Stop, find(text, 0, "q"));
}

test "the next pair is the earlier of the next quotes and the next brackets" {
    try expect_find("x \"a\" (b)\n", 0, "s", 2, 4);
    try expect_find("x (b) \"a\"\n", 0, "s", 2, 4);
    try expect_find("x \"a\" (b)\n", 0, "q", 2, 4);
}

test "only pair characters are pair characters" {
    try std.testing.expect(surround.is_pair_char("("));
    try std.testing.expect(surround.is_pair_char("b"));
    try std.testing.expect(surround.is_pair_char("«"));
    try std.testing.expect(!surround.is_pair_char("z"));
}
