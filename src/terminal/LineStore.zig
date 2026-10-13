const std = @import("std");
const cbor = @import("cbor");
const DoubleMappedRingBuffer = @import("DoubleMappedRingBuffer");

const LineStore = @This();

pub const block_lines = 64;

allocator: std.mem.Allocator,
ring: DoubleMappedRingBuffer,
// positions grow only
tail: u64 = 0,
head: u64 = 0,
first_line: u64 = 0,
lines: usize = 0,
cols: u16,
blocks: std.ArrayList(Block) = .empty,
scratch: std.Io.Writer.Allocating,

const Block = struct {
    pos: u64,
    rows: u32,
    state: packed struct(u32) {
        rows: enum(u1) { valid, invalid } = .valid,
        marks: enum(u1) { none, some } = .none,
        _: u30 = 0,
    } = .{},
};

/// [display_width, text, marks]
pub const Line = struct {
    display_width: u32,
    text: []const u8,
    marks: cbor.Raw,

    pub fn rows(self: Line, cols: u16) u32 {
        return rows_for(self.display_width, cols);
    }

    pub fn has_marks(self: Line) bool {
        var iter = self.marks.bytes;
        return (cbor.decodeArrayHeader(&iter) catch 0) > 0;
    }
};

pub const Position = struct {
    line: u64,
    row: u32,
};

pub const Error = error{ OutOfMemory, LineTooLarge, InvalidLineStore };

pub fn init(allocator: std.mem.Allocator, byte_budget: usize, cols: u16) !LineStore {
    const page = std.heap.pageSize();
    return .{
        .allocator = allocator,
        .ring = try .init(@max(1, (byte_budget + page - 1) / page) * page),
        .cols = cols,
        .scratch = .init(allocator),
    };
}

pub fn deinit(self: *LineStore) void {
    self.scratch.deinit();
    self.blocks.deinit(self.allocator);
    self.ring.deinit();
}

pub fn rows_for(display_width: u32, cols: u16) u32 {
    return if (cols == 0) 1 else @max(1, (display_width + cols - 1) / cols);
}

pub fn end_line(self: *const LineStore) u64 {
    return self.first_line + self.lines;
}

pub fn used_bytes(self: *const LineStore) usize {
    return @intCast(self.head - self.tail);
}

pub fn append(self: *LineStore, display_width: u32, text: []const u8, marks: cbor.Raw) Error!void {
    self.scratch.clearRetainingCapacity();
    const writer = &self.scratch.writer;
    cbor.writeArrayHeader(writer, 3) catch return error.OutOfMemory;
    cbor.writeValue(writer, display_width) catch return error.OutOfMemory;
    cbor.writeValue(writer, text) catch return error.OutOfMemory;
    writer.writeAll(marks.bytes) catch return error.OutOfMemory;
    const record = self.scratch.written();
    if (record.len > self.ring.len()) return error.LineTooLarge;

    const line: Line = .{ .display_width = display_width, .text = text, .marks = marks };
    const line_no = self.end_line();
    if (self.blocks.items.len == 0 or line_no % block_lines == 0)
        try self.blocks.ensureUnusedCapacity(self.allocator, 1);

    while (self.ring.len() - self.used_bytes() < record.len) try self.drop_oldest();

    if (self.blocks.items.len == 0 or line_no % block_lines == 0)
        self.blocks.appendAssumeCapacity(.{ .pos = self.head, .rows = 0 });
    const block = &self.blocks.items[self.blocks.items.len - 1];
    block.rows += line.rows(self.cols);
    if (line.has_marks()) block.state.marks = .some;

    @memcpy(self.ring.slice(@intCast(self.head % self.ring.len()), record.len), record);
    self.head += record.len;
    self.lines += 1;
}

