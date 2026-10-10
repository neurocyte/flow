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

// Hover
// A hover request makes the server send a workspace/applyEdit request. The
// edit inserts a line at the top of the hovered file and at the top of a
// second file with the same name plus ".other".
// The edit of the hovered file carries the document version that the client
// last sent for that file, so the client must accept it.
// On line 1 the edit carries a wrong document version, so the client must
// answer with "applied: false".

// Diagnostics
// When a file opens, the server publishes one warning for the first three
// characters of line 2. The diagnostic carries a data field.

// Code actions
// A code action request returns these items. The server ignores the "only"
// filter of the request, so the client must filter.
// - A preferred quick fix that inserts a comment line above the range. Its
//   title shows how many diagnostics the request context held, and whether
//   their data field came back.
// - A quick fix without an edit. The edit comes from codeAction/resolve.
// - A disabled refactoring.
// - A refactoring with an edit and a command. The command must run after
//   the edit.
// - An old style Command item.
// - Three refactorings with file operations, all in the directory of the file:
//   create "created.dummy" with one line of text, rename the file to
//   "renamed.dummy" after an edit to it, and delete "<file>.other".

// Commands
// The command "dummy.apply" makes the server send a workspace/applyEdit
// request that inserts a line at the top of the file given as its argument.

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
    .hoverProvider = true,
    .codeActionProvider = .{ .resolveProvider = true },
    .executeCommandProvider = .{ .commands = .{"dummy.apply"} },
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
    if (std.mem.eql(u8, method, "textDocument/didOpen")) try publish_diagnostics(arena, out, params);
    if (std.mem.eql(u8, method, "textDocument/didOpen") or std.mem.eql(u8, method, "textDocument/didChange"))
        synced.set(get(params, "textDocument") orelse .null);
    const id_ = id orelse return true;

    if (std.mem.eql(u8, method, "initialize")) {
        try respond(arena, out, id_, .{ .capabilities = capabilities });
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        try respond(arena, out, id_, .{ .isIncomplete = false, .items = try completion_items(arena, params) });
    } else if (std.mem.eql(u8, method, "completionItem/resolve")) {
        try resolve(io, arena, out, id_, params);
    } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
        try code_actions(arena, out, id_, params);
    } else if (std.mem.eql(u8, method, "codeAction/resolve")) {
        try resolve_code_action(arena, out, id_, params);
    } else if (std.mem.eql(u8, method, "workspace/executeCommand")) {
        try execute_command(arena, out, params);
        try respond(arena, out, id_, null);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        try send_apply_edit(arena, out, params);
        try respond(arena, out, id_, .{ .contents = "dummy_lsp sent workspace/applyEdit" });
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

fn publish_diagnostics(arena: std.mem.Allocator, out: *std.Io.Writer, params: std.json.Value) !void {
    const uri = get_string(get(params, "textDocument") orelse .null, "uri") orelse return;
    try send(arena, out, .{
        .jsonrpc = "2.0",
        .method = "textDocument/publishDiagnostics",
        .params = .{
            .uri = uri,
            .diagnostics = .{.{
                .range = Range{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 3 } },
                .severity = 2,
                .source = "dummy_lsp",
                .message = "dummy warning",
                .data = .{ .id = 7 },
            }},
        },
    });
}

fn code_actions(arena: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, params: std.json.Value) !void {
    const uri = get_string(get(params, "textDocument") orelse .null, "uri") orelse return respond(arena, out, id, null);
    const start = get(get(params, "range") orelse .null, "start") orelse .null;
    const line: usize = @intCast(get_int(start, "line") orelse 0);

    var diagnostics: usize = 0;
    var data_returned = false;
    switch (get(get(params, "context") orelse .null, "diagnostics") orelse .null) {
        .array => |array| {
            diagnostics = array.items.len;
            for (array.items) |diagnostic| {
                if ((get_int(get(diagnostic, "data") orelse .null, "id") orelse 0) == 7) data_returned = true;
            }
        },
        else => {},
    }
    const title = try std.fmt.allocPrint(arena, "Insert comment ({d} diagnostics in context{s})", .{
        diagnostics,
        if (data_returned) ", data returned" else "",
    });

    try respond(arena, out, id, .{
        .{ .title = title, .kind = "quickfix", .isPreferred = true, .edit = .{ .changes = Changes.insert_line(uri, line, "# fixed by dummy_lsp\n") } },
        .{ .title = "Lazy fix (dummy)", .kind = "quickfix", .data = .{ .uri = uri, .line = line } },
        .{ .title = "Rewrite (dummy)", .kind = "refactor.rewrite", .disabled = .{ .reason = "nothing to rewrite" } },
        .{
            .title = "Edit then command (dummy)",
            .kind = "refactor",
            .edit = .{ .changes = Changes.insert_line(uri, line, "# edited by dummy_lsp\n") },
            .command = .{ .title = "Apply", .command = "dummy.apply", .arguments = .{uri} },
        },
        .{ .title = "Run dummy command", .command = "dummy.apply", .arguments = .{uri} },
        .{ .title = "Create file (dummy)", .kind = "refactor", .edit = .{ .documentChanges = .{
            FileOperation{ .kind = "create", .uri = try sibling(arena, uri, "created.dummy") },
            TextDocumentEdit{ .textDocument = .{ .uri = try sibling(arena, uri, "created.dummy") }, .edits = &.{.{ .range = top, .newText = "created by dummy_lsp\n" }} },
        } } },
        .{ .title = "Rename file (dummy)", .kind = "refactor", .edit = .{ .documentChanges = .{
            TextDocumentEdit{ .textDocument = .{ .uri = uri }, .edits = &.{.{ .range = top, .newText = "# renamed by dummy_lsp\n" }} },
            FileOperation{ .kind = "rename", .oldUri = uri, .newUri = try sibling(arena, uri, "renamed.dummy") },
        } } },
        .{ .title = "Delete other file (dummy)", .kind = "refactor", .edit = .{ .documentChanges = .{
            FileOperation{ .kind = "delete", .uri = try std.fmt.allocPrint(arena, "{s}.other", .{uri}) },
        } } },
    });
}

