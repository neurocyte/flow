const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("root");

const LSP = @import("LSP.zig");

a: std.mem.Allocator,
name: []const u8,
files: std.ArrayList(File),
open_time: i64,
language_servers: std.StringHashMap(LSP),
file_language_server: std.StringHashMap(LSP),

const Self = @This();

const File = struct {
    path: []const u8,
    mtime: i128,
    row: usize = 0,
    col: usize = 0,
};

pub fn init(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!Self {
    return .{
        .a = a,
        .name = try a.dupe(u8, name),
        .files = std.ArrayList(File).init(a),
        .open_time = std.time.milliTimestamp(),
        .language_servers = std.StringHashMap(LSP).init(a),
        .file_language_server = std.StringHashMap(LSP).init(a),
    };
}

pub fn deinit(self: *Self) void {
    var i_ = self.file_language_server.iterator();
    while (i_.next()) |p| {
        self.a.free(p.key_ptr.*);
    }
    var i = self.language_servers.iterator();
    while (i.next()) |p| {
        self.a.free(p.key_ptr.*);
        p.value_ptr.*.deinit();
    }
    for (self.files.items) |file| self.a.free(file.path);
    self.files.deinit();
    self.a.free(self.name);
}

fn get_lsp(self: *Self, language_server: []const u8) !LSP {
    if (self.language_servers.get(language_server)) |lsp| return lsp;
    const lsp = try LSP.open(self.a, .{ .buf = language_server });
    try self.language_servers.put(try self.a.dupe(u8, language_server), lsp);
    const uri = try self.make_URI(null);
    defer self.a.free(uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, self.name, std.fs.path.sep);
    const basename = if (basename_begin) |begin| self.name[begin + 1 ..] else self.name;
    const response = try self.send_lsp_init_request(lsp, self.name, basename, uri);
    defer self.a.free(response.buf);
    try lsp.send_notification("initialized", .{});
    return lsp;
}

fn get_file_lsp(self: *Self, file_path: []const u8) !LSP {
    const lsp = self.file_language_server.get(file_path) orelse return tp.exit("no language server");
    if (lsp.pid.expired()) return tp.exit("no language server");
    return lsp;
}

fn make_URI(self: *Self, file_path: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(self.a);
    if (file_path) |path|
        try buf.writer().print("file://{s}/{s}", .{ self.name, path })
    else
        try buf.writer().print("file://{s}", .{self.name});
    return buf.toOwnedSlice();
}

pub fn add_file(self: *Self, path: []const u8, mtime: i128) error{OutOfMemory}!void {
    (try self.files.addOne()).* = .{ .path = try self.a.dupe(u8, path), .mtime = mtime };
}

pub fn sort_files_by_mtime(self: *Self) void {
    const less_fn = struct {
        fn less_fn(_: void, lhs: File, rhs: File) bool {
            return lhs.mtime > rhs.mtime;
        }
    }.less_fn;
    std.mem.sort(File, self.files.items, {}, less_fn);
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) error{ OutOfMemory, Exit }!void {
    defer from.send(.{ "PRJ", "recent_done", "" }) catch {};
    for (self.files.items, 0..) |file, i| {
        try from.send(.{ "PRJ", "recent", file.path });
        if (i >= max) return;
    }
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) error{ OutOfMemory, Exit }!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "recent_done", query }) catch {};
    for (self.files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |_| {
            try from.send(.{ "PRJ", "recent", file.path });
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn update_mru(self: *Self, file_path: []const u8, row: usize, col: usize) !void {
    defer self.sort_files_by_mtime();
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        file.mtime = std.time.nanoTimestamp();
        if (row != 0) {
            file.row = row;
            file.col = col;
        }
        return;
    }
    return self.add_file(file_path, std.time.nanoTimestamp());
}

pub fn get_mru_position(self: *Self, from: tp.pid_ref, file_path: []const u8) !void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        if (file.row != 0)
            try from.send(.{ "cmd", "goto", .{ file.row, file.col } });
        return;
    }
}

