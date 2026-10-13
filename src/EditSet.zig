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

pub fn apply_to_string(allocator: std.mem.Allocator, text: *std.ArrayList(u8), edit_set: cbor.Raw) !void {
    const iter: Iterator = try .init(edit_set);
    if (iter.tail.base_hash) |expected| if (expected != hash(text.items)) return error.BaseMismatch;
    const edits = try byte_edits(allocator, edit_set, text.items);
    defer allocator.free(edits);
    var index = edits.len;
    while (index > 0) {
        index -= 1;
        try text.replaceRange(allocator, edits[index].begin, edits[index].end - edits[index].begin, edits[index].text);
    }
    if (iter.tail.result_hash) |expected| if (expected != hash(text.items)) return error.ResultMismatch;
}

pub fn is_empty(edit_set: cbor.Raw) bool {
    if (edit_set.bytes.len == 0) return true;
    const iter = Iterator.init(edit_set) catch return true;
    return iter.remaining == 0;
}

/// Hashes document content with every CRLF counted as one LF.
pub const Hasher = struct {
    state: std.hash.XxHash64,
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
/// The diff compares lines first and then the bytes inside each small block
/// of changed lines. A large block becomes one edit.
pub fn diff_strings(allocator: std.mem.Allocator, edit_set: *std.Io.Writer.Allocating, src: []const u8, dst: []const u8) DiffError!void {
    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    try diff_lines(arena, &hunks, src, dst);
    var writer: Writer = try .init(edit_set);
    try write_hunks(&writer, hunks.items, src, dst, .{});
    try writer.finish(.{ .base_hash = hash(src), .result_hash = hash(dst) });
}

pub const ByteRange = struct {
    begin: usize,
    end: usize,
};

const HunkOffset = struct {
    rows: usize = 0,
    bytes: usize = 0,
    allocator: ?std.mem.Allocator = null,
    byte_ranges: ?*std.ArrayList(ByteRange) = null,
};

fn write_hunks(writer: *Writer, hunks: []const Hunk, src: []const u8, dst: []const u8, offset: HunkOffset) DiffError!void {
    var scan: LineScan = .{};
    var index: usize = 0;
    while (index < hunks.len) : (index += 1) {
        var hunk = hunks[index];
        // an edit must not end inside a UTF-8 sequence, the bytes that follow are equal in src and dst
        while (hunk.src_end < src.len and is_continuation(src[hunk.src_end])) {
            hunk.src_end += 1;
            hunk.dst_end += 1;
            if (index + 1 < hunks.len and hunks[index + 1].src_begin < hunk.src_end) {
                index += 1;
                hunk.src_end = hunks[index].src_end;
                hunk.dst_end = hunks[index].dst_end;
            }
        }
        hunk.trim(src, dst);
        if (hunk.src_begin == hunk.src_end and hunk.dst_begin == hunk.dst_end) continue;
        var begin = scan.position(src, hunk.src_begin);
        var end = scan.position(src, hunk.src_end);
        begin.row += offset.rows;
        end.row += offset.rows;
        try writer.write(.{ .begin = begin, .end = end, .text = dst[hunk.dst_begin..hunk.dst_end] });
        if (offset.byte_ranges) |byte_ranges|
            (try byte_ranges.addOne(offset.allocator.?)).* = .{ .begin = offset.bytes + hunk.src_begin, .end = offset.bytes + hunk.src_end };
    }
}

/// Writes the edit set that turns the rope src into the rope dst. Nodes that
/// both ropes share at their begin and at their end are not read. A rope is
/// a pointer to a node with `weights_sum()` and the cases `node` (`left` and
/// `right`) and `leaf` (`buf` and `eol`). byte_ranges gets the byte range in
/// src of each edit. It gives error.InputTooLarge above max_middle_lines.
pub fn diff_roots(
    allocator: std.mem.Allocator,
    edit_set: *std.Io.Writer.Allocating,
    src: anytype,
    dst: @TypeOf(src),
    tail: Tail,
    max_middle_lines: usize,
    byte_ranges: ?*std.ArrayList(ByteRange),
) DiffError!void {
    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();

    var writer: Writer = try .init(edit_set);
    if (src != dst) {
        const Rope = RopeOps(@TypeOf(src));
        const src_rows = Rope.eols(src) + 1;
        const dst_rows = Rope.eols(dst) + 1;
        const prefix_rows = @min(Rope.common_eols(src, dst, .forward), @min(src_rows, dst_rows) - 1);
        const suffix_rows = @min(Rope.common_eols(src, dst, .backward), @min(src_rows, dst_rows) - 1 - prefix_rows);
        if (src_rows + dst_rows - 2 * (prefix_rows + suffix_rows) > max_middle_lines) return error.InputTooLarge;

        const src_begin = Rope.row_offset(src, prefix_rows);
        var src_middle: std.Io.Writer.Allocating = .init(arena);
        try Rope.write_range(src, &src_middle.writer, src_begin, Rope.row_offset(src, src_rows - suffix_rows));
        var dst_middle: std.Io.Writer.Allocating = .init(arena);
        try Rope.write_range(dst, &dst_middle.writer, Rope.row_offset(dst, prefix_rows), Rope.row_offset(dst, dst_rows - suffix_rows));

        var hunks: std.ArrayList(Hunk) = .empty;
        try diff_lines(arena, &hunks, src_middle.written(), dst_middle.written());
        try write_hunks(&writer, hunks.items, src_middle.written(), dst_middle.written(), .{
            .rows = prefix_rows,
            .bytes = src_begin,
            .allocator = allocator,
            .byte_ranges = byte_ranges,
        });
    }
    try writer.finish(tail);
}

fn RopeOps(comptime Root: type) type {
    return struct {
        const Direction = enum { forward, backward };

        fn eols(node: Root) usize {
            return node.weights_sum().eols;
        }

        fn len(node: Root) usize {
            return node.weights_sum().len;
        }

        /// The number of line ends in the begin (or the end) of both ropes that
        /// is made of the same nodes. Equal node pointers mean equal content.
        fn common_eols(a: Root, b: Root, direction: Direction) usize {
            var a_stack: Stack = .{};
            var b_stack: Stack = .{};
            a_stack.push(a);
            b_stack.push(b);
            var count: usize = 0;
            while (a_stack.top()) |a_node| {
                const b_node = b_stack.top() orelse break;
                if (a_node == b_node) {
                    count += eols(a_node);
                    a_stack.pop();
                    b_stack.pop();
                } else if (a_node.* == .node and (b_node.* != .node or len(a_node) >= len(b_node))) {
                    a_stack.descend(direction);
                } else if (b_node.* == .node) {
                    b_stack.descend(direction);
                } else break;
            }
            return count;
        }

        const Stack = struct {
            nodes: [256]Root = undefined,
            len: usize = 0,

            fn top(self: *const Stack) ?Root {
                return if (self.len == 0) null else self.nodes[self.len - 1];
            }

            fn push(self: *Stack, node: Root) void {
                if (self.len < self.nodes.len) {
                    self.nodes[self.len] = node;
                    self.len += 1;
                }
            }

            fn pop(self: *Stack) void {
                self.len -= 1;
            }

            fn descend(self: *Stack, direction: Direction) void {
                const branch = self.nodes[self.len - 1].node;
                self.len -= 1;
                switch (direction) {
                    .forward => {
                        self.push(branch.right);
                        self.push(branch.left);
                    },
                    .backward => {
                        self.push(branch.left);
                        self.push(branch.right);
                    },
                }
            }
        };

        /// the byte offset of the begin of a row, with one byte for each line end
        fn row_offset(node: Root, row: usize) usize {
            if (row == 0) return 0;
            if (row > eols(node)) return len(node);
            var current = node;
            var remaining = row;
            var offset: usize = 0;
            while (true) switch (current.*) {
                .node => |*branch| if (eols(branch.left) >= remaining) {
                    current = branch.left;
                } else {
                    remaining -= eols(branch.left);
                    offset += len(branch.left);
                    current = branch.right;
                },
                .leaf => return offset + len(current),
            };
        }

        fn write_range(node: Root, writer: *std.Io.Writer, begin: usize, end: usize) std.Io.Writer.Error!void {
            if (begin >= end) return;
            switch (node.*) {
                .node => |*branch| {
                    const left_len = len(branch.left);
                    if (begin < left_len) try write_range(branch.left, writer, begin, @min(end, left_len));
                    if (end > left_len) try write_range(branch.right, writer, begin -| left_len, end - left_len);
                },
                .leaf => |*leaf| {
                    if (begin < leaf.buf.len) try writer.writeAll(leaf.buf[begin..@min(end, leaf.buf.len)]);
                    if (leaf.eol and end > leaf.buf.len) try writer.writeByte('\n');
                },
            }
        }
    };
}

/// the part of two texts between their common first lines and their common last lines
const Middle = struct {
    begin: usize,
    src_end: usize,
    dst_end: usize,

    fn of(src: []const u8, dst: []const u8) Middle {
        const prefix = std.mem.indexOfDiff(u8, src, dst) orelse @min(src.len, dst.len);
        const begin = if (std.mem.lastIndexOfScalar(u8, src[0..prefix], '\n')) |eol| eol + 1 else 0;
        const max_suffix = @min(src.len, dst.len) - prefix;
        var suffix: usize = 0;
        while (suffix < max_suffix and src[src.len - 1 - suffix] == dst[dst.len - 1 - suffix]) suffix += 1;
        // the common end must begin at the begin of a line in both texts
        const tail = src[src.len - suffix ..];
        const src_at_line = suffix == src.len or src[src.len - suffix - 1] == '\n';
        const dst_at_line = suffix == dst.len or dst[dst.len - suffix - 1] == '\n';
        if (suffix > 0 and !(src_at_line and dst_at_line))
            suffix = if (std.mem.indexOfScalar(u8, tail, '\n')) |eol| suffix - eol - 1 else 0;
        return .{ .begin = begin, .src_end = src.len - suffix, .dst_end = dst.len - suffix };
    }
};

fn count_lines(text: []const u8) usize {
    if (text.len == 0) return 0;
    return std.mem.count(u8, text, "\n") + @intFromBool(text[text.len - 1] != '\n');
}

/// The number of lines of src and dst between their common first lines and
/// their common last lines. The time of diff_strings depends on this number,
/// and in the worst case it grows with its square.
pub fn middle_lines(src: []const u8, dst: []const u8) usize {
    const middle: Middle = .of(src, dst);
    return count_lines(src[middle.begin..middle.src_end]) + count_lines(dst[middle.begin..middle.dst_end]);
}

pub const Estimate = struct {
    /// the lines of both texts between their common first lines and their common last lines
    middle_lines: usize,
    /// the middle lines of one text that the other text does not have, this many lines differ at least
    changed_lines: usize,

    /// The time of diff_strings grows with this product. It is a lower
    /// bound: lines that only moved are not counted as changed.
    pub fn cost(self: Estimate) usize {
        return self.middle_lines *| @max(self.changed_lines, 1);
    }
};

pub fn estimate(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) error{OutOfMemory}!Estimate {
    const middle: Middle = .of(src, dst);
    var counts: std.AutoHashMapUnmanaged(u64, isize) = .empty;
    defer counts.deinit(allocator);
    var middle_lines_: usize = 0;
    var src_lines = std.mem.splitScalar(u8, src[middle.begin..middle.src_end], '\n');
    while (src_lines.next()) |line| {
        if (line.len == 0 and src_lines.peek() == null) break;
        middle_lines_ += 1;
        const entry = try counts.getOrPutValue(allocator, std.hash.Wyhash.hash(0, line), 0);
        entry.value_ptr.* += 1;
    }
    var changed: usize = 0;
    var dst_lines = std.mem.splitScalar(u8, dst[middle.begin..middle.dst_end], '\n');
    while (dst_lines.next()) |line| {
        if (line.len == 0 and dst_lines.peek() == null) break;
        middle_lines_ += 1;
        if (counts.getPtr(std.hash.Wyhash.hash(0, line))) |count| {
            if (count.* > 0) count.* -= 1 else changed += 1;
        } else changed += 1;
    }
    var remaining = counts.valueIterator();
    while (remaining.next()) |count| changed += @intCast(count.*);
    return .{ .middle_lines = middle_lines_, .changed_lines = changed };
}

const Lines = struct {
    lines: []const []const u8,
    hashes: []const u64,
    offsets: []const usize,

    fn split(allocator: std.mem.Allocator, text: []const u8, base_offset: usize) error{OutOfMemory}!Lines {
        const count = count_lines(text);
        const lines = try allocator.alloc([]const u8, count);
        const hashes = try allocator.alloc(u64, count);
        const offsets = try allocator.alloc(usize, count + 1);
        var offset: usize = 0;
        for (lines, hashes, offsets[0..count]) |*line, *hash_, *offset_| {
            const end = if (std.mem.indexOfScalarPos(u8, text, offset, '\n')) |eol| eol + 1 else text.len;
            line.* = text[offset..end];
            hash_.* = std.hash.Wyhash.hash(0, line.*);
            offset_.* = base_offset + offset;
            offset = end;
        }
        offsets[count] = base_offset + text.len;
        return .{ .lines = lines, .hashes = hashes, .offsets = offsets };
    }

    fn with_tail(self: Lines, allocator: std.mem.Allocator, text: []const u8, offset: usize, count: usize) error{OutOfMemory}!Lines {
        var end = offset;
        for (0..count) |_| end = if (std.mem.indexOfScalarPos(u8, text, end, '\n')) |eol| eol + 1 else text.len;
        const tail: Lines = try .split(allocator, text[offset..end], offset);
        return .{
            .lines = try std.mem.concat(allocator, []const u8, &.{ self.lines, tail.lines }),
            .hashes = try std.mem.concat(allocator, u64, &.{ self.hashes, tail.hashes }),
            .offsets = try std.mem.concat(allocator, usize, &.{ self.offsets[0..self.lines.len], tail.offsets }),
        };
    }
};

const LineContext = struct {
    src: Lines,
    dst: Lines,

    pub fn eql(self: LineContext, src_index: u32, dst_index: u32) bool {
        return self.src.hashes[src_index] == self.dst.hashes[dst_index] and
            std.mem.eql(u8, self.src.lines[src_index], self.dst.lines[dst_index]);
    }
};

/// a block of changed lines up to this size, both sides together, gets a byte diff
const max_block_refine_bytes = 2 * 1024;

/// a block of changed lines, as line indexes in the two middles
const RawBlock = struct {
    src_line: usize,
    src_end: usize,
    dst_line: usize,
    dst_end: usize,
};

const LineDiff = struct {
    middle: Middle,
    src: Lines,
    dst: Lines,
    blocks: []const RawBlock,

    fn of(arena: std.mem.Allocator, src: []const u8, dst: []const u8) (error{ OutOfMemory, InputTooLarge })!LineDiff {
        const middle: Middle = .of(src, dst);
        const src_lines: Lines = try .split(arena, src[middle.begin..middle.src_end], middle.begin);
        const dst_lines: Lines = try .split(arena, dst[middle.begin..middle.dst_end], middle.begin);
        const total = src_lines.lines.len + dst_lines.lines.len;
        if (total > std.math.maxInt(i32) / 4) return error.InputTooLarge;

        var dizzy_edits: std.ArrayList(dizzy.Edit) = .empty;
        const scratch = try arena.alloc(u32, 4 * total + 2);
        try dizzy.Differ(LineContext).diff(arena, &dizzy_edits, @intCast(src_lines.lines.len), @intCast(dst_lines.lines.len), scratch, .{ .src = src_lines, .dst = dst_lines });

        var blocks: std.ArrayList(RawBlock) = .empty;
        var src_line: usize = 0;
        var dst_line: usize = 0;
        var open = false;
        for (dizzy_edits.items) |dizzy_edit| {
            const len = dizzy_edit.range.end - dizzy_edit.range.start;
            if (dizzy_edit.kind == .equal) {
                open = false;
                src_line += len;
                dst_line += len;
                continue;
            }
            if (!open) (try blocks.addOne(arena)).* = .{ .src_line = src_line, .src_end = src_line, .dst_line = dst_line, .dst_end = dst_line };
            open = true;
            if (dizzy_edit.kind == .delete) src_line += len else dst_line += len;
            const block = &blocks.items[blocks.items.len - 1];
            block.src_end = src_line;
            block.dst_end = dst_line;
        }
        var src_all = src_lines;
        var dst_all = dst_lines;
        if (blocks.items.len > 0) {
            // the last block can slide into the common last lines, which are not part of the middle
            const last = blocks.items[blocks.items.len - 1];
            const tail_lines = try slide_room(arena, last, src_lines, dst_lines, src[middle.src_end..]);
            if (tail_lines > 0) {
                src_all = try src_lines.with_tail(arena, src, middle.src_end, tail_lines);
                dst_all = try dst_lines.with_tail(arena, dst, middle.dst_end, tail_lines);
            }
        }
        slide_blocks(&blocks, src_all, dst_all);
        return .{ .middle = middle, .src = src_all, .dst = dst_all, .blocks = blocks.items };
    }

    /// the number of lines of tail that the block can slide down, if it is at the end of both middles
    fn slide_room(arena: std.mem.Allocator, block: RawBlock, src: Lines, dst: Lines, tail: []const u8) error{OutOfMemory}!usize {
        if (block.src_end != src.lines.len or block.dst_end != dst.lines.len) return 0;
        const inserted = block.src_line == block.src_end;
        const removed = block.dst_line == block.dst_end;
        if (inserted == removed) return 0;
        const block_lines = if (inserted) dst.lines[block.dst_line..block.dst_end] else src.lines[block.src_line..block.src_end];
        var seen: std.ArrayList([]const u8) = .empty;
        var offset: usize = 0;
        while (offset < tail.len) {
            const end = if (std.mem.indexOfScalarPos(u8, tail, offset, '\n')) |eol| eol + 1 else tail.len;
            const line = tail[offset..end];
            const index = seen.items.len;
            const expected = if (index < block_lines.len) block_lines[index] else seen.items[index - block_lines.len];
            if (!std.mem.eql(u8, line, expected)) break;
            try seen.append(arena, line);
            offset = end;
        }
        return seen.items.len;
    }

    /// A block of only new lines or only removed lines can often move down
    /// with the same result, if the line after it equals its first line. Git
    /// moves such a block down as far as it goes, and so does this. A block
    /// that reaches the next block joins it.
    fn slide_blocks(blocks: *std.ArrayList(RawBlock), src: Lines, dst: Lines) void {
        var index: usize = 0;
        while (index < blocks.items.len) {
            const block = &blocks.items[index];
            const has_next = index + 1 < blocks.items.len;
            const src_limit = if (has_next) blocks.items[index + 1].src_line else src.lines.len;
            const dst_limit = if (has_next) blocks.items[index + 1].dst_line else dst.lines.len;
            const inserted = block.src_line == block.src_end;
            const removed = block.dst_line == block.dst_end;
            if (inserted != removed) {
                const side = if (inserted) dst else src;
                while (block.src_end < src_limit and block.dst_end < dst_limit) {
                    const first = if (inserted) block.dst_line else block.src_line;
                    const after = if (inserted) block.dst_end else block.src_end;
                    if (side.hashes[first] != side.hashes[after] or !std.mem.eql(u8, side.lines[first], side.lines[after])) break;
                    block.src_line += 1;
                    block.src_end += 1;
                    block.dst_line += 1;
                    block.dst_end += 1;
                }
            }
            if (has_next and block.src_end == src_limit and block.dst_end == dst_limit) {
                block.src_end = blocks.items[index + 1].src_end;
                block.dst_end = blocks.items[index + 1].dst_end;
                _ = blocks.orderedRemove(index + 1);
                continue;
            }
            index += 1;
        }
    }
};

fn diff_lines(arena: std.mem.Allocator, hunks: *std.ArrayList(Hunk), src: []const u8, dst: []const u8) (error{ OutOfMemory, InputTooLarge })!void {
    const diff: LineDiff = try .of(arena, src, dst);
    for (diff.blocks) |block| try diff_block(arena, hunks, src, dst, .{
        .src_begin = diff.src.offsets[block.src_line],
        .src_end = diff.src.offsets[block.src_end],
        .dst_begin = diff.dst.offsets[block.dst_line],
        .dst_end = diff.dst.offsets[block.dst_end],
    });
}

/// a block of changed lines: src_rows lines from src_row on were replaced by dst_rows lines from dst_row on
pub const LineBlock = struct {
    src_row: usize,
    src_rows: usize,
    dst_row: usize,
    dst_rows: usize,
};

/// The blocks of changed lines between two texts, in the order of the texts.
/// This is the line level of diff_strings, the same kind of result as the
/// hunks of `git diff --unified=0`.
pub fn line_blocks(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) (error{ OutOfMemory, InputTooLarge })![]LineBlock {
    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    const diff: LineDiff = try .of(arena_.allocator(), src, dst);
    const first_row = std.mem.count(u8, src[0..diff.middle.begin], "\n");
    const blocks = try allocator.alloc(LineBlock, diff.blocks.len);
    for (blocks, diff.blocks) |*block, raw| block.* = .{
        .src_row = first_row + raw.src_line,
        .src_rows = raw.src_end - raw.src_line,
        .dst_row = first_row + raw.dst_line,
        .dst_rows = raw.dst_end - raw.dst_line,
    };
    return blocks;
}

pub const LineMark = struct {
    kind: Kind,
    line: usize,
    lines: usize,

    pub const Kind = enum { insert, modify, delete };
};

/// The marks for the lines of the new text. A delete mark has one line, the
/// line that now follows the removed lines.
pub fn line_marks(allocator: std.mem.Allocator, blocks: []const LineBlock) error{OutOfMemory}![]LineMark {
    var marks: std.ArrayList(LineMark) = .empty;
    errdefer marks.deinit(allocator);
    for (blocks) |block| {
        const modified = @min(block.src_rows, block.dst_rows);
        if (modified > 0)
            (try marks.addOne(allocator)).* = .{ .kind = .modify, .line = block.dst_row, .lines = modified };
        if (block.dst_rows > modified)
            (try marks.addOne(allocator)).* = .{ .kind = .insert, .line = block.dst_row + modified, .lines = block.dst_rows - modified };
        if (block.src_rows > modified)
            (try marks.addOne(allocator)).* = .{ .kind = .delete, .line = block.dst_row + modified, .lines = 1 };
    }
    return marks.toOwnedSlice(allocator);
}

fn diff_block(arena: std.mem.Allocator, hunks: *std.ArrayList(Hunk), src: []const u8, dst: []const u8, block: Hunk) error{OutOfMemory}!void {
    const old = src[block.src_begin..block.src_end];
    const new = dst[block.dst_begin..block.dst_end];
    if (old.len == 0 or new.len == 0 or old.len + new.len > max_block_refine_bytes)
        return add_hunk(arena, hunks, src, block);

    const prefix = std.mem.indexOfDiff(u8, old, new) orelse @min(old.len, new.len);
    const max_suffix = @min(old.len, new.len) - prefix;
    var suffix: usize = 0;
    while (suffix < max_suffix and old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    const middle_old = old[prefix .. old.len - suffix];
    const middle_new = new[prefix .. new.len - suffix];

    var dizzy_edits: std.ArrayList(dizzy.Edit) = .empty;
    const scratch = try arena.alloc(u32, 4 * (middle_old.len + middle_new.len) + 2);
    try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, middle_old, middle_new, scratch);

    var src_pos: usize = block.src_begin + prefix;
    var dst_pos: usize = block.dst_begin + prefix;
    for (dizzy_edits.items) |dizzy_edit| {
        const len = dizzy_edit.range.end - dizzy_edit.range.start;
        switch (dizzy_edit.kind) {
            .equal => {
                src_pos += len;
                dst_pos += len;
            },
            .delete => {
                try add_hunk(arena, hunks, src, .{ .src_begin = src_pos, .src_end = src_pos + len, .dst_begin = dst_pos, .dst_end = dst_pos });
                src_pos += len;
            },
            .insert => {
                try add_hunk(arena, hunks, src, .{ .src_begin = src_pos, .src_end = src_pos, .dst_begin = dst_pos, .dst_end = dst_pos + len });
                dst_pos += len;
            },
        }
    }
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

fn applied_copy(allocator: std.mem.Allocator, src: []const u8, edit_set: []const u8) ![]u8 {
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
    const result = try applied_copy(testing.allocator, src, edit_set);
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

test "apply_to_string" {
    const src = "let a = 1;\nlet b = 2;\n\u{e9}t\u{e9}\n";
    const dst = "let a = 10;\nconst c = 2;\n\u{e8}t\u{e9}!\nmore\n";
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, src, dst);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, src);
    try apply_to_string(testing.allocator, &text, .{ .bytes = edit_set.written() });
    try testing.expectEqualStrings(dst, text.items);
    try testing.expectError(error.BaseMismatch, apply_to_string(testing.allocator, &text, .{ .bytes = edit_set.written() }));
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
    try testing.expectEqual(0xef46db3751d8e999, hash(""));
    try testing.expectEqual(std.hash.XxHash64.hash(0, "flow\ncontrol\n"), hash("flow\r\ncontrol\r\n"));
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
        .{ .begin = .{ .row = 1, .pos = 0 }, .end = .{ .row = 2, .pos = 0 }, .text = "" },
    });
    try expect_diff("one\ntwo\n", "one\ntwo\nthree\n", &.{
        .{ .begin = .{ .row = 2, .pos = 0 }, .end = .{ .row = 2, .pos = 0 }, .text = "three\n" },
    });
    try expect_diff("let a = 1;\nlet b = 2;\n", "let a = 10;\nlet c = 2;\n", &.{
        .{ .begin = .{ .row = 0, .pos = 9 }, .end = .{ .row = 0, .pos = 9 }, .text = "0" },
        .{ .begin = .{ .row = 1, .pos = 4 }, .end = .{ .row = 1, .pos = 5 }, .text = "c" },
    });
}

