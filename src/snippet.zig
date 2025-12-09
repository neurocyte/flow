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
    var tabstops: std.ArrayList(struct { id: usize, range: Range }) = .empty;
    defer tabstops.deinit(allocator);
    var id: ?usize = null;
    var content_begin: std.ArrayList(Position) = .empty;
    defer content_begin.deinit(allocator);
    var max_id: usize = 0;
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
                '{' => {
                    state = .placeholder;
                },
                '0'...'9' => {
                    const digit: usize = @intCast(c - '0');
                    id = if (id) |id_| (id_ * 10) + digit else digit;
                },
                else => {
                    const pos = snippet.len - iter.len;
                    if (id == null)
                        return invalid(snippet, pos, error.InvalidIdValue);
                    (try tabstops.addOne(allocator)).* = .{
                        .id = id orelse unreachable,
                        .range = .{ .begin = .{text.written().len} },
                    };
                    max_id = @max(id orelse unreachable, max_id);
                    id = null;
                    state = state_stack.pop() orelse return error.InvalidState;
                    continue :fsm .initial;
                },
            },
            .placeholder => switch (c) {
                '0'...'9' => {
                    const digit: usize = @intCast(c - '0');
                    id = if (id) |id_| (id_ * 10) + digit else digit;
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
                    (try tabstops.addOne(allocator)).* = .{
                        .id = id orelse unreachable,
                        .range = .{
                            .begin = begin_pos,
                            .end = .{text.written().len},
                        },
                    };
                    max_id = @max(id orelse unreachable, max_id);
                    id = null;
                    state = state_stack.pop() orelse return error.InvalidState;
                },
                else => try text.writer.writeByte(c),
            },
        }
    }

    if (state != .initial) {
        const pos = snippet.len - iter.len;
        if (id == null)
            return invalid(snippet, pos, error.UnexpectedEndOfDocument);
    }

    var result: std.ArrayList([]Range) = .empty;
    defer result.deinit(allocator);
    var n: usize = 1;
    while (n <= max_id) : (n += 1) {
        var tabstop: std.ArrayList(Range) = .empty;
        errdefer tabstop.deinit(allocator);
        for (tabstops.items) |item| if (item.id == n) {
            (try tabstop.addOne(allocator)).* = item.range;
        };
        if (tabstop.items.len > 0)
            (try result.addOne(allocator)).* = try tabstop.toOwnedSlice(allocator);
    }
    var tabstop: std.ArrayList(Range) = .empty;
    errdefer tabstop.deinit(allocator);
    for (tabstops.items) |item| if (item.id == 0) {
        (try tabstop.addOne(allocator)).* = item.range;
    };
    if (tabstop.items.len > 0)
        (try result.addOne(allocator)).* = try tabstop.toOwnedSlice(allocator);
    return .{
        .text = try text.toOwnedSlice(),
        .tabstops = try result.toOwnedSlice(allocator),
    };
}

fn invalid(snippet: []const u8, pos: usize, e: Error) Error {
    log.err("invalid snippet: {s}", .{snippet});
    log.err("{t} at pos {d}", .{ e, pos });
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