fn drop_oldest(self: *LineStore) error{InvalidLineStore}!void {
    var iter = self.stream_from(self.tail);
    const size = iter.len;
    const line = try next_line(&iter) orelse return error.InvalidLineStore;
    self.tail += size - iter.len;
    self.first_line += 1;
    self.lines -= 1;
    if (self.lines == 0 or self.first_line % block_lines == 0) {
        _ = self.blocks.orderedRemove(0);
        return;
    }
    const block = &self.blocks.items[0];
    block.pos = self.tail;
    if (block.state.rows == .valid) block.rows -= line.rows(self.cols);
}

fn stream_from(self: *const LineStore, pos: u64) []const u8 {
    return self.ring.slice(@intCast(pos % self.ring.len()), @intCast(self.head - pos));
}

fn next_line(iter: *[]const u8) error{InvalidLineStore}!?Line {
    if (iter.len == 0) return null;
    var line: Line = undefined;
    var marks: []const u8 = undefined;
    if (!(cbor.matchValue(iter, .{
        cbor.extract(&line.display_width),
        cbor.extract(&line.text),
        cbor.extract_cbor(&marks),
    }) catch return error.InvalidLineStore)) return error.InvalidLineStore;
    line.marks = .{ .bytes = marks };
    return line;
}

fn block_index(self: *const LineStore, line_no: u64) usize {
    return @intCast(line_no / block_lines - self.first_line / block_lines);
}

fn block_first_line(self: *const LineStore, index: usize) u64 {
    return @max(self.first_line, (self.first_line / block_lines + index) * block_lines);
}

fn block_end_line(self: *const LineStore, index: usize) u64 {
    return @min(self.end_line(), (self.first_line / block_lines + index + 1) * block_lines);
}

pub const Iterator = struct {
    stream: []const u8,
    line_no: u64,

    pub fn next(self: *Iterator) error{InvalidLineStore}!?Line {
        const line = try next_line(&self.stream) orelse return null;
        self.line_no += 1;
        return line;
    }
};

pub fn iterate(self: *const LineStore, line_no: u64) error{InvalidLineStore}!Iterator {
    if (line_no < self.first_line or line_no >= self.end_line())
        return .{ .stream = &.{}, .line_no = self.end_line() };
    const index = self.block_index(line_no);
    var iter: Iterator = .{
        .stream = self.stream_from(self.blocks.items[index].pos),
        .line_no = self.block_first_line(index),
    };
    while (iter.line_no < line_no) _ = try iter.next();
    return iter;
}

pub fn get(self: *const LineStore, line_no: u64) error{InvalidLineStore}!?Line {
    var iter = try self.iterate(line_no);
    return iter.next();
}

pub fn set_cols(self: *LineStore, cols: u16) void {
    if (cols == self.cols) return;
    self.cols = cols;
    for (self.blocks.items) |*block| block.state.rows = .invalid;
}

fn block_rows(self: *LineStore, index: usize) error{InvalidLineStore}!u32 {
    const block = &self.blocks.items[index];
    if (block.state.rows == .valid) return block.rows;
    var iter: Iterator = .{ .stream = self.stream_from(block.pos), .line_no = self.block_first_line(index) };
    const end = self.block_end_line(index);
    var rows: u32 = 0;
    while (iter.line_no < end) rows += (try iter.next() orelse return error.InvalidLineStore).rows(self.cols);
    block.rows = rows;
    block.state.rows = .valid;
    return rows;
}

pub fn total_rows(self: *LineStore) error{InvalidLineStore}!usize {
    var rows: usize = 0;
    for (0..self.blocks.items.len) |index| rows += try self.block_rows(index);
    return rows;
}

