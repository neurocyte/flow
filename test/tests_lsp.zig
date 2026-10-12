const std = @import("std");
const cbor = @import("cbor");
const write_workspace_edit = @import("project_manager").test_internal.write_workspace_edit;

const a = std.testing.allocator;

fn expect_workspace_edit(json: []const u8, expected_json: []const u8) !void {
    const workspace_edit = try cbor.fromJsonAlloc(a, json);
    defer a.free(workspace_edit);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_workspace_edit(&result.writer, workspace_edit, null);
    const result_json = try cbor.toJsonAlloc(a, result.written());
    defer a.free(result_json);
    try std.testing.expectEqualStrings(expected_json, result_json);
}

test "workspace edit: changes" {
    try expect_workspace_edit(
        \\{"changes":{
        \\  "file:///src/a.zig":[
        \\    {"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"newText":"foo"},
        \\    {"range":{"start":{"line":7,"character":0},"end":{"line":8,"character":0}},"newText":""}],
        \\  "file:///src/b.zig":[
        \\    {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"bar\n"}]
        \\}}
    ,
        \\[["/src/a.zig",null,[[[1,2,1,5,"foo"],[7,0,8,0,""]],null,null,null,null]],["/src/b.zig",null,[[[0,0,0,0,"bar\n"]],null,null,null,null]]]
    );
}

test "workspace edit: documentChanges" {
    try expect_workspace_edit(
        \\{"documentChanges":[
        \\  {"textDocument":{"uri":"file:///src/a.zig","version":4},"edits":[
        \\    {"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"newText":"foo"}]},
        \\  {"edits":[
        \\    {"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":1}},"newText":"x","annotationId":"a"}],
        \\   "textDocument":{"version":null,"uri":"file:///src/b.zig"}}
        \\]}
    ,
        \\[["/src/a.zig",4,[[[1,2,1,5,"foo"]],null,null,null,null]],["/src/b.zig",null,[[[3,0,3,1,"x"]],null,null,null,null]]]
    );
}

test "workspace edit: edits are sorted, two inserts at one position keep their order" {
    try expect_workspace_edit(
        \\{"changes":{"file:///src/a.zig":[
        \\  {"range":{"start":{"line":7,"character":0},"end":{"line":8,"character":0}},"newText":""},
        \\  {"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":2}},"newText":"first"},
        \\  {"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":1}},"newText":"x"},
        \\  {"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":2}},"newText":"second"}]
        \\}}
    ,
        \\[["/src/a.zig",null,[[[0,1,0,4,"x"],[1,2,1,2,"first"],[1,2,1,2,"second"],[7,0,8,0,""]],null,null,null,null]]]
    );
}

test "workspace edit: overlapping edits are invalid" {
    const workspace_edit = try cbor.fromJsonAlloc(a,
        \\{"changes":{"file:///src/a.zig":[
        \\  {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"newText":"a"},
        \\  {"range":{"start":{"line":1,"character":3},"end":{"line":1,"character":8}},"newText":"b"}]
        \\}}
    );
    defer a.free(workspace_edit);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try std.testing.expectError(error.InvalidTextEdit, write_workspace_edit(&result.writer, workspace_edit, null));
}

test "workspace edit: documentChanges is preferred over changes" {
    try expect_workspace_edit(
        \\{"changes":{"file:///src/a.zig":[]},
        \\ "documentChanges":[{"textDocument":{"uri":"file:///src/b.zig","version":1},"edits":[]}]}
    ,
        \\[["/src/b.zig",1,[[],null,null,null,null]]]
    );
}

