text: []const u8,
tabstops: [][]Range,

const Snippet = @This();
const Range = struct { begin: Position, end: ?Position = null };
const Position = struct { usize };

const Tabstop = struct {
    id: usize,
    range: Range,
};

pub fn deinit(self: *const Snippet, allocator: std.mem.Allocator) void {
    for (self.tabstops) |tabstop| allocator.free(tabstop);
    allocator.free(self.tabstops);
    allocator.free(self.text);
}

pub fn parse(allocator: std.mem.Allocator, snippet: []const u8) Error!Snippet {
    var tabstops: std.ArrayList(Tabstop) = .empty;
    defer tabstops.deinit(allocator);
    var id: ?usize = null;
    var content_begin: std.ArrayList(Position) = .empty;
    defer content_begin.deinit(allocator);
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
                '{' => if (id == null) {
                    state = .placeholder;
                } else {
                    try register_tabstop(allocator, &tabstops, &id, .{ .begin = .{text.written().len} });
                    state = state_stack.pop() orelse return error.InvalidState;
                    continue :fsm .initial;
                },
                '0'...'9' => append_id_digit(&id, c) catch {
                    const pos = snippet.len - iter.len;
                    return invalid(snippet, pos, error.InvalidIdValue);
                },
                else => {
                    const pos = snippet.len - iter.len;
                    if (id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    try register_tabstop(allocator, &tabstops, &id, .{ .begin = .{text.written().len} });
                    state = state_stack.pop() orelse return error.InvalidState;
                    continue :fsm .initial;
                },
            },
            .placeholder => switch (c) {
                '0'...'9' => append_id_digit(&id, c) catch {
                    const pos = snippet.len - iter.len;
                    return invalid(snippet, pos, error.InvalidIdValue);
                },
                '}' => {
                    const pos = snippet.len - iter.len;
                    if (id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    try register_tabstop(allocator, &tabstops, &id, .{ .begin = .{text.written().len} });
                    state = state_stack.pop() orelse return error.InvalidState;
                },
                ':' => {
                    const pos = snippet.len - iter.len;
                    if (id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    (try content_begin.addOne(allocator)).* = .{text.written().len};
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
                '}' => {
                    const pos = snippet.len - iter.len;
                    if (id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    if (content_begin.items.len == 0)
                        return invalid(snippet, pos, error.InvalidPlaceholderValue);
                    const begin_pos = content_begin.pop() orelse return invalid(snippet, pos, error.InvalidPlaceholderValue);
                    try register_tabstop(allocator, &tabstops, &id, .{
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
        if (state != .tabstop or id == null)
            return invalid(snippet, pos, error.UnexpectedEndOfDocument);
        try register_tabstop(allocator, &tabstops, &id, .{ .begin = .{text.written().len} });
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

fn register_tabstop(
    allocator: std.mem.Allocator,
    tabstops: *std.ArrayList(Tabstop),
    id: *?usize,
    range: Range,
) error{OutOfMemory}!void {
    (try tabstops.addOne(allocator)).* = .{
        .id = id.* orelse unreachable,
        .range = range,
    };
    id.* = null;
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