fn expect_line_blocks(src: []const u8, dst: []const u8, expected: []const LineBlock) !void {
    const blocks = try line_blocks(testing.allocator, src, dst);
    defer testing.allocator.free(blocks);
    try testing.expectEqualSlices(LineBlock, expected, blocks);
}

test "line_blocks" {
    try expect_line_blocks("a\nb\nc\n", "a\nb\nc\n", &.{});
    try expect_line_blocks("a\nb\nc\n", "a\nX\nc\n", &.{.{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 }});
    try expect_line_blocks("a\nc\n", "a\nb1\nb2\nc\n", &.{.{ .src_row = 1, .src_rows = 0, .dst_row = 1, .dst_rows = 2 }});
    try expect_line_blocks("a\nb\nc\nd\n", "a\nd\n", &.{.{ .src_row = 1, .src_rows = 2, .dst_row = 1, .dst_rows = 0 }});
    try expect_line_blocks("a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE1\nE2\n", &.{
        .{ .src_row = 0, .src_rows = 1, .dst_row = 0, .dst_rows = 1 },
        .{ .src_row = 4, .src_rows = 1, .dst_row = 4, .dst_rows = 2 },
    });
    try expect_line_blocks("", "a\nb\n", &.{.{ .src_row = 0, .src_rows = 0, .dst_row = 0, .dst_rows = 2 }});
    try expect_line_blocks("a\nb", "a\nb\nc", &.{.{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 2 }});
    try expect_line_blocks("a\nconst b\nc\n", "a\npub const b\nc\n", &.{.{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 }});
    try expect_line_blocks("a\npub const b\nc\n", "a\nconst b\nc\n", &.{.{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 }});
    try expect_line_blocks("const b\nc\n", "pub const b\nc\n", &.{.{ .src_row = 0, .src_rows = 1, .dst_row = 0, .dst_rows = 1 }});
    // a block of new lines slides down as far as it goes, as in git
    try expect_line_blocks("a;\n}\n\nfn c {\nz\n", "a;\n}\n\nconst m;\nb;\n}\n\nfn c {\nz\n", &.{.{ .src_row = 3, .src_rows = 0, .dst_row = 3, .dst_rows = 4 }});
    try expect_line_blocks("h\nX\nm\na;\n}\n\nfn c {\nz\n", "h\nY\nm\na;\n}\n\nconst m;\nb;\n}\n\nfn c {\nz\n", &.{
        .{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 },
        .{ .src_row = 6, .src_rows = 0, .dst_row = 6, .dst_rows = 4 },
    });
    try expect_line_blocks("h\nX\nm\nx\nx\nx\nend\n", "h\nY\nm\nx\nx\nx\nx\nx\nend\n", &.{
        .{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 },
        .{ .src_row = 6, .src_rows = 0, .dst_row = 6, .dst_rows = 2 },
    });
    try expect_line_blocks("h\nX\na\n}\n\nb\n}\n\nc\n", "h\nY\na\n}\n\nc\n", &.{
        .{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 },
        .{ .src_row = 5, .src_rows = 3, .dst_row = 5, .dst_rows = 0 },
    });
}