test "workspace edit: file operations" {
    try expect_workspace_edit(
        \\{"documentChanges":[
        \\  {"kind":"create","uri":"file:///src/new.zig"},
        \\  {"textDocument":{"uri":"file:///src/new.zig","version":null},"edits":[
        \\    {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]},
        \\  {"kind":"rename","oldUri":"file:///src/a.zig","newUri":"file:///src/sub/b.zig"},
        \\  {"kind":"delete","uri":"file:///src/c.zig"}
        \\]}
    ,
        \\[["create","/src/new.zig","","fail","file"],["/src/new.zig",null,[[[0,0,0,0,"x"]],null,null,null,null]],["rename","/src/a.zig","/src/sub/b.zig","fail","file"],["delete","/src/c.zig","","fail","file"]]
    );
}

test "workspace edit: file operation options" {
    try expect_workspace_edit(
        \\{"documentChanges":[
        \\  {"kind":"create","uri":"file:///a","options":{"overwrite":true,"ignoreIfExists":true}},
        \\  {"kind":"create","uri":"file:///b","options":{"ignoreIfExists":true}},
        \\  {"options":{"overwrite":false,"ignoreIfExists":false},"newUri":"file:///d","oldUri":"file:///c","kind":"rename"},
        \\  {"kind":"delete","uri":"file:///dir","options":{"recursive":true,"ignoreIfNotExists":true},"annotationId":"x"},
        \\  {"kind":"delete","uri":"file:///e","options":null}
        \\]}
    ,
        \\[["create","/a","","overwrite","file"],["create","/b","","ignore","file"],["rename","/c","/d","fail","file"],["delete","/dir","","ignore","recursive"],["delete","/e","","fail","file"]]
    );
}

test "workspace edit: invalid file operations" {
    for ([_][]const u8{
        \\{"documentChanges":[{"kind":"move","uri":"file:///a"}]}
        ,
        \\{"documentChanges":[{"kind":"create"}]}
        ,
        \\{"documentChanges":[{"kind":"rename","oldUri":"file:///a"}]}
    }) |json| {
        const workspace_edit = try cbor.fromJsonAlloc(a, json);
        defer a.free(workspace_edit);
        var result: std.Io.Writer.Allocating = .init(a);
        defer result.deinit();
        try std.testing.expectError(error.InvalidWorkspaceEditField, write_workspace_edit(&result.writer, workspace_edit, null));
    }
}

test "workspace edit: percent encoded uri" {
    try expect_workspace_edit(
        \\{"changes":{"file:///src/a%20b.zig":[]}}
    ,
        \\[["/src/a b.zig",null,[[],null,null,null,null]]]
    );
}

test "workspace edit: neither changes nor documentChanges" {
    const workspace_edit = try cbor.fromJsonAlloc(a, "{}");
    defer a.free(workspace_edit);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try std.testing.expectError(error.InvalidWorkspaceEdit, write_workspace_edit(&result.writer, workspace_edit, null));
}

const write_did_change = @import("project_manager").test_internal.write_did_change;

const ContentChange = struct {
    range: struct {
        start: struct { line: usize, character: usize },
        end: struct { line: usize, character: usize },
    },
    text: []const u8,
};

fn line_offset(text: []const u8, line: usize, character: usize) usize {
    var offset: usize = 0;
    var row = line;
    while (row > 0) : (row -= 1) offset = std.mem.indexOfScalarPos(u8, text, offset, '\n').? + 1;
    return offset + character;
}

// apply the content changes one after the other, as a language server does
fn expect_did_change(src: []const u8, dst: []const u8, expected_changes: ?usize) !void {
    var params: std.Io.Writer.Allocating = .init(a);
    defer params.deinit();
    var edit_set: std.Io.Writer.Allocating = .init(a);
    defer edit_set.deinit();
    try @import("EditSet").diff_strings(a, &edit_set, src, dst);
    try write_did_change(a, &params.writer, "file:///a", 7, .{ .bytes = edit_set.written() });
    const json = try cbor.toJsonAlloc(a, params.written());
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(struct {
        textDocument: struct { uri: []const u8, version: usize },
        contentChanges: []const ContentChange,
    }, a, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file:///a", parsed.value.textDocument.uri);
    try std.testing.expectEqual(7, parsed.value.textDocument.version);
    if (expected_changes) |count| try std.testing.expectEqual(count, parsed.value.contentChanges.len);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, src);
    for (parsed.value.contentChanges) |change| {
        const begin = line_offset(text.items, change.range.start.line, change.range.start.character);
        const end = line_offset(text.items, change.range.end.line, change.range.end.character);
        try text.replaceRange(a, begin, end - begin, change.text);
    }
    try std.testing.expectEqualStrings(dst, text.items);
}

test "did change: the changes applied in order give the new text" {
    try expect_did_change("one\ntwo\n", "one\ntwo\n", 0);
    try expect_did_change("one\ntwo\n", "one\n2\n", 1);
    try expect_did_change("let a = 1;\nlet b = 2;\n", "let a = 10;\nlet c = 2;\nlet d;\n", 3);
    try expect_did_change("one\r\ntwo\r\n", "one\r\nthree\r\ntwo\r\n", 1);
    try expect_did_change("", "new\nfile\n", 1);
    try expect_did_change("old\nfile\n", "", 1);
    try expect_did_change("caf\u{e9}\n", "caf\u{e8}\n", 1);
}

test "did change: random texts" {
    const pieces = [_][]const u8{ "a", "b", " ", "\n", "\n", "\u{e9}", "\u{65e5}", "fn ", "x = 1;" };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    var dst: std.ArrayList(u8) = .empty;
    defer dst.deinit(a);
    for (0..300) |_| {
        src.clearRetainingCapacity();
        dst.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 40)) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            switch (random.uintLessThan(u8, 10)) {
                0 => try src.appendSlice(a, piece),
                1 => try dst.appendSlice(a, piece),
                else => {
                    try src.appendSlice(a, piece);
                    try dst.appendSlice(a, piece);
                },
            }
        }
        try expect_did_change(src.items, dst.items, null);
    }
}

