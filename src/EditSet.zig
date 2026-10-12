//! An edit set is a list of text edits for one document plus the hashes of
//! the document before and after the edits.
//!
//! [edits, base_hash, result_hash, base_meta, result_meta]
//!
//! edits is [[row, pos, end_row, end_pos, text], ...] with pos as a byte
//! offset in the line. All positions refer to the base document. The edits
//! are sorted by position and do not overlap.

const std = @import("std");
const cbor = @import("cbor");
const dizzy = @import("dizzy");

pub const Hash = u64;

pub const Position = struct {
    row: usize = 0,
    pos: usize = 0,

    pub fn order(a: Position, b: Position) std.math.Order {
        return if (a.row != b.row) std.math.order(a.row, b.row) else std.math.order(a.pos, b.pos);
    }
};

pub const Edit = struct {
    begin: Position,
    end: Position,
    text: []const u8,
};

pub const Tail = struct {
    base_hash: ?Hash = null,
    result_hash: ?Hash = null,
    base_meta: ?cbor.Raw = null,
    result_meta: ?cbor.Raw = null,
};

pub const Writer = struct {
    buf: *std.Io.Writer.Allocating,
    count_offset: usize,
    count: u32 = 0,
    last_end: Position = .{},

    pub const Error = std.Io.Writer.Error || error{ InvalidEditSet, TooManyEdits };

    const count_header = [_]u8{ 0x9a, 0, 0, 0, 0 };

    pub fn init(buf: *std.Io.Writer.Allocating) Error!Writer {
        try cbor.writeArrayHeader(&buf.writer, 5);
        const count_offset = buf.written().len + 1;
        try buf.writer.writeAll(&count_header);
        return .{ .buf = buf, .count_offset = count_offset };
    }

    pub fn write(self: *Writer, edit: Edit) Error!void {
        if (edit.begin.order(self.last_end) == .lt or edit.end.order(edit.begin) == .lt)
            return error.InvalidEditSet;
        if (self.count == std.math.maxInt(u32)) return error.TooManyEdits;
        try cbor.writeValue(&self.buf.writer, .{ edit.begin.row, edit.begin.pos, edit.end.row, edit.end.pos, edit.text });
        self.count += 1;
        self.last_end = edit.end;
    }

    pub fn finish(self: *Writer, tail: Tail) Error!void {
        std.mem.writeInt(u32, self.buf.written()[self.count_offset..][0..4], self.count, .big);
        inline for (@typeInfo(Tail).@"struct".field_names) |name|
            try cbor.writeValue(&self.buf.writer, @field(tail, name));
    }
};

/// Writes an edit set with a known number of sorted edits.
pub fn write(writer: *std.Io.Writer, edits: []const Edit, tail: Tail) Writer.Error!void {
    try cbor.writeArrayHeader(writer, 5);
    try cbor.writeArrayHeader(writer, edits.len);
    var last_end: Position = .{};
    for (edits) |edit| {
        if (edit.begin.order(last_end) == .lt or edit.end.order(edit.begin) == .lt)
            return error.InvalidEditSet;
        try cbor.writeValue(writer, .{ edit.begin.row, edit.begin.pos, edit.end.row, edit.end.pos, edit.text });
        last_end = edit.end;
    }
    inline for (@typeInfo(Tail).@"struct".field_names) |name|
        try cbor.writeValue(writer, @field(tail, name));
}

pub fn less_than(_: void, lhs: Edit, rhs: Edit) bool {
    return lhs.begin.order(rhs.begin) == .lt;
}