test "line_marks" {
    const marks = try line_marks(testing.allocator, &.{
        .{ .src_row = 1, .src_rows = 1, .dst_row = 1, .dst_rows = 1 },
        .{ .src_row = 4, .src_rows = 0, .dst_row = 4, .dst_rows = 3 },
        .{ .src_row = 9, .src_rows = 2, .dst_row = 12, .dst_rows = 0 },
        .{ .src_row = 20, .src_rows = 1, .dst_row = 21, .dst_rows = 3 },
        .{ .src_row = 30, .src_rows = 3, .dst_row = 33, .dst_rows = 1 },
    });
    defer testing.allocator.free(marks);
    try testing.expectEqualSlices(LineMark, &.{
        .{ .kind = .modify, .line = 1, .lines = 1 },
        .{ .kind = .insert, .line = 4, .lines = 3 },
        .{ .kind = .delete, .line = 12, .lines = 1 },
        .{ .kind = .modify, .line = 21, .lines = 1 },
        .{ .kind = .insert, .line = 22, .lines = 2 },
        .{ .kind = .modify, .line = 33, .lines = 1 },
        .{ .kind = .delete, .line = 34, .lines = 1 },
    }, marks);
}

test "estimate" {
    const same = try estimate(testing.allocator, "a\nb\nc\n", "a\nb\nc\n");
    try testing.expectEqual(0, same.middle_lines);
    const one = try estimate(testing.allocator, "a\nb\nc\nd\ne\n", "a\nX\nc\nd\ne\n");
    try testing.expectEqual(2, one.middle_lines);
    try testing.expectEqual(2, one.changed_lines);
    const far = try estimate(testing.allocator, "a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE\n");
    try testing.expectEqual(10, far.middle_lines);
    try testing.expectEqual(4, far.changed_lines);
    try testing.expectEqual(40, far.cost());
    const moved = try estimate(testing.allocator, "a\nb\nc\n", "c\na\nb\n");
    try testing.expectEqual(6, moved.middle_lines);
    try testing.expectEqual(0, moved.changed_lines);
    const repeated = try estimate(testing.allocator, "x\nx\ny\n", "x\ny\ny\nq\n");
    try testing.expectEqual(3, repeated.changed_lines);
}

