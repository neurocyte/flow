//! A dummy language server for testing

// build: zig build-exe test/dummy_lsp/dummy_lsp.zig -femit-bin=zig-out/bin/dummy_lsp

// Copy dummy.conf to the file_type directory of a flow configuration
// directory.

// Use a file with at least three lines. Type two characters and trigger
// completion. Every item replaces the two characters before the cursor.

// Completions
// Widget: An additional edit (an import line at the top) sent with the item
// Lazy:   The same edit, available only through completionItem/resolve
// Slow:   As Lazy, but the resolve answer takes 2.5 seconds
// Error:  A resolve request that fails
// Plain:  An item with nothing to resolve
// make:   A snippet with three additional edits. One replaces the first
//         three characters of line 2. One replaces the first character of the
//         cursor line with four spaces.

// The server reports "resolveProvider: false" and puts a data field on the
// items that need a resolve. rust-analyzer does the same.

const std = @import("std");

const Position = struct { line: usize, character: usize };
const Range = struct { start: Position, end: Position };
const TextEdit = struct { range: Range, newText: []const u8 };

const Data = struct {
    name: []const u8,
    delay_ms: i64 = 0,
    fail: bool = false,
};

const CompletionItem = struct {
    label: []const u8,
    kind: u8 = 7,
    insertTextFormat: ?u8 = null,
    textEdit: TextEdit,
    additionalTextEdits: ?[]const TextEdit = null,
    data: ?Data = null,
};

const top: Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };

const capabilities = .{
    .positionEncoding = "utf-8",
    .textDocumentSync = 1,
    .completionProvider = .{ .resolveProvider = false },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    while (try read_message(&stdin.interface, arena)) |body| {
        defer _ = arena_state.reset(.retain_capacity);
        const msg = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        if (!try handle(io, arena, &stdout.interface, msg)) break;
    }
}

fn read_message(in: *std.Io.Reader, arena: std.mem.Allocator) !?[]const u8 {
    const content_length = "content-length:";
    var length: usize = 0;
    while (true) {
        const line_ = in.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return null,
            else => |e_| return e_,
        };
        const line = std.mem.trim(u8, line_, " \r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, content_length))
            length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[content_length.len..], " "), 10);
    }
    const body = try arena.alloc(u8, length);
    try in.readSliceAll(body);
    return body;
}

fn handle(io: std.Io, arena: std.mem.Allocator, out: *std.Io.Writer, msg: std.json.Value) !bool {
    const method = get_string(msg, "method") orelse return true;
    const id = get(msg, "id");
    const params = get(msg, "params") orelse .null;

    if (std.mem.eql(u8, method, "exit")) return false;
    const id_ = id orelse return true;

    if (std.mem.eql(u8, method, "initialize")) {
        try respond(arena, out, id_, .{ .capabilities = capabilities });
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        try respond(arena, out, id_, .{ .isIncomplete = false, .items = try completion_items(arena, params) });
    } else if (std.mem.eql(u8, method, "completionItem/resolve")) {
        try resolve(io, arena, out, id_, params);
    } else {
        try respond(arena, out, id_, null);
    }
    return true;
}

fn completion_items(arena: std.mem.Allocator, params: std.json.Value) ![]const CompletionItem {
    const position = get(params, "position") orelse .null;
    const line: usize = @intCast(get_int(position, "line") orelse 0);
    const character: usize = @intCast(get_int(position, "character") orelse 0);
    // every item replaces the two characters before the cursor
    const range: Range = .{
        .start = .{ .line = line, .character = character -| 2 },
        .end = .{ .line = line, .character = character },
    };
    return arena.dupe(CompletionItem, &.{
        // additional edit sent with the item
        .{
            .label = "Widget",
            .textEdit = .{ .range = range, .newText = "Widget" },
            .additionalTextEdits = &.{.{ .range = top, .newText = "import Widget;\n" }},
        },
        // additional edit only available through completionItem/resolve
        .{ .label = "Lazy", .textEdit = .{ .range = range, .newText = "Lazy" }, .data = .{ .name = "Lazy" } },
        // as Lazy, but the resolve answer takes 2.5 seconds
        .{ .label = "Slow", .textEdit = .{ .range = range, .newText = "Slow" }, .data = .{ .name = "Slow", .delay_ms = 2500 } },
        // the resolve request fails
        .{ .label = "Error", .textEdit = .{ .range = range, .newText = "Error" }, .data = .{ .name = "Error", .fail = true } },
        // nothing to resolve
        .{ .label = "Plain", .textEdit = .{ .range = range, .newText = "Plain" } },
        // snippet with three additional edits, one of them on the cursor line
        .{
            .label = "make",
            .kind = 3,
            .insertTextFormat = 2,
            .textEdit = .{ .range = range, .newText = "make(${1:arg})$0" },
            .additionalTextEdits = try arena.dupe(TextEdit, &.{
                .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 3 } }, .newText = "NEW" },
                .{ .range = top, .newText = "use make;\n" },
                .{ .range = .{ .start = .{ .line = line, .character = 0 }, .end = .{ .line = line, .character = 1 } }, .newText = "    " },
            }),
        },
    });
}

fn resolve(io: std.Io, arena: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, item: std.json.Value) !void {
    const data = get(item, "data") orelse return respond(arena, out, id, item);
    if (get_bool(data, "fail") orelse false)
        return respond_error(arena, out, id, -32801, "content modified");
    try std.Io.sleep(io, .fromMilliseconds(get_int(data, "delay_ms") orelse 0), .awake);

    const import = try std.fmt.allocPrint(arena, "import {s};\n", .{get_string(data, "name") orelse "?"});
    const Resolved = struct {
        item: std.json.Value,
        additionalTextEdits: []const TextEdit,

        pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
            try jw.beginObject();
            var fields = self.item.object.iterator();
            while (fields.next()) |field| {
                try jw.objectField(field.key_ptr.*);
                try jw.write(field.value_ptr.*);
            }
            try jw.objectField("additionalTextEdits");
            try jw.write(self.additionalTextEdits);
            try jw.endObject();
        }
    };
    try respond(arena, out, id, Resolved{
        .item = item,
        .additionalTextEdits = &.{.{ .range = top, .newText = import }},
    });
}

fn respond(arena: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, result: anytype) !void {
    try send(arena, out, .{ .jsonrpc = "2.0", .id = id, .result = result });
}

fn respond_error(arena: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    try send(arena, out, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
}

fn send(arena: std.mem.Allocator, out: *std.Io.Writer, msg: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(arena, msg, .{ .emit_null_optional_fields = false });
    try out.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try out.flush();
}

fn get(value: std.json.Value, field: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(field),
        else => null,
    };
}

fn get_string(value: std.json.Value, field: []const u8) ?[]const u8 {
    return switch (get(value, field) orelse return null) {
        .string => |string| string,
        else => null,
    };
}

fn get_int(value: std.json.Value, field: []const u8) ?i64 {
    return switch (get(value, field) orelse return null) {
        .integer => |integer| integer,
        else => null,
    };
}

fn get_bool(value: std.json.Value, field: []const u8) ?bool {
    return switch (get(value, field) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}