const DocumentHashes = @import("project_manager").test_internal.DocumentHashes;

test "document hashes: lookup by version and of the last version" {
    var hashes: DocumentHashes = .{};
    defer hashes.deinit(a);
    try std.testing.expectEqual(null, hashes.base_hash("file:///a", null));
    try hashes.open(a, "file:///a", 1, 100);
    hashes.change("file:///a", 2, 200);
    hashes.change("file:///a", 3, 300);
    hashes.change("file:///other", 9, 900);
    try std.testing.expectEqual(100, hashes.base_hash("file:///a", 1).?);
    try std.testing.expectEqual(200, hashes.base_hash("file:///a", 2).?);
    try std.testing.expectEqual(300, hashes.base_hash("file:///a", null).?);
    try std.testing.expectEqual(null, hashes.base_hash("file:///a", 4));
    try std.testing.expectEqual(null, hashes.base_hash("file:///other", null));
}

test "document hashes: only the last versions are kept" {
    var hashes: DocumentHashes = .{};
    defer hashes.deinit(a);
    try hashes.open(a, "file:///a", 0, 1000);
    for (1..DocumentHashes.max_versions + 5) |version| hashes.change("file:///a", version, 1000 + version);
    const last = DocumentHashes.max_versions + 4;
    try std.testing.expectEqual(1000 + last, hashes.base_hash("file:///a", null).?);
    try std.testing.expectEqual(1000 + last, hashes.base_hash("file:///a", last).?);
    try std.testing.expectEqual(1000 + last - 31, hashes.base_hash("file:///a", last - 31).?);
    try std.testing.expectEqual(null, hashes.base_hash("file:///a", last - 32));
    try std.testing.expectEqual(null, hashes.base_hash("file:///a", 0));
}

test "document hashes: open again and close forget the versions" {
    var hashes: DocumentHashes = .{};
    defer hashes.deinit(a);
    try hashes.open(a, "file:///a", 1, 100);
    hashes.change("file:///a", 2, 200);
    try hashes.open(a, "file:///a", 1, 111);
    try std.testing.expectEqual(111, hashes.base_hash("file:///a", null).?);
    try std.testing.expectEqual(null, hashes.base_hash("file:///a", 2));
    hashes.close(a, "file:///a");
    try std.testing.expectEqual(null, hashes.base_hash("file:///a", null));
}