pub fn did_open(self: *Self, from: tp.pid_ref, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) tp.result {
    self.update_mru(file_path, 0, 0) catch {};
    self.get_mru_position(from, file_path) catch {};
    const lsp = self.get_lsp(language_server) catch |e| return tp.exit_error(e);
    if (!self.file_language_server.contains(file_path)) {
        const key = self.a.dupe(u8, file_path) catch |e| return tp.exit_error(e);
        self.file_language_server.put(key, lsp) catch |e| return tp.exit_error(e);
    }
    const uri = self.make_URI(file_path) catch |e| return tp.exit_error(e);
    defer self.a.free(uri);
    try lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    });
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = self.make_URI(file_path) catch |e| return tp.exit_error(e);
    defer self.a.free(uri);
    const response = try lsp.send_request(self.a, "textDocument/definition", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    });
    defer self.a.free(response.buf);
    var link: []const u8 = undefined;
    if (try response.match(.{ "child", tp.string, "result", tp.array })) {
        if (try response.match(.{ tp.any, tp.any, tp.any, .{ tp.extract_cbor(&link), tp.more } })) {
            try self.navigate_to_location_link(from, link);
        } else if (try response.match(.{ tp.any, tp.any, tp.any, .{tp.extract_cbor(&link)} })) {
            try self.navigate_to_location_link(from, link);
        }
    } else if (try response.match(.{ "child", tp.string, "result", tp.null_ })) {
        return;
    } else if (try response.match(.{ "child", tp.string, "result", tp.extract_cbor(&link) })) {
        try self.navigate_to_location_link(from, link);
    }
}

fn navigate_to_location_link(self: *Self, from: tp.pid_ref, location_link: []const u8) !void {
    var iter = location_link;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var value: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
            targetUri = value;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetRange = try read_range(range);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetSelectionRange = try read_range(range);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (targetUri == null or targetRange == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, targetUri.?[0..7], "file://")) return error.InvalidTargetURI;
    const file_path = try std.Uri.unescapeString(self.a, targetUri.?[7..]);
    defer self.a.free(file_path);
    try from.send(.{ "cmd", "navigate", .{ .file = file_path } });
    if (targetSelectionRange) |sel| {
        try from.send(.{ "cmd", "goto", .{
            targetRange.?.start.line + 1,
            targetRange.?.start.character + 1,
            sel.start.line,
            sel.start.character,
            sel.end.line,
            sel.end.character,
        } });
    } else {
        try from.send(.{ "cmd", "goto", .{
            targetRange.?.start.line + 1,
            targetRange.?.start.character + 1,
        } });
    }
}

const Range = struct { start: Position, end: Position };
fn read_range(range: []const u8) !Range {
    var iter = range;
    var start: ?Position = null;
    var end: ?Position = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "start")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidMessageField;
            start = try read_position(position);
        } else if (std.mem.eql(u8, field_name, "end")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidMessageField;
            end = try read_position(position);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (start == null or end == null) return error.InvalidMessageField;
    return .{ .start = start.?, .end = end.? };
}

const Position = struct { line: usize, character: usize };
fn read_position(position: []const u8) !Position {
    var iter = position;
    var line: ?usize = 0;
    var character: ?usize = 0;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "line")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&line)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "character")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&character)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (line == null or character == null) return error.InvalidMessageField;
    return .{ .line = line.?, .character = character.? };
}