pub const Iterator = struct {
    edits: []const u8,
    remaining: usize,
    last_end: Position = .{},
    tail: Tail,

    pub const Error = cbor.Error || error{InvalidEditSet};

    pub fn init(edit_set: cbor.Raw) Error!Iterator {
        var edits: cbor.Raw = undefined;
        var tail: Tail = .{};
        if (!try cbor.match(edit_set.bytes, .{
            cbor.extract(&edits),
            cbor.extract(&tail.base_hash),
            cbor.extract(&tail.result_hash),
            cbor.extract(&tail.base_meta),
            cbor.extract(&tail.result_meta),
        })) return error.InvalidEditSet;
        var iter = edits.bytes;
        const count = cbor.decodeArrayHeader(&iter) catch return error.InvalidEditSet;
        return .{ .edits = iter, .remaining = count, .tail = tail };
    }

    pub fn next(self: *Iterator) Error!?Edit {
        if (self.remaining == 0) return null;
        var edit: Edit = undefined;
        if (!try cbor.matchValue(&self.edits, .{
            cbor.extract(&edit.begin.row),
            cbor.extract(&edit.begin.pos),
            cbor.extract(&edit.end.row),
            cbor.extract(&edit.end.pos),
            cbor.extract(&edit.text),
        })) return error.InvalidEditSet;
        if (edit.begin.order(self.last_end) == .lt or edit.end.order(edit.begin) == .lt)
            return error.InvalidEditSet;
        self.remaining -= 1;
        self.last_end = edit.end;
        return edit;
    }
};

/// Applies an edit set to a document, last edit first. The document must
/// provide `fn hash(doc) Hash` and `fn replace(doc, edit: Edit) !void`.
/// After an error the document may hold a part of the edits.
pub fn apply(allocator: std.mem.Allocator, edit_set: cbor.Raw, doc: anytype) !void {
    const iter: Iterator = try .init(edit_set);
    if (iter.tail.base_hash) |expected| if (expected != doc.hash()) return error.BaseMismatch;
    const edits = try collect(allocator, edit_set);
    defer allocator.free(edits);
    var index = edits.len;
    while (index > 0) {
        index -= 1;
        try doc.replace(edits[index]);
    }
    if (iter.tail.result_hash) |expected| if (expected != doc.hash()) return error.ResultMismatch;
}

/// The edits of an edit set as a slice. The texts point into edit_set.
pub fn collect(allocator: std.mem.Allocator, edit_set: cbor.Raw) (Iterator.Error || error{OutOfMemory})![]Edit {
    var iter: Iterator = try .init(edit_set);
    const result = try allocator.alloc(Edit, iter.remaining);
    errdefer allocator.free(result);
    for (result) |*edit| edit.* = (try iter.next()).?;
    return result;
}

pub const ByteEdit = struct {
    begin: usize,
    end: usize,
    text: []const u8,
    begin_position: Position,
    end_position: Position,

    /// the position of the end of text after the edit
    pub fn new_end_position(self: ByteEdit) Position {
        const eol = std.mem.lastIndexOfScalar(u8, self.text, '\n') orelse
            return .{ .row = self.begin_position.row, .pos = self.begin_position.pos + self.text.len };
        return .{
            .row = self.begin_position.row + std.mem.count(u8, self.text, "\n"),
            .pos = self.text.len - eol - 1,
        };
    }
};

/// The edits of an edit set with byte offsets in src, the base document.
/// For a consumer that takes the edits one after the other, for example
/// tree-sitter or LSP didChange, give them last edit first. Then each
/// offset is still valid when its edit is applied.
pub fn byte_edits(allocator: std.mem.Allocator, edit_set: cbor.Raw, src: []const u8) (Iterator.Error || error{OutOfMemory})![]ByteEdit {
    var iter: Iterator = try .init(edit_set);
    const result = try allocator.alloc(ByteEdit, iter.remaining);
    errdefer allocator.free(result);
    var scan: OffsetScan = .{};
    for (result) |*byte_edit| {
        const edit = (try iter.next()).?;
        byte_edit.* = .{
            .begin = scan.offset(src, edit.begin) orelse return error.InvalidEditSet,
            .end = scan.offset(src, edit.end) orelse return error.InvalidEditSet,
            .text = edit.text,
            .begin_position = edit.begin,
            .end_position = edit.end,
        };
    }
    return result;
}

const OffsetScan = struct {
    row: usize = 0,
    line_begin: usize = 0,

    fn offset(self: *OffsetScan, text: []const u8, position: Position) ?usize {
        while (self.row < position.row) {
            const eol = std.mem.indexOfScalarPos(u8, text, self.line_begin, '\n') orelse return null;
            self.row += 1;
            self.line_begin = eol + 1;
        }
        const result = self.line_begin + position.pos;
        return if (result <= text.len) result else null;
    }
};