test "workspace edit: text edits get the hash of their document version" {
    var hashes: DocumentHashes = .{};
    defer hashes.deinit(a);
    try hashes.open(a, "file:///src/a.zig", 4, 44);
    hashes.change("file:///src/a.zig", 5, 55);
    try hashes.open(a, "file:///src/b.zig", 1, 11);
    const workspace_edit = try cbor.fromJsonAlloc(a,
        \\{"documentChanges":[
        \\  {"textDocument":{"uri":"file:///src/a.zig","version":4},"edits":[]},
        \\  {"textDocument":{"uri":"file:///src/a.zig","version":9},"edits":[]},
        \\  {"textDocument":{"uri":"file:///src/b.zig","version":null},"edits":[]},
        \\  {"textDocument":{"uri":"file:///src/c.zig","version":null},"edits":[]}
        \\]}
    );
    defer a.free(workspace_edit);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_workspace_edit(&result.writer, workspace_edit, &hashes);
    const result_json = try cbor.toJsonAlloc(a, result.written());
    defer a.free(result_json);
    try std.testing.expectEqualStrings(
        \\[["/src/a.zig",4,[[],44,null,null,null]],["/src/a.zig",9,[[],null,null,null,null]],["/src/b.zig",null,[[],11,null,null,null]],["/src/c.zig",null,[[],null,null,null,null]]]
    , result_json);
}

const write_diagnostics_in_range = @import("project_manager").test_internal.write_diagnostics_in_range;
const ServerCapabilities = @import("project_manager").test_internal.ServerCapabilities;

const diagnostics_json =
    \\[{"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":8}},"message":"a","data":{"x":1}},
    \\ {"range":{"start":{"line":3,"character":0},"end":{"line":5,"character":2}},"message":"b"},
    \\ {"message":"no range"}]
;

fn expect_diagnostics_in_range(start: [2]usize, end: [2]usize, expected_messages: []const []const u8) !void {
    const diagnostics = try cbor.fromJsonAlloc(a, diagnostics_json);
    defer a.free(diagnostics);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_diagnostics_in_range(&result.writer, diagnostics, .{
        .start = .{ .line = start[0], .character = start[1] },
        .end = .{ .line = end[0], .character = end[1] },
    });

    var iter: []const u8 = result.written();
    var len = try cbor.decodeArrayHeader(&iter);
    try std.testing.expectEqual(expected_messages.len, len);
    var idx: usize = 0;
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        try std.testing.expect(try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic)));
        const json = try cbor.toJsonAlloc(a, diagnostic);
        defer a.free(json);
        const needle = try std.fmt.allocPrint(a, "\"message\":\"{s}\"", .{expected_messages[idx]});
        defer a.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
        idx += 1;
    }
}

test "diagnostics in range: cursor inside a diagnostic" {
    try expect_diagnostics_in_range(.{ 1, 6 }, .{ 1, 6 }, &.{"a"});
}

test "diagnostics in range: cursor at the diagnostic edges" {
    try expect_diagnostics_in_range(.{ 1, 4 }, .{ 1, 4 }, &.{"a"});
    try expect_diagnostics_in_range(.{ 1, 8 }, .{ 1, 8 }, &.{"a"});
}

test "diagnostics in range: cursor outside" {
    try expect_diagnostics_in_range(.{ 1, 3 }, .{ 1, 3 }, &.{});
    try expect_diagnostics_in_range(.{ 1, 9 }, .{ 1, 9 }, &.{});
    try expect_diagnostics_in_range(.{ 2, 0 }, .{ 2, 5 }, &.{});
}

test "diagnostics in range: selection over several diagnostics" {
    try expect_diagnostics_in_range(.{ 0, 0 }, .{ 4, 0 }, &.{ "a", "b" });
}