const FileOperation = struct {
    kind: []const u8,
    uri: ?[]const u8 = null,
    oldUri: ?[]const u8 = null,
    newUri: ?[]const u8 = null,
};

const TextDocumentEdit = struct {
    textDocument: struct { uri: []const u8, version: ?i64 = null },
    edits: []const TextEdit,
};

fn sibling(arena: std.mem.Allocator, uri: []const u8, name: []const u8) ![]const u8 {
    const dir = uri[0 .. (std.mem.lastIndexOfScalar(u8, uri, '/') orelse return error.InvalidUri) + 1];
    return std.fmt.allocPrint(arena, "{s}{s}", .{ dir, name });
}

const Changes = struct {
    uri: []const u8,
    edits: [1]TextEdit,

    fn insert_line(uri: []const u8, line: usize, text: []const u8) Changes {
        return .{ .uri = uri, .edits = .{.{
            .range = .{ .start = .{ .line = line, .character = 0 }, .end = .{ .line = line, .character = 0 } },
            .newText = text,
        }} };
    }

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField(self.uri);
        try jw.write(self.edits);
        try jw.endObject();
    }
};

fn resolve_code_action(arena: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, action: std.json.Value) !void {
    const data = get(action, "data") orelse return respond(arena, out, id, action);
    const uri = get_string(data, "uri") orelse return respond(arena, out, id, action);
    const line: usize = @intCast(get_int(data, "line") orelse 0);
    try respond(arena, out, id, .{
        .title = get_string(action, "title") orelse "",
        .kind = get_string(action, "kind") orelse "",
        .data = data,
        .edit = .{ .changes = Changes.insert_line(uri, line, "# lazily fixed by dummy_lsp\n") },
    });
}

fn execute_command(arena: std.mem.Allocator, out: *std.Io.Writer, params: std.json.Value) !void {
    if (!std.mem.eql(u8, get_string(params, "command") orelse "", "dummy.apply")) return;
    const uri = switch (get(params, "arguments") orelse .null) {
        .array => |arguments| if (arguments.items.len > 0 and arguments.items[0] == .string) arguments.items[0].string else return,
        else => return,
    };
    try send(arena, out, .{
        .jsonrpc = "2.0",
        .id = "apply-edit-command",
        .method = "workspace/applyEdit",
        .params = .{ .edit = .{ .changes = Changes.insert_line(uri, 0, "# applied by dummy command\n") } },
    });
}

// the document that the client last opened or changed, and its version
var synced: struct {
    uri_buf: [4096]u8 = undefined,
    uri: []const u8 = "",
    version: ?i64 = null,

    fn set(self: *@This(), text_document: std.json.Value) void {
        const uri = get_string(text_document, "uri") orelse return;
        if (uri.len > self.uri_buf.len) return;
        @memcpy(self.uri_buf[0..uri.len], uri);
        self.uri = self.uri_buf[0..uri.len];
        self.version = get_int(text_document, "version");
    }

    fn get(self: *const @This(), uri: []const u8) ?i64 {
        return if (std.mem.eql(u8, self.uri, uri)) self.version else null;
    }
} = .{};

fn send_apply_edit(arena: std.mem.Allocator, out: *std.Io.Writer, params: std.json.Value) !void {
    const uri = get_string(get(params, "textDocument") orelse .null, "uri") orelse return;
    const line = get_int(get(params, "position") orelse .null, "line") orelse 0;
    const version: ?i64 = if (line == 0) 999 else synced.get(uri);
    const edits: []const TextEdit = &.{.{ .range = top, .newText = "applied by dummy_lsp\n" }};
    try send(arena, out, .{
        .jsonrpc = "2.0",
        .id = "apply-edit",
        .method = "workspace/applyEdit",
        .params = .{
            .label = "dummy edit",
            .edit = .{ .documentChanges = .{
                .{ .textDocument = .{ .uri = uri, .version = version }, .edits = edits },
                .{ .textDocument = .{ .uri = try std.fmt.allocPrint(arena, "{s}.other", .{uri}), .version = null }, .edits = edits },
            } },
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