fn send_lsp_init_request(self: *Self, lsp: LSP, project_path: []const u8, project_basename: []const u8, project_uri: []const u8) error{Exit}!tp.message {
    return lsp.send_request(self.a, "initialize", .{
        .processId = std.os.linux.getpid(),
        .rootPath = project_path,
        .rootUri = project_uri,
        .workspaceFolders = .{
            .{
                .uri = project_uri,
                .name = project_basename,
            },
        },
        .trace = "verbose",
        .locale = "en-us",
        .clientInfo = .{
            .name = root.application_name,
            .version = "0.0.1",
        },
        .capabilities = .{
            .workspace = .{
                .applyEdit = true,
                .workspaceEdit = .{
                    .documentChanges = true,
                    .resourceOperations = .{
                        "create",
                        "rename",
                        "delete",
                    },
                    .failureHandling = "textOnlyTransactional",
                    .normalizesLineEndings = true,
                    .changeAnnotationSupport = .{ .groupsOnLabel = true },
                },
                // .configuration = true,
                .didChangeWatchedFiles = .{
                    .dynamicRegistration = true,
                    .relativePatternSupport = true,
                },
                .symbol = .{
                    .dynamicRegistration = true,
                    .symbolKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 },
                    },
                    .tagSupport = .{ .valueSet = .{1} },
                    .resolveSupport = .{ .properties = .{"location.range"} },
                },
                .codeLens = .{ .refreshSupport = true },
                .executeCommand = .{ .dynamicRegistration = true },
                // .didChangeConfiguration = .{ .dynamicRegistration = true },
                .workspaceFolders = true,
                .semanticTokens = .{ .refreshSupport = true },
                .fileOperations = .{
                    .dynamicRegistration = true,
                    .didCreate = true,
                    .didRename = true,
                    .didDelete = true,
                    .willCreate = true,
                    .willRename = true,
                    .willDelete = true,
                },
                .inlineValue = .{ .refreshSupport = true },
                .inlayHint = .{ .refreshSupport = true },
                .diagnostics = .{ .refreshSupport = true },
            },
            .textDocument = .{
                .publishDiagnostics = .{
                    .relatedInformation = true,
                    .versionSupport = false,
                    .tagSupport = .{ .valueSet = .{ 1, 2 } },
                    .codeDescriptionSupport = true,
                    .dataSupport = true,
                },
                .synchronization = .{
                    .dynamicRegistration = true,
                    .willSave = true,
                    .willSaveWaitUntil = true,
                    .didSave = true,
                },
                .completion = .{
                    .dynamicRegistration = true,
                    .contextSupport = true,
                    .completionItem = .{
                        .snippetSupport = true,
                        .commitCharactersSupport = true,
                        .documentationFormat = .{
                            "markdown",
                            "plaintext",
                        },
                        .deprecatedSupport = true,
                        .preselectSupport = true,
                        .tagSupport = .{ .valueSet = .{1} },
                        .insertReplaceSupport = true,
                        .resolveSupport = .{ .properties = .{
                            "documentation",
                            "detail",
                            "additionalTextEdits",
                        } },
                        .insertTextModeSupport = .{ .valueSet = .{ 1, 2 } },
                        .labelDetailsSupport = true,
                    },
                    .insertTextMode = 2,
                    .completionItemKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 },
                    },
                    .completionList = .{ .itemDefaults = .{
                        "commitCharacters",
                        "editRange",
                        "insertTextFormat",
                        "insertTextMode",
                    } },
                },
                .hover = .{
                    .dynamicRegistration = true,
                    .contentFormat = .{ "markdown", "plaintext" },
                },
                .signatureHelp = .{
                    .dynamicRegistration = true,
                    .signatureInformation = .{
                        .documentationFormat = .{ "markdown", "plaintext" },
                        .parameterInformation = .{ .labelOffsetSupport = true },
                        .activeParameterSupport = true,
                    },
                    .contextSupport = true,
                },
                .definition = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .references = .{ .dynamicRegistration = true },
                .documentHighlight = .{ .dynamicRegistration = true },
                .documentSymbol = .{
                    .dynamicRegistration = true,
                    .symbolKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 },
                    },
                    .hierarchicalDocumentSymbolSupport = true,
                    .tagSupport = .{ .valueSet = .{1} },
                    .labelSupport = true,
                },
                .codeAction = .{
                    .dynamicRegistration = true,
                    .isPreferredSupport = true,
                    .disabledSupport = true,
                    .dataSupport = true,
                    .resolveSupport = .{ .properties = .{"edit"} },
                    .codeActionLiteralSupport = .{
                        .codeActionKind = .{
                            .valueSet = .{
                                "",
                                "quickfix",
                                "refactor",
                                "refactor.extract",
                                "refactor.inline",
                                "refactor.rewrite",
                                "source",
                                "source.organizeImports",
                            },
                        },
                    },
                    .honorsChangeAnnotations = false,
                },
                .codeLens = .{ .dynamicRegistration = true },
                .formatting = .{ .dynamicRegistration = true },
                .rangeFormatting = .{ .dynamicRegistration = true },
                .onTypeFormatting = .{ .dynamicRegistration = true },
                .rename = .{
                    .dynamicRegistration = true,
                    .prepareSupport = true,
                    .prepareSupportDefaultBehavior = 1,
                    .honorsChangeAnnotations = true,
                },
                .documentLink = .{
                    .dynamicRegistration = true,
                    .tooltipSupport = true,
                },
                .typeDefinition = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .implementation = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .colorProvider = .{ .dynamicRegistration = true },
                .foldingRange = .{
                    .dynamicRegistration = true,
                    .rangeLimit = 5000,
                    .lineFoldingOnly = true,
                    .foldingRangeKind = .{ .valueSet = .{ "comment", "imports", "region" } },
                    .foldingRange = .{ .collapsedText = false },
                },
                .declaration = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .selectionRange = .{ .dynamicRegistration = true },
                .callHierarchy = .{ .dynamicRegistration = true },
                .semanticTokens = .{
                    .dynamicRegistration = true,
                    .tokenTypes = .{
                        "namespace",
                        "type",
                        "class",
                        "enum",
                        "interface",
                        "struct",
                        "typeParameter",
                        "parameter",
                        "variable",
                        "property",
                        "enumMember",
                        "event",
                        "function",
                        "method",
                        "macro",
                        "keyword",
                        "modifier",
                        "comment",
                        "string",
                        "number",
                        "regexp",
                        "operator",
                        "decorator",
                    },
                    .tokenModifiers = .{
                        "declaration",
                        "definition",
                        "readonly",
                        "static",
                        "deprecated",
                        "abstract",
                        "async",
                        "modification",
                        "documentation",
                        "defaultLibrary",
                    },
                    .formats = .{"relative"},
                    .requests = .{
                        .range = true,
                        .full = .{ .delta = true },
                    },
                    .multilineTokenSupport = false,
                    .overlappingTokenSupport = false,
                    .serverCancelSupport = true,
                    .augmentsSyntaxTokens = true,
                },
                .linkedEditingRange = .{ .dynamicRegistration = true },
                .typeHierarchy = .{ .dynamicRegistration = true },
                .inlineValue = .{ .dynamicRegistration = true },
                .inlayHint = .{
                    .dynamicRegistration = true,
                    .resolveSupport = .{
                        .properties = .{
                            "tooltip",
                            "textEdits",
                            "label.tooltip",
                            "label.location",
                            "label.command",
                        },
                    },
                },
                .diagnostic = .{
                    .dynamicRegistration = true,
                    .relatedDocumentSupport = false,
                },
            },
            .window = .{
                .showMessage = .{
                    .messageActionItem = .{ .additionalPropertiesSupport = true },
                },
                .showDocument = .{ .support = true },
                .workDoneProgress = true,
            },
            .general = .{
                .staleRequestSupport = .{
                    .cancel = true,
                    .retryOnContentModified = .{
                        "textDocument/semanticTokens/full",
                        "textDocument/semanticTokens/range",
                        "textDocument/semanticTokens/full/delta",
                    },
                },
                .regularExpressions = .{
                    .engine = "ECMAScript",
                    .version = "ES2020",
                },
                .markdown = .{
                    .parser = "marked",
                    .version = "1.1.0",
                },
                .positionEncodings = .{"utf-8"},
            },
            .notebookDocument = .{
                .synchronization = .{
                    .dynamicRegistration = true,
                    .executionSummarySupport = true,
                },
            },
        },
    });
}