pub fn is_empty(edit_set: cbor.Raw) bool {
    if (edit_set.bytes.len == 0) return true;
    const iter = Iterator.init(edit_set) catch return true;
    return iter.remaining == 0;
}

/// Hashes document content with every CRLF counted as one LF.
pub const Hasher = struct {
    state: std.hash.XxHash3,
    pending_cr: bool = false,

    pub fn init() Hasher {
        return .{ .state = .init(0) };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        var rest = bytes;
        if (rest.len == 0) return;
        if (self.pending_cr) {
            self.pending_cr = false;
            if (rest[0] != '\n') self.state.update("\r");
        }
        while (std.mem.indexOfScalar(u8, rest, '\r')) |cr| {
            self.state.update(rest[0..cr]);
            rest = rest[cr + 1 ..];
            if (rest.len == 0) {
                self.pending_cr = true;
                return;
            }
            if (rest[0] != '\n') self.state.update("\r");
        }
        self.state.update(rest);
    }

    pub fn final(self: *Hasher) Hash {
        if (self.pending_cr) self.state.update("\r");
        self.pending_cr = false;
        return self.state.final();
    }
};

pub fn hash(content: []const u8) Hash {
    var hasher: Hasher = .init();
    hasher.update(content);
    return hasher.final();
}

pub const DiffError = Writer.Error || error{ OutOfMemory, InputTooLarge };

/// Writes the edit set that turns src into dst. The positions count lines
/// by LF, so text for a buffer must use LF line endings in both strings.
pub fn diff_strings(allocator: std.mem.Allocator, edit_set: *std.Io.Writer.Allocating, src: []const u8, dst: []const u8) DiffError!void {
    if (src.len + dst.len > std.math.maxInt(i32) / 4) return error.InputTooLarge;

    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();

    var dizzy_edits: std.ArrayList(dizzy.Edit) = .empty;
    const scratch = try arena.alloc(u32, 4 * (src.len + dst.len) + 2);
    try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, src, dst, scratch);

    var hunks: std.ArrayList(Hunk) = .empty;
    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    for (dizzy_edits.items) |dizzy_edit| {
        const len = dizzy_edit.range.end - dizzy_edit.range.start;
        switch (dizzy_edit.kind) {
            .equal => {
                src_pos += len;
                dst_pos += len;
            },
            .delete => {
                try add_hunk(arena, &hunks, src, .{ .src_begin = src_pos, .src_end = src_pos + len, .dst_begin = dst_pos, .dst_end = dst_pos });
                src_pos += len;
            },
            .insert => {
                try add_hunk(arena, &hunks, src, .{ .src_begin = src_pos, .src_end = src_pos, .dst_begin = dst_pos, .dst_end = dst_pos + len });
                dst_pos += len;
            },
        }
    }

    var writer: Writer = try .init(edit_set);
    var scan: LineScan = .{};
    var index: usize = 0;
    while (index < hunks.items.len) : (index += 1) {
        var hunk = hunks.items[index];
        // an edit must not end inside a UTF-8 sequence, the bytes that follow are equal in src and dst
        while (hunk.src_end < src.len and is_continuation(src[hunk.src_end])) {
            hunk.src_end += 1;
            hunk.dst_end += 1;
            if (index + 1 < hunks.items.len and hunks.items[index + 1].src_begin < hunk.src_end) {
                index += 1;
                hunk.src_end = hunks.items[index].src_end;
                hunk.dst_end = hunks.items[index].dst_end;
            }
        }
        hunk.trim(src, dst);
        if (hunk.src_begin == hunk.src_end and hunk.dst_begin == hunk.dst_end) continue;
        try writer.write(.{
            .begin = scan.position(src, hunk.src_begin),
            .end = scan.position(src, hunk.src_end),
            .text = dst[hunk.dst_begin..hunk.dst_end],
        });
    }
    try writer.finish(.{ .base_hash = hash(src), .result_hash = hash(dst) });
}