test "middle_lines" {
    try testing.expectEqual(0, middle_lines("same\ntext\n", "same\ntext\n"));
    try testing.expectEqual(2, middle_lines("a\nb\nc\n", "a\nX\nc\n"));
    try testing.expectEqual(1, middle_lines("a\nc\n", "a\nb\nc\n"));
    try testing.expectEqual(3, middle_lines("a\nb\nc", ""));
    try testing.expectEqual(2, middle_lines("a\nb\nc", "a\nb\ncd"));
    try testing.expectEqual(2, middle_lines("xa\nb\n", "ya\nb\n"));
    try testing.expectEqual(6, middle_lines("a\nb\nc\n", "x\ny\nz\n"));
}

test "diff_strings: a large block of changed lines is one edit" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var dst: std.ArrayList(u8) = .empty;
    defer dst.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "first\n");
    try dst.appendSlice(testing.allocator, "first\n");
    for (0..200) |i| {
        try src.print(testing.allocator, "old line number {d}\n", .{i});
        try dst.print(testing.allocator, "a completely new line {d}\n", .{i * 7});
    }
    try src.appendSlice(testing.allocator, "last\n");
    try dst.appendSlice(testing.allocator, "last\n");
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, src.items, dst.items);
    const edits = try collect(testing.allocator, .{ .bytes = edit_set.written() });
    defer testing.allocator.free(edits);
    try testing.expectEqual(1, edits.len);
    try testing.expectEqual(Position{ .row = 1, .pos = 0 }, edits[0].begin);
    try testing.expectEqual(200, edits[0].end.row);
    try expect_round_trip(src.items, dst.items, edit_set.written());
}

