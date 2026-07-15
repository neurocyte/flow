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
    name_begin: ?usize = null,
    content_begin: ?Position = null,
    discards: bool = false,
};

pub const Resolver = *const fn (allocator: std.mem.Allocator, name: []const u8) VariableError!?[]const u8;
pub const VariableError = error{ OutOfMemory, WriteFailed };

pub fn deinit(self: *const Snippet, allocator: std.mem.Allocator) void {
    for (self.tabstops) |tabstop| allocator.free(tabstop);
    allocator.free(self.tabstops);
    allocator.free(self.text);
}

pub fn parse(allocator: std.mem.Allocator, snippet: []const u8, resolver: ?Resolver) Error!Snippet {
    var tabstops: std.ArrayList(Tabstop) = .empty;
    defer tabstops.deinit(allocator);
    var unknown: std.ArrayList(Range) = .empty;
    defer unknown.deinit(allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var discard: usize = 0;

    var state: enum {
        initial,
        escape,
        tabstop,
        placeholder,
        content,
        variable,
        braced_variable,
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
                else => if (discard == 0) try text.writer.writeByte(c),
            },
            .escape => {
                if (discard == 0) try text.writer.writeByte(c);
                state = state_stack.pop() orelse return error.InvalidState;
            },
            .tabstop => switch (c) {
                // a brace only opens a placeholder directly after the '$'
                '{' => if ((try top(&frames)).id == null) {
                    state = .placeholder;
                } else {
                    try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} }, discard > 0);
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
                'a'...'z', 'A'...'Z', '_' => {
                    const frame = try top(&frames);
                    // a name only starts directly after the '$', $1a is a tabstop followed by text
                    if (frame.id != null) {
                        try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} }, discard > 0);
                        state = state_stack.pop() orelse return error.InvalidState;
                        continue :fsm state;
                    }
                    frame.name_begin = snippet.len - iter.len;
                    state = .variable;
                },
                else => {
                    const pos = snippet.len - iter.len;
                    if ((try top(&frames)).id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} }, discard > 0);
                    state = state_stack.pop() orelse return error.InvalidState;
                    continue :fsm state;
                },
            },
            .variable => switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                else => {
                    const pos = snippet.len - iter.len;
                    try close_variable(allocator, &frames, &unknown, &text, snippet, pos, resolver, discard > 0);
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
                'a'...'z', 'A'...'Z', '_' => {
                    const pos = snippet.len - iter.len;
                    const frame = try top(&frames);
                    if (frame.id != null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    frame.name_begin = pos;
                    state = .braced_variable;
                },
                '}' => {
                    const pos = snippet.len - iter.len;
                    if ((try top(&frames)).id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} }, discard > 0);
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
            .braced_variable => switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                '}' => {
                    const pos = snippet.len - iter.len;
                    try close_variable(allocator, &frames, &unknown, &text, snippet, pos, resolver, discard > 0);
                    state = state_stack.pop() orelse return error.InvalidState;
                },
                ':' => {
                    const pos = snippet.len - iter.len;
                    const frame = try top(&frames);
                    const name_begin = frame.name_begin orelse return error.InvalidState;
                    // a variable that has a value skips its default entirely
                    if (try resolve(allocator, resolver, snippet[name_begin..pos])) |value| {
                        defer allocator.free(value);
                        if (value.len > 0) {
                            if (discard == 0) try text.writer.writeAll(value);
                            frame.discards = true;
                            discard += 1;
                        }
                    }
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
                    const begin_pos = frame.content_begin orelse
                        return invalid(snippet, pos, error.InvalidPlaceholderValue);
                    if (frame.id) |_| {
                        try close_tabstop(allocator, &tabstops, &frames, .{
                            .begin = begin_pos,
                            .end = .{text.written().len},
                        }, discard > 0);
                    } else {
                        // a variable default carries no tabstop of its own
                        const closed = frames.pop() orelse return error.InvalidState;
                        if (closed.discards) discard -= 1;
                    }
                    state = state_stack.pop() orelse return error.InvalidState;
                },
                else => if (discard == 0) try text.writer.writeByte(c),
            },
        }
    }

    if (state != .initial) {
        const pos = snippet.len - iter.len;
        // a trailing bare tabstop or variable is complete, but only if nothing encloses it
        if (frames.items.len != 1)
            return invalid(snippet, pos, error.UnexpectedEndOfDocument);
        switch (state) {
            .tabstop => {
                if (frames.items[0].id == null)
                    return invalid(snippet, pos, error.UnexpectedEndOfDocument);
                try close_tabstop(allocator, &tabstops, &frames, .{ .begin = .{text.written().len} }, discard > 0);
            },
            .variable => try close_variable(allocator, &frames, &unknown, &text, snippet, pos, resolver, discard > 0),
            else => return invalid(snippet, pos, error.UnexpectedEndOfDocument),
        }
    }

    // an unknown variable is a placeholder over its own name
    if (unknown.items.len > 0) {
        var next_id: usize = 0;
        for (tabstops.items) |item| next_id = @max(next_id, item.id);
        for (unknown.items) |range| {
            next_id = std.math.add(usize, next_id, 1) catch
                return invalid(snippet, snippet.len, error.InvalidIdValue);
            (try tabstops.addOne(allocator)).* = .{ .id = next_id, .range = range };
        }
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
    discard: bool,
) error{ OutOfMemory, InvalidState }!void {
    const frame = frames.pop() orelse return error.InvalidState;
    if (discard) return;
    (try tabstops.addOne(allocator)).* = .{
        .id = frame.id orelse return error.InvalidState,
        .range = range,
    };
}

fn resolve(allocator: std.mem.Allocator, resolver: ?Resolver, name: []const u8) VariableError!?[]const u8 {
    return if (resolver) |resolve_| try resolve_(allocator, name) else null;
}

fn close_variable(
    allocator: std.mem.Allocator,
    frames: *std.ArrayList(Frame),
    unknown: *std.ArrayList(Range),
    text: *std.Io.Writer.Allocating,
    snippet: []const u8,
    name_end: usize,
    resolver: ?Resolver,
    discard: bool,
) Error!void {
    const frame = frames.pop() orelse return error.InvalidState;
    const name_begin = frame.name_begin orelse return error.InvalidState;
    if (discard) return;
    const name = snippet[name_begin..name_end];
    if (try resolve(allocator, resolver, name)) |value| {
        defer allocator.free(value);
        try text.writer.writeAll(value);
    } else {
        const begin = text.written().len;
        try text.writer.writeAll(name);
        (try unknown.addOne(allocator)).* = .{
            .begin = .{begin},
            .end = .{text.written().len},
        };
    }
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