const Hunk = struct {
    src_begin: usize,
    src_end: usize,
    dst_begin: usize,
    dst_end: usize,

    // the widening to whole UTF-8 sequences can leave equal characters at both ends
    fn trim(self: *Hunk, src: []const u8, dst: []const u8) void {
        const old = src[self.src_begin..self.src_end];
        const new = dst[self.dst_begin..self.dst_end];
        var prefix = std.mem.indexOfDiff(u8, old, new) orelse @min(old.len, new.len);
        while (prefix > 0 and (is_continuation_at(old, prefix) or is_continuation_at(new, prefix))) prefix -= 1;
        self.src_begin += prefix;
        self.dst_begin += prefix;

        const old_rest = old[prefix..];
        const new_rest = new[prefix..];
        var suffix: usize = 0;
        while (suffix < old_rest.len and suffix < new_rest.len and
            old_rest[old_rest.len - 1 - suffix] == new_rest[new_rest.len - 1 - suffix]) suffix += 1;
        while (suffix > 0 and (is_continuation(old_rest[old_rest.len - suffix]) or is_continuation(new_rest[new_rest.len - suffix]))) suffix -= 1;
        self.src_end -= suffix;
        self.dst_end -= suffix;
    }
};

fn is_continuation_at(text: []const u8, offset: usize) bool {
    return offset < text.len and is_continuation(text[offset]);
}

fn is_continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn add_hunk(allocator: std.mem.Allocator, hunks: *std.ArrayList(Hunk), src: []const u8, hunk_: Hunk) error{OutOfMemory}!void {
    var hunk = hunk_;
    const floor = if (hunks.items.len > 0) hunks.items[hunks.items.len - 1].src_end else 0;
    // an edit must not begin inside a UTF-8 sequence, the bytes before it are equal in src and dst
    while (hunk.src_begin > floor and hunk.src_begin < src.len and is_continuation(src[hunk.src_begin])) {
        hunk.src_begin -= 1;
        hunk.dst_begin -= 1;
    }
    if (hunks.items.len > 0) {
        const last = &hunks.items[hunks.items.len - 1];
        if (last.src_end == hunk.src_begin and last.dst_end == hunk.dst_begin) {
            last.src_end = hunk.src_end;
            last.dst_end = hunk.dst_end;
            return;
        }
    }
    (try hunks.addOne(allocator)).* = hunk;
}

const LineScan = struct {
    offset: usize = 0,
    row: usize = 0,
    line_begin: usize = 0,

    fn position(self: *LineScan, text: []const u8, offset: usize) Position {
        while (std.mem.indexOfScalarPos(u8, text[0..offset], self.offset, '\n')) |eol| {
            self.row += 1;
            self.line_begin = eol + 1;
            self.offset = eol + 1;
        }
        self.offset = offset;
        return .{ .row = self.row, .pos = offset - self.line_begin };
    }
};

const testing = std.testing;

fn expect_edits(edit_set: []const u8, expected: []const Edit) !void {
    var iter: Iterator = try .init(.{ .bytes = edit_set });
    try testing.expectEqual(expected.len, iter.remaining);
    for (expected) |edit| {
        const actual = (try iter.next()).?;
        try testing.expectEqual(edit.begin, actual.begin);
        try testing.expectEqual(edit.end, actual.end);
        try testing.expectEqualStrings(edit.text, actual.text);
    }
    try testing.expectEqual(null, try iter.next());
}

fn offset_of(text: []const u8, position: Position) usize {
    var offset: usize = 0;
    var row = position.row;
    while (row > 0) : (row -= 1) offset = std.mem.indexOfScalarPos(u8, text, offset, '\n').? + 1;
    return offset + position.pos;
}

fn apply_to_string(allocator: std.mem.Allocator, src: []const u8, edit_set: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var iter: Iterator = try .init(.{ .bytes = edit_set });
    var offset: usize = 0;
    while (try iter.next()) |edit| {
        const begin = offset_of(src, edit.begin);
        try result.appendSlice(allocator, src[offset..begin]);
        try result.appendSlice(allocator, edit.text);
        offset = offset_of(src, edit.end);
    }
    try result.appendSlice(allocator, src[offset..]);
    return result.toOwnedSlice(allocator);
}