/// find the line that holds `row`, row 0 is the first row of the oldest line
pub fn locate_row(self: *LineStore, row: usize) error{InvalidLineStore}!?Position {
    var first_row: usize = 0;
    for (0..self.blocks.items.len) |index| {
        const rows = try self.block_rows(index);
        if (row >= first_row + rows) {
            first_row += rows;
            continue;
        }
        var iter: Iterator = .{ .stream = self.stream_from(self.blocks.items[index].pos), .line_no = self.block_first_line(index) };
        while (try iter.next()) |line| {
            const line_rows = line.rows(self.cols);
            if (row < first_row + line_rows)
                return .{ .line = iter.line_no - 1, .row = @intCast(row - first_row) };
            first_row += line_rows;
        }
        return error.InvalidLineStore;
    }
    return null;
}

/// the first row of `line_no`
pub fn row_of(self: *LineStore, line_no: u64) error{InvalidLineStore}!?usize {
    if (line_no < self.first_line or line_no >= self.end_line()) return null;
    const index = self.block_index(line_no);
    var row: usize = 0;
    for (0..index) |i| row += try self.block_rows(i);
    var iter: Iterator = .{ .stream = self.stream_from(self.blocks.items[index].pos), .line_no = self.block_first_line(index) };
    while (iter.line_no < line_no) row += (try iter.next() orelse return error.InvalidLineStore).rows(self.cols);
    return row;
}

pub const Direction = enum { older, newer };

/// find the nearest line with marks, starting at `line_no`
pub fn find_marked(self: *const LineStore, line_no: u64, direction: Direction) error{InvalidLineStore}!?u64 {
    if (self.lines == 0) return null;
    var index = self.block_index(std.math.clamp(line_no, self.first_line, self.end_line() - 1));
    while (true) {
        if (self.blocks.items[index].state.marks == .some) {
            var iter: Iterator = .{ .stream = self.stream_from(self.blocks.items[index].pos), .line_no = self.block_first_line(index) };
            const end = self.block_end_line(index);
            var found: ?u64 = null;
            while (iter.line_no < end) {
                const line = try iter.next() orelse return error.InvalidLineStore;
                const no = iter.line_no - 1;
                if (!line.has_marks()) continue;
                switch (direction) {
                    .older => if (no <= line_no) {
                        found = no;
                    },
                    .newer => if (no >= line_no) return no,
                }
            }
            if (found) |no| return no;
        }
        switch (direction) {
            .older => if (index == 0) return null else {
                index -= 1;
            },
            .newer => if (index + 1 == self.blocks.items.len) return null else {
                index += 1;
            },
        }
    }
}

const testing = std.testing;
const no_marks: cbor.Raw = .{ .bytes = &.{0x80} };

fn test_marks(buf: []u8) cbor.Raw {
    var writer: std.Io.Writer = .fixed(buf);
    cbor.writeValue(&writer, .{.{ 0, "prompt_start", null }}) catch unreachable;
    return .{ .bytes = writer.buffered() };
}

fn test_text(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "line {d} \x1b[0;1mbold\x1b[0m", .{n}) catch unreachable;
}

test "append and get" {
    var store = try LineStore.init(testing.allocator, 1, 80);
    defer store.deinit();
    var marks_buf: [32]u8 = undefined;
    try store.append(5, "hello", no_marks);
    try store.append(200, "long", test_marks(&marks_buf));

    try testing.expectEqual(2, store.lines);
    const first = (try store.get(0)).?;
    try testing.expectEqual(5, first.display_width);
    try testing.expectEqualStrings("hello", first.text);
    try testing.expect(!first.has_marks());
    try testing.expectEqual(1, first.rows(80));
    const second = (try store.get(1)).?;
    try testing.expectEqualStrings("long", second.text);
    try testing.expect(second.has_marks());
    try testing.expectEqual(3, second.rows(80));
    try testing.expectEqual(null, try store.get(2));
}