test "diagnostics in range: multi line diagnostic" {
    try expect_diagnostics_in_range(.{ 4, 20 }, .{ 4, 20 }, &.{"b"});
    try expect_diagnostics_in_range(.{ 5, 3 }, .{ 5, 3 }, &.{});
}

test "diagnostics in range: the raw diagnostic is preserved" {
    const diagnostics = try cbor.fromJsonAlloc(a, diagnostics_json);
    defer a.free(diagnostics);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_diagnostics_in_range(&result.writer, diagnostics, .{
        .start = .{ .line = 1, .character = 5 },
        .end = .{ .line = 1, .character = 5 },
    });
    const json = try cbor.toJsonAlloc(a, result.written());
    defer a.free(json);
    try std.testing.expectEqualStrings(
        \\[{"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":8}},"message":"a","data":{"x":1}}]
    , json);
}

fn read_capabilities(json: []const u8) !ServerCapabilities {
    const capabilities = try cbor.fromJsonAlloc(a, json);
    defer a.free(capabilities);
    return ServerCapabilities.read(a, capabilities);
}

test "server capabilities: none" {
    var capabilities = try read_capabilities("{\"hoverProvider\":true}");
    defer capabilities.deinit(a);
    try std.testing.expectEqual(.none, capabilities.code_action);
    try std.testing.expectEqual(0, capabilities.execute_commands.len);
}

const write_configuration = @import("project_manager").test_internal.write_configuration;

fn expect_configuration(settings_json: []const u8, params_json: []const u8, expected_json: []const u8) !void {
    const settings = if (settings_json.len > 0) try cbor.fromJsonAlloc(a, settings_json) else try a.dupe(u8, "");
    defer a.free(settings);
    const params = try cbor.fromJsonAlloc(a, params_json);
    defer a.free(params);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_configuration(&result.writer, settings, params);
    const json = try cbor.toJsonAlloc(a, result.written());
    defer a.free(json);
    try std.testing.expectEqualStrings(expected_json, json);
}

const nixd_settings =
    \\{"nixd":{"formatting":{"command":["nixfmt"]},"n":1},"other":true}
;

test "workspace configuration: sections" {
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"other\"}]}", "[true]");
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"nixd.formatting\"}]}", "[{\"command\":[\"nixfmt\"]}]");
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"nixd.formatting.command\"}]}", "[[\"nixfmt\"]]");
    try expect_configuration(nixd_settings, "{\"items\":[{\"scopeUri\":\"file:///x\",\"section\":\"nixd.n\"}]}", "[1]");
}

test "workspace configuration: missing paths give null" {
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"formatting\"}]}", "[null]");
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"nixd.missing\"}]}", "[null]");
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"other.deeper\"}]}", "[null]");
    try expect_configuration(nixd_settings, "{\"items\":[{\"section\":\"nixd.n.deeper\"}]}", "[null]");
}

test "workspace configuration: an item without a section gets everything" {
    try expect_configuration("{\"a\":1}", "{\"items\":[{}]}", "[{\"a\":1}]");
    try expect_configuration("{\"a\":1}", "{\"items\":[{\"scopeUri\":\"file:///x\"}]}", "[{\"a\":1}]");
}

test "workspace configuration: several items keep their order" {
    try expect_configuration(
        nixd_settings,
        "{\"items\":[{\"section\":\"nixd.n\"},{\"section\":\"missing\"},{\"section\":\"other\"}]}",
        "[1,null,true]",
    );
    try expect_configuration(nixd_settings, "{\"items\":[]}", "[]");
}

test "workspace configuration: no settings gives null for each item" {
    try expect_configuration("", "{\"items\":[{\"section\":\"nixd\"},{}]}", "[null,null]");
}

test "workspace configuration: invalid params" {
    const params = try cbor.fromJsonAlloc(a, "{\"other\":1}");
    defer a.free(params);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try std.testing.expectError(error.InvalidConfigurationParams, write_configuration(&result.writer, "", params));
}