fn expect_diff(src: []const u8, dst: []const u8, expected: []const Edit) !void {
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, src, dst);
    try expect_edits(edit_set.written(), expected);
    try expect_round_trip(src, dst, edit_set.written());
}

fn expect_round_trip(src: []const u8, dst: []const u8, edit_set: []const u8) !void {
    const result = try apply_to_string(testing.allocator, src, edit_set);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(dst, result);
    const iter: Iterator = try .init(.{ .bytes = edit_set });
    try testing.expectEqual(hash(src), iter.tail.base_hash.?);
    try testing.expectEqual(hash(dst), iter.tail.result_hash.?);
}

test "writer and iterator" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var writer: Writer = try .init(&buf);
    const edits = [_]Edit{
        .{ .begin = .{ .row = 0, .pos = 2 }, .end = .{ .row = 0, .pos = 4 }, .text = "x" },
        .{ .begin = .{ .row = 0, .pos = 4 }, .end = .{ .row = 0, .pos = 4 }, .text = "insert" },
        .{ .begin = .{ .row = 3, .pos = 0 }, .end = .{ .row = 5, .pos = 1 }, .text = "" },
    };
    for (edits) |edit| try writer.write(edit);
    try writer.finish(.{ .base_hash = 1, .result_hash = std.math.maxInt(u64) });

    try expect_edits(buf.written(), &edits);
    const iter: Iterator = try .init(.{ .bytes = buf.written() });
    try testing.expectEqual(1, iter.tail.base_hash.?);
    try testing.expectEqual(std.math.maxInt(u64), iter.tail.result_hash.?);
    try testing.expectEqual(null, iter.tail.base_meta);
    try testing.expectEqual(null, iter.tail.result_meta);
}

const TestDocument = struct {
    text: std.ArrayList(u8) = .empty,
    base: []const u8,

    fn hash(self: *const TestDocument) Hash {
        return EditSet.hash(self.text.items);
    }

    fn replace(self: *TestDocument, edit: Edit) !void {
        const begin = offset_of(self.base, edit.begin);
        const end = offset_of(self.base, edit.end);
        try self.text.replaceRange(testing.allocator, begin, end - begin, edit.text);
    }
};

const EditSet = @This();

fn expect_apply(src: []const u8, dst: []const u8, edit_set: []const u8) !void {
    var doc: TestDocument = .{ .base = src };
    defer doc.text.deinit(testing.allocator);
    try doc.text.appendSlice(testing.allocator, src);
    try apply(testing.allocator, .{ .bytes = edit_set }, &doc);
    try testing.expectEqualStrings(dst, doc.text.items);
}

test "apply: last edit first, with both hash checks" {
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, "one\ntwo\nthree\n", "ONE\ntwo\n3\nfour\n");
    try expect_apply("one\ntwo\nthree\n", "ONE\ntwo\n3\nfour\n", edit_set.written());
}

test "apply: a wrong base hash changes nothing" {
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, "one\ntwo\n", "one\n2\n");
    var doc: TestDocument = .{ .base = "one\nTWO\n" };
    defer doc.text.deinit(testing.allocator);
    try doc.text.appendSlice(testing.allocator, "one\nTWO\n");
    try testing.expectError(error.BaseMismatch, apply(testing.allocator, .{ .bytes = edit_set.written() }, &doc));
    try testing.expectEqualStrings("one\nTWO\n", doc.text.items);
}

test "apply: a wrong result hash is an error" {
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try write(&edit_set.writer, &.{.{ .begin = .{}, .end = .{}, .text = "x" }}, .{ .base_hash = hash("one"), .result_hash = hash("yone") });
    var doc: TestDocument = .{ .base = "one" };
    defer doc.text.deinit(testing.allocator);
    try doc.text.appendSlice(testing.allocator, "one");
    try testing.expectError(error.ResultMismatch, apply(testing.allocator, .{ .bytes = edit_set.written() }, &doc));
}

