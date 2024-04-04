const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("root");

const LSP = @import("LSP.zig");

a: std.mem.Allocator,
name: []const u8,
files: std.ArrayList(File),
open_time: i64,
lsp: ?LSP = null,
lsp_name: [:0]const u8,

const Self = @This();

const File = struct {
    path: []const u8,
    mtime: i128,
};

pub fn init(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!Self {
    return .{
        .a = a,
        .name = try a.dupe(u8, name),
        .files = std.ArrayList(File).init(a),
        .open_time = std.time.milliTimestamp(),
        .lsp_name = "zls",
    };
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |file| self.a.free(file.path);
    self.files.deinit();
    if (self.lsp) |*lsp| lsp.deinit();
    self.a.free(self.name);
}

fn get_lsp(self: *Self) !LSP {
    if (self.lsp) |lsp| return lsp;
    self.lsp = try LSP.open(self.a, tp.message.fmt(.{self.lsp_name}), self.lsp_name);
    const uri = try self.make_URI(null);
    defer self.a.free(uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, self.name, std.fs.path.sep);
    const basename = if (basename_begin) |begin| self.name[begin + 1 ..] else self.name;
    const response = try self.send_lsp_init_request(self.name, basename, uri);
    defer self.a.free(response.buf);
    return self.lsp.?;
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

pub fn did_open(self: *Self, from: tp.pid_ref, file_path: []const u8, file_type: []const u8, version: usize, text: []const u8) tp.result {
    _ = from; // autofix
    const lsp = self.get_lsp() catch |e| return tp.exit_error(e);
    const uri = self.make_URI(file_path) catch |e| return tp.exit_error(e);
    defer self.a.free(uri);
    try lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    });
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) tp.result {
    const lsp = self.get_lsp() catch |e| return tp.exit_error(e);
    const uri = self.make_URI(file_path) catch |e| return tp.exit_error(e);
    defer self.a.free(uri);
    const response = try lsp.send_request(self.a, "textDocument/definition", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    });
    defer self.a.free(response.buf);
    try from.send_raw(response);
}

fn send_lsp_init_request(self: *Self, project_path: []const u8, project_basename: []const u8, project_uri: []const u8) error{Exit}!tp.message {
    return self.lsp.?.send_request(self.a, "initialize", .{
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
                .configuration = true,
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
                .didChangeConfiguration = .{ .dynamicRegistration = true },
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
                .positionEncodings = .{"utf-16"},
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