test "the oldest lines are dropped at the byte budget" {
    var store = try LineStore.init(testing.allocator, 1, 80);
    defer store.deinit();
    const total = 5000;
    var buf: [64]u8 = undefined;
    for (0..total) |n| try store.append(10, test_text(&buf, n), no_marks);

    try testing.expectEqual(total, store.end_line());
    try testing.expect(store.first_line > 0);
    try testing.expect(store.used_bytes() <= store.ring.len());
    try testing.expectEqual(null, try store.get(store.first_line - 1));

    var iter = try store.iterate(store.first_line);
    var n = store.first_line;
    while (try iter.next()) |line| : (n += 1)
        try testing.expectEqualStrings(test_text(&buf, @intCast(n)), line.text);
    try testing.expectEqual(total, n);
    try testing.expectEqual((store.lines + store.first_line % block_lines + block_lines - 1) / block_lines, store.blocks.items.len);

    for ([_]u64{ store.first_line, store.first_line + 63, store.first_line + 64, total - 1 }) |no|
        try testing.expectEqualStrings(test_text(&buf, @intCast(no)), (try store.get(no)).?.text);
}

test "a line that is larger than the ring is refused" {
    var store = try LineStore.init(testing.allocator, 1, 80);
    defer store.deinit();
    const text = try testing.allocator.alloc(u8, store.ring.len());
    defer testing.allocator.free(text);
    @memset(text, 'x');
    try testing.expectError(error.LineTooLarge, store.append(1, text, no_marks));
    try store.append(1, text[0 .. text.len - 8], no_marks);
    try store.append(1, "next", no_marks);
    try testing.expectEqual(1, store.lines);
    try testing.expectEqualStrings("next", (try store.get(1)).?.text);
}

test "rows follow the width" {
    var store = try LineStore.init(testing.allocator, 1 << 16, 80);
    defer store.deinit();
    var expected_80: usize = 0;
    var expected_33: usize = 0;
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..1000) |_| {
        const width = prng.random().uintLessThan(u32, 300);
        try store.append(width, "x", no_marks);
        expected_80 += rows_for(width, 80);
        expected_33 += rows_for(width, 33);
    }
    try testing.expectEqual(expected_80, try store.total_rows());
    store.set_cols(33);
    try testing.expectEqual(expected_33, try store.total_rows());

    var row: usize = 0;
    var iter = try store.iterate(0);
    while (try iter.next()) |line| {
        const line_no = iter.line_no - 1;
        try testing.expectEqual(row, (try store.row_of(line_no)).?);
        const rows = line.rows(33);
        try testing.expectEqual(Position{ .line = line_no, .row = 0 }, (try store.locate_row(row)).?);
        try testing.expectEqual(Position{ .line = line_no, .row = rows - 1 }, (try store.locate_row(row + rows - 1)).?);
        row += rows;
    }
    try testing.expectEqual(null, try store.locate_row(row));
}

test "row sums stay correct while lines are dropped" {
    var store = try LineStore.init(testing.allocator, 1, 40);
    defer store.deinit();
    var buf: [64]u8 = undefined;
    for (0..3000) |n| {
        try store.append(@intCast(n % 130), test_text(&buf, n), no_marks);
        if (n % 97 != 0) continue;
        var expected: usize = 0;
        var iter = try store.iterate(store.first_line);
        while (try iter.next()) |line| expected += line.rows(40);
        try testing.expectEqual(expected, try store.total_rows());
    }
}

test "find marked lines" {
    var store = try LineStore.init(testing.allocator, 1 << 16, 80);
    defer store.deinit();
    var marks_buf: [32]u8 = undefined;
    for (0..500) |n|
        try store.append(1, "x", if (n == 10 or n == 300) test_marks(&marks_buf) else no_marks);

    try testing.expectEqual(10, try store.find_marked(0, .newer));
    try testing.expectEqual(10, try store.find_marked(10, .newer));
    try testing.expectEqual(300, try store.find_marked(11, .newer));
    try testing.expectEqual(null, try store.find_marked(301, .newer));
    try testing.expectEqual(300, try store.find_marked(499, .older));
    try testing.expectEqual(10, try store.find_marked(299, .older));
    try testing.expectEqual(null, try store.find_marked(9, .older));
}