test "apply: null hashes are not compared" {
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try write(&edit_set.writer, &.{
        .{ .begin = .{}, .end = .{}, .text = "a" },
        .{ .begin = .{}, .end = .{}, .text = "b" },
        .{ .begin = .{ .row = 0, .pos = 1 }, .end = .{ .row = 0, .pos = 3 }, .text = "" },
    }, .{});
    try expect_apply("one", "abo", edit_set.written());
    try testing.expect(!is_empty(.{ .bytes = edit_set.written() }));
    try testing.expect(is_empty(.empty));
}

test "write rejects unsorted edits" {
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try testing.expectError(error.InvalidEditSet, write(&edit_set.writer, &.{
        .{ .begin = .{ .row = 1 }, .end = .{ .row = 1 }, .text = "a" },
        .{ .begin = .{}, .end = .{}, .text = "b" },
    }, .{}));
}

test "byte_edits: offsets in the base document" {
    const src = "one\ntwo\nthree\n";
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try write(&edit_set.writer, &.{
        .{ .begin = .{ .row = 0, .pos = 1 }, .end = .{ .row = 0, .pos = 3 }, .text = "N" },
        .{ .begin = .{ .row = 1, .pos = 3 }, .end = .{ .row = 2, .pos = 0 }, .text = "" },
        .{ .begin = .{ .row = 3, .pos = 0 }, .end = .{ .row = 3, .pos = 0 }, .text = "end" },
    }, .{});
    const result = try byte_edits(testing.allocator, .{ .bytes = edit_set.written() }, src);
    defer testing.allocator.free(result);
    try testing.expectEqual(3, result.len);
    try testing.expectEqual(1, result[0].begin);
    try testing.expectEqual(3, result[0].end);
    try testing.expectEqual(7, result[1].begin);
    try testing.expectEqual(8, result[1].end);
    try testing.expectEqual(14, result[2].begin);
    try testing.expectEqual(14, result[2].end);
    try testing.expectEqualStrings("end", result[2].text);
    try testing.expectEqual(Position{ .row = 0, .pos = 2 }, result[0].new_end_position());
    try testing.expectEqual(Position{ .row = 1, .pos = 3 }, result[1].new_end_position());
    try testing.expectEqual(Position{ .row = 3, .pos = 3 }, result[2].new_end_position());
    const multi_line: ByteEdit = .{ .begin = 0, .end = 0, .text = "a\nbc\nd", .begin_position = .{ .row = 4, .pos = 7 }, .end_position = .{ .row = 4, .pos = 7 } };
    try testing.expectEqual(Position{ .row = 6, .pos = 1 }, multi_line.new_end_position());
    const ends_with_eol: ByteEdit = .{ .begin = 0, .end = 0, .text = "a\n", .begin_position = .{ .row = 4, .pos = 7 }, .end_position = .{ .row = 4, .pos = 7 } };
    try testing.expectEqual(Position{ .row = 5, .pos = 0 }, ends_with_eol.new_end_position());

    try testing.expectError(error.InvalidEditSet, byte_edits(testing.allocator, .{ .bytes = edit_set.written() }, "one\n"));
}

test "byte_edits: applied last edit first they give the target" {
    const src = "let a = 1;\nlet b = 2;\n\u{e9}t\u{e9}\n";
    const dst = "let a = 10;\nconst c = 2;\n\u{e8}t\u{e9}!\nmore\n";
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, src, dst);
    const result = try byte_edits(testing.allocator, .{ .bytes = edit_set.written() }, src);
    defer testing.allocator.free(result);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, src);
    var index = result.len;
    while (index > 0) {
        index -= 1;
        try text.replaceRange(testing.allocator, result[index].begin, result[index].end - result[index].begin, result[index].text);
    }
    try testing.expectEqualStrings(dst, text.items);
}

test "empty edit set without hashes" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var writer: Writer = try .init(&buf);
    try writer.finish(.{});
    var iter: Iterator = try .init(.{ .bytes = buf.written() });
    try testing.expectEqual(null, try iter.next());
    try testing.expectEqual(null, iter.tail.base_hash);
    try testing.expectEqual(null, iter.tail.result_hash);
}