test "diff_strings: moved and repeated lines" {
    try expect_diff("a\nb\nc\nd\n", "c\nd\na\nb\n", &.{
        .{ .begin = .{ .row = 0, .pos = 0 }, .end = .{ .row = 0, .pos = 0 }, .text = "c\nd\n" },
        .{ .begin = .{ .row = 2, .pos = 0 }, .end = .{ .row = 4, .pos = 0 }, .text = "" },
    });
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, "x\nx\nx\n", "x\nx\nx\nx\nx\n");
    try expect_round_trip("x\nx\nx\n", "x\nx\nx\nx\nx\n", edit_set.written());
    edit_set.clearRetainingCapacity();
    try diff_strings(testing.allocator, &edit_set, "no eol", "no eol\n");
    try expect_round_trip("no eol", "no eol\n", edit_set.written());
    edit_set.clearRetainingCapacity();
    try diff_strings(testing.allocator, &edit_set, "a\nno eol", "b\nno eol");
    try expect_round_trip("a\nno eol", "b\nno eol", edit_set.written());
}

test "diff_strings: a change in the middle of a long text" {
    var part: std.ArrayList(u8) = .empty;
    defer part.deinit(testing.allocator);
    for (0..2000) |_| try part.appendSlice(testing.allocator, "0123456789abcdef\n");
    const src = try std.mem.concat(testing.allocator, u8, &.{ part.items, "old line\n", part.items });
    defer testing.allocator.free(src);
    const dst = try std.mem.concat(testing.allocator, u8, &.{ part.items, "new line\n", part.items });
    defer testing.allocator.free(dst);
    try expect_diff(src, dst, &.{
        .{ .begin = .{ .row = 2000, .pos = 0 }, .end = .{ .row = 2000, .pos = 3 }, .text = "new" },
    });
    const added = try std.mem.concat(testing.allocator, u8, &.{ part.items, "added\n", part.items });
    defer testing.allocator.free(added);
    const both = try std.mem.concat(testing.allocator, u8, &.{ part.items, part.items });
    defer testing.allocator.free(both);
    try testing.expectEqual(1, middle_lines(both, added));
    var edit_set: std.Io.Writer.Allocating = .init(testing.allocator);
    defer edit_set.deinit();
    try diff_strings(testing.allocator, &edit_set, both, added);
    try expect_round_trip(both, added, edit_set.written());
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