test "server capabilities: text document sync" {
    const cases = [_]struct { []const u8, ServerCapabilities.TextDocumentSync }{
        .{ "{\"hoverProvider\":true}", .incremental },
        .{ "{\"textDocumentSync\":0}", .none },
        .{ "{\"textDocumentSync\":1}", .full },
        .{ "{\"textDocumentSync\":2}", .incremental },
        .{ "{\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":{\"includeText\":true}}}", .full },
        .{ "{\"textDocumentSync\":{\"change\":2,\"openClose\":true}}", .incremental },
        .{ "{\"textDocumentSync\":{\"openClose\":true}}", .none },
    };
    for (cases) |case| {
        var capabilities = try read_capabilities(case[0]);
        defer capabilities.deinit(a);
        try std.testing.expectEqual(case[1], capabilities.sync);
    }
}

test "server capabilities: boolean code action provider" {
    var capabilities = try read_capabilities("{\"codeActionProvider\":true}");
    defer capabilities.deinit(a);
    try std.testing.expectEqual(.actions, capabilities.code_action);

    var disabled = try read_capabilities("{\"codeActionProvider\":false}");
    defer disabled.deinit(a);
    try std.testing.expectEqual(.none, disabled.code_action);
}

test "server capabilities: code action options and commands" {
    var capabilities = try read_capabilities(
        \\{"codeActionProvider":{"codeActionKinds":["quickfix","refactor"],"resolveProvider":true},
        \\ "executeCommandProvider":{"commands":["a.fix","b.run"]}}
    );
    defer capabilities.deinit(a);
    try std.testing.expectEqual(.actions_with_resolve, capabilities.code_action);
    try std.testing.expect(capabilities.can_execute("b.run"));
    try std.testing.expect(!capabilities.can_execute("c.other"));

    var no_resolve = try read_capabilities("{\"codeActionProvider\":{\"codeActionKinds\":[]}}");
    defer no_resolve.deinit(a);
    try std.testing.expectEqual(.actions, no_resolve.code_action);
}

const write_code_actions = @import("project_manager").test_internal.write_code_actions;

fn expect_code_actions(json: []const u8, expected_json: []const u8) !void {
    const actions = try cbor.fromJsonAlloc(a, json);
    defer a.free(actions);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_code_actions(&result.writer, actions);
    const result_json = try cbor.toJsonAlloc(a, result.written());
    defer a.free(result_json);
    try std.testing.expectEqualStrings(expected_json, result_json);
}

test "code actions: empty" {
    try expect_code_actions("[]", "[]");
}

test "code actions: code action with all fields" {
    try expect_code_actions(
        \\[{"title":"Fix it","kind":"quickfix","isPreferred":true,"data":{"id":1}}]
    ,
        \\[["Fix it","quickfix","preferred","",{"title":"Fix it","kind":"quickfix","isPreferred":true,"data":{"id":1}}]]
    );
}

test "code actions: disabled action" {
    try expect_code_actions(
        \\[{"title":"Extract","kind":"refactor.extract","disabled":{"reason":"no selection"}}]
    ,
        \\[["Extract","refactor.extract","normal","no selection",{"title":"Extract","kind":"refactor.extract","disabled":{"reason":"no selection"}}]]
    );
}

test "code actions: command item" {
    try expect_code_actions(
        \\[{"title":"Run","command":"server.run","arguments":[1,"x"]}]
    ,
        \\[["Run","","normal","",{"title":"Run","command":"server.run","arguments":[1,"x"]}]]
    );
}

test "code actions: code action with an embedded command" {
    try expect_code_actions(
        \\[{"title":"Both","command":{"title":"Run","command":"server.run"},"edit":{"changes":{}}}]
    ,
        \\[["Both","","normal","",{"title":"Both","command":{"title":"Run","command":"server.run"},"edit":{"changes":{}}}]]
    );
}