test "meta values pass through" {
    var meta_buf: [64]u8 = undefined;
    const base_meta = cbor.fmt(&meta_buf, .{ "undo", 42, .{ 1, 2 } });
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var writer: Writer = try .init(&buf);
    try writer.write(.{ .begin = .{}, .end = .{}, .text = "a" });
    try writer.finish(.{ .base_meta = .{ .bytes = base_meta }, .result_meta = .{ .bytes = "\x01" } });
    const iter: Iterator = try .init(.{ .bytes = buf.written() });
    try testing.expectEqualSlices(u8, base_meta, iter.tail.base_meta.?.bytes);
    try testing.expectEqualSlices(u8, "\x01", iter.tail.result_meta.?.bytes);
}

test "the fixed width count is valid for the plain cbor decoders" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var writer: Writer = try .init(&buf);
    try writer.write(.{ .begin = .{ .row = 1, .pos = 2 }, .end = .{ .row = 1, .pos = 3 }, .text = "t" });
    try writer.finish(.{ .base_hash = 7 });

    var edits: []const u8 = undefined;
    var base_hash: ?u64 = null;
    try testing.expect(try cbor.match(buf.written(), .{ cbor.extract_cbor(&edits), cbor.extract(&base_hash), cbor.null_, cbor.null_, cbor.null_ }));
    try testing.expectEqual(7, base_hash.?);
    var row: usize = undefined;
    var text: []const u8 = undefined;
    try testing.expect(try cbor.match(edits, .{.{ cbor.extract(&row), 2, 1, 3, cbor.extract(&text) }}));
    try testing.expectEqual(1, row);
    try testing.expectEqualStrings("t", text);

    var iter: []const u8 = buf.written();
    try cbor.skipValue(&iter);
    try testing.expectEqual(0, iter.len);

    const json = try cbor.toJsonAlloc(testing.allocator, buf.written());
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[[[1,2,1,3,\"t\"]],7,null,null,null]", json);
}

test "writer and iterator reject unsorted and overlapping edits" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var writer: Writer = try .init(&buf);
    try writer.write(.{ .begin = .{ .row = 2, .pos = 0 }, .end = .{ .row = 2, .pos = 5 }, .text = "" });
    try testing.expectError(error.InvalidEditSet, writer.write(.{ .begin = .{ .row = 1, .pos = 0 }, .end = .{ .row = 1, .pos = 1 }, .text = "" }));
    try testing.expectError(error.InvalidEditSet, writer.write(.{ .begin = .{ .row = 2, .pos = 4 }, .end = .{ .row = 2, .pos = 6 }, .text = "" }));
    try testing.expectError(error.InvalidEditSet, writer.write(.{ .begin = .{ .row = 3, .pos = 4 }, .end = .{ .row = 3, .pos = 2 }, .text = "" }));

    const unsorted = try cbor.fromJsonAlloc(testing.allocator, "[[[2,0,2,5,\"\"],[1,0,1,1,\"\"]],null,null,null,null]");
    defer testing.allocator.free(unsorted);
    var iter: Iterator = try .init(.{ .bytes = unsorted });
    _ = try iter.next();
    try testing.expectError(error.InvalidEditSet, iter.next());

    const bare_list = try cbor.fromJsonAlloc(testing.allocator, "[[2,0,2,5,\"\"]]");
    defer testing.allocator.free(bare_list);
    try testing.expectError(error.InvalidEditSet, Iterator.init(.{ .bytes = bare_list }));
}

test "hash: line ending mode does not matter" {
    try testing.expectEqual(hash("one\ntwo\n"), hash("one\r\ntwo\r\n"));
    try testing.expectEqual(hash("one\ntwo"), hash("one\r\ntwo"));
    try testing.expect(hash("one\ntwo") != hash("one\ntwo\n"));
    try testing.expect(hash("one\rtwo") != hash("one\ntwo"));
    try testing.expect(hash("one\r") != hash("one"));
}

test "hash: known values" {
    try testing.expectEqual(0x2d06800538d394c2, hash(""));
    try testing.expectEqual(std.hash.XxHash3.hash(0, "flow\ncontrol\n"), hash("flow\r\ncontrol\r\n"));
}

