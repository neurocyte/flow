text: []const u8,
tabstops: [][]Range,

const Snippet = @This();
const Range = struct { begin: Position, end: ?Position = null };
const Position = struct { usize };

const Tabstop = struct {
    id: usize,
    range: Range,
};

const Frame = struct {
    id: ?usize = null,
    content_begin: ?Position = null,
};

pub fn deinit(self: *const Snippet, allocator: std.mem.Allocator) void {
    for (self.tabstops) |tabstop| allocator.free(tabstop);
    allocator.free(self.tabstops);
    allocator.free(self.text);
}

pub fn parse(allocator: std.mem.Allocator, snippet: []const u8) Error!Snippet {
    var tabstops: std.ArrayList(Tabstop) = .empty;
    defer tabstops.deinit(allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();

    var state: enum {
        initial,
        escape,
        tabstop,
        placeholder,
        content,
    } = .initial;

    var state_stack: std.ArrayList(@TypeOf(state)) = .empty;
    defer state_stack.deinit(allocator);

    var iter = snippet;
    while (iter.len > 0) : (iter = iter[1..]) {
        const c = iter[0];
        fsm: switch (state) {
            .initial => switch (c) {
                '\\' => {
                    (try state_stack.addOne(allocator)).* = state;
                    state = .escape;
                },
                '$' => {
                    (try state_stack.addOne(allocator)).* = state;
                    (try frames.addOne(allocator)).* = .{};
                    state = .tabstop;
                },
                else => try text.writer.writeByte(c),
            },
            .escape => {
                try text.writer.writeByte(c);
                state = state_stack.pop() orelse return error.InvalidState;
            },
            .tabstop => switch (c) {
                // a brace only opens a placeholder directly after the '$'
                '{' => if ((try top(&frames)).id == null) {
                    state = .placeholder;
                } else {
                    try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} });
                    state = state_stack.pop() orelse return error.InvalidState;
                    continue :fsm state;
                },
                '0'...'9' => {
                    const frame = try top(&frames);
                    append_id_digit(&frame.id, c) catch {
                        const pos = snippet.len - iter.len;
                        return invalid(snippet, pos, error.InvalidIdValue);
                    };
                },
                else => {
                    const pos = snippet.len - iter.len;
                    if ((try top(&frames)).id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} });
                    state = state_stack.pop() orelse return error.InvalidState;
                    continue :fsm state;
                },
            },
            .placeholder => switch (c) {
                '0'...'9' => {
                    const frame = try top(&frames);
                    append_id_digit(&frame.id, c) catch {
                        const pos = snippet.len - iter.len;
                        return invalid(snippet, pos, error.InvalidIdValue);
                    };
                },
                '}' => {
                    const pos = snippet.len - iter.len;
                    if ((try top(&frames)).id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} });
                    state = state_stack.pop() orelse return error.InvalidState;
                },
                ':' => {
                    const pos = snippet.len - iter.len;
                    const frame = try top(&frames);
                    if (frame.id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    frame.content_begin = .{text.written().len};
                    state = .content;
                },
                else => {
                    const pos = snippet.len - iter.len;
                    return invalid(snippet, pos, error.InvalidIdValue);
                },
            },
            .content => switch (c) {
                '\\' => {
                    (try state_stack.addOne(allocator)).* = state;
                    state = .escape;
                },
                '$' => {
                    (try state_stack.addOne(allocator)).* = state;
                    (try frames.addOne(allocator)).* = .{};
                    state = .tabstop;
                },
                '}' => {
                    const pos = snippet.len - iter.len;
                    const frame = try top(&frames);
                    if (frame.id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    const begin_pos = frame.content_begin orelse
                        return invalid(snippet, pos, error.InvalidPlaceholderValue);
                    try close_tabstop(allocator, &tabstops, &frames, .{
                        .begin = begin_pos,
                        .end = .{text.written().len},
                    });
                    state = state_stack.pop() orelse return error.InvalidState;
                },
                else => try text.writer.writeByte(c),
            },
        }
    }

    if (state != .initial) {
        const pos = snippet.len - iter.len;
        // a trailing bare tabstop is complete, but only if nothing encloses it
        if (state != .tabstop or frames.items.len != 1 or frames.items[0].id == null)
            return invalid(snippet, pos, error.UnexpectedEndOfDocument);
        try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} });
    }

    var ids: std.ArrayList(usize) = .empty;
    defer ids.deinit(allocator);
    for (tabstops.items) |item| {
        for (ids.items) |seen| {
            if (seen == item.id) break;
        } else (try ids.addOne(allocator)).* = item.id;
    }
    std.mem.sort(usize, ids.items, {}, id_before);

    var result: std.ArrayList([]Range) = .empty;
    defer result.deinit(allocator);
    errdefer for (result.items) |ranges| allocator.free(ranges);
    for (ids.items) |tabstop_id|
        if (try collect_ranges(allocator, tabstops.items, tabstop_id)) |ranges| {
            errdefer allocator.free(ranges);
            (try result.addOne(allocator)).* = ranges;
        };
    const owned_text = try text.toOwnedSlice();
    errdefer allocator.free(owned_text);
    return .{
        .text = owned_text,
        .tabstops = try result.toOwnedSlice(allocator),
    };
}

fn append_id_digit(id: *?usize, c: u8) error{Overflow}!void {
    const digit: usize = @intCast(c - '0');
    id.* = if (id.*) |id_|
        try std.math.add(usize, try std.math.mul(usize, id_, 10), digit)
    else
        digit;
}

fn top(frames: *std.ArrayList(Frame)) error{InvalidState}!*Frame {
    if (frames.items.len == 0) return error.InvalidState;
    return &frames.items[frames.items.len - 1];
}

fn close_tabstop(
    allocator: std.mem.Allocator,
    tabstops: *std.ArrayList(Tabstop),
    frames: *std.ArrayList(Frame),
    range: Range,
) error{ OutOfMemory, InvalidState }!void {
    const frame = frames.pop() orelse return error.InvalidState;
    (try tabstops.addOne(allocator)).* = .{
        .id = frame.id orelse return error.InvalidState,
        .range = range,
    };
}

// tabstop 0 is the final cursor position and always comes last
fn id_before(_: void, lhs: usize, rhs: usize) bool {
    if (lhs == 0) return false;
    if (rhs == 0) return true;
    return lhs < rhs;
}

fn collect_ranges(allocator: std.mem.Allocator, tabstops: []const Tabstop, id: usize) error{OutOfMemory}!?[]Range {
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(allocator);
    for (tabstops) |item| if (item.id == id) {
        (try ranges.addOne(allocator)).* = item.range;
    };
    return if (ranges.items.len > 0) try ranges.toOwnedSlice(allocator) else null;
}

fn invalid(snippet: []const u8, pos: usize, e: Error) Error {
    if (!builtin.is_test) {
        log.err("invalid snippet: {s}", .{snippet});
        log.err("{t} at pos {d}", .{ e, pos });
    }
    return e;
}

pub const Error = error{
    WriteFailed,
    OutOfMemory,
    InvalidIdValue,
    InvalidPlaceholderValue,
    UnexpectedEndOfDocument,
    InvalidState,
};

const log = std.log.scoped(.snippet);
const std = @import("std");
const builtin = @import("builtin");