test "hash: the split of the input does not matter" {
    const text = "one\r\ntwo\r\rthree\r\n\r\nfour\r";
    const expected = hash(text);
    for (0..text.len + 1) |split| {
        var hasher: Hasher = .init();
        hasher.update(text[0..split]);
        hasher.update(text[split..]);
        try testing.expectEqual(expected, hasher.final());
    }
}

test "diff_strings: fixed cases" {
    try expect_diff("", "", &.{});
    try expect_diff("same\ntext\n", "same\ntext\n", &.{});
    try expect_diff("", "new", &.{.{ .begin = .{}, .end = .{}, .text = "new" }});
    try expect_diff("old", "", &.{.{ .begin = .{}, .end = .{ .row = 0, .pos = 3 }, .text = "" }});
    try expect_diff("one\ntwo\nthree\n", "one\nthree\n", &.{
        .{ .begin = .{ .row = 1, .pos = 1 }, .end = .{ .row = 2, .pos = 1 }, .text = "" },
    });
    try expect_diff("one\ntwo\n", "one\ntwo\nthree\n", &.{
        .{ .begin = .{ .row = 2, .pos = 0 }, .end = .{ .row = 2, .pos = 0 }, .text = "three\n" },
    });
    try expect_diff("let a = 1;\nlet b = 2;\n", "let a = 10;\nlet c = 2;\n", &.{
        .{ .begin = .{ .row = 0, .pos = 9 }, .end = .{ .row = 0, .pos = 9 }, .text = "0" },
        .{ .begin = .{ .row = 1, .pos = 4 }, .end = .{ .row = 1, .pos = 5 }, .text = "c" },
    });
}

test "diff_strings: a replacement is one edit" {
    try expect_diff("abc", "axc", &.{
        .{ .begin = .{ .row = 0, .pos = 1 }, .end = .{ .row = 0, .pos = 2 }, .text = "x" },
    });
}

test "diff_strings: edits keep UTF-8 sequences whole" {
    try expect_diff("caf\u{e9}", "caf\u{e8}", &.{
        .{ .begin = .{ .row = 0, .pos = 3 }, .end = .{ .row = 0, .pos = 5 }, .text = "\u{e8}" },
    });
    try expect_diff("\u{65e5}\u{672c}", "\u{65e5}\u{6708}\u{672c}", &.{
        .{ .begin = .{ .row = 0, .pos = 3 }, .end = .{ .row = 0, .pos = 3 }, .text = "\u{6708}" },
    });
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, "x\u{e9}\u{e8}y", "x\u{e8}\u{e9}\u{ea}y");
    var iter: Iterator = try .init(.{ .bytes = edit_set.written() });
    while (try iter.next()) |edit| try testing.expect(std.unicode.utf8ValidateSlice(edit.text));
}

test "diff_strings: random strings round trip" {
    const pieces = [_][]const u8{ "a", "b", "c", " ", "\n", "\n", "\u{e9}", "\u{e8}", "\u{65e5}", "\u{1f600}", "fn ", "end" };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var dst: std.ArrayList(u8) = .empty;
    defer dst.deinit(testing.allocator);
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();

    for (0..500) |_| {
        src.clearRetainingCapacity();
        dst.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 40)) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            switch (random.uintLessThan(u8, 10)) {
                0 => try src.appendSlice(testing.allocator, piece),
                1 => try dst.appendSlice(testing.allocator, piece),
                2 => {
                    try src.appendSlice(testing.allocator, piece);
                    try dst.appendSlice(testing.allocator, pieces[random.uintLessThan(usize, pieces.len)]);
                },
                else => {
                    try src.appendSlice(testing.allocator, piece);
                    try dst.appendSlice(testing.allocator, piece);
                },
            }
        }
        edit_set.clearRetainingCapacity();
        try diff_strings(testing.allocator, &edit_set, src.items, dst.items);
        try expect_round_trip(src.items, dst.items, edit_set.written());
        try expect_apply(src.items, dst.items, edit_set.written());
        var iter: Iterator = try .init(.{ .bytes = edit_set.written() });
        while (try iter.next()) |edit| try testing.expect(std.unicode.utf8ValidateSlice(edit.text));
    }
}
