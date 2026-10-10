const std = @import("std");
const cbor = @import("cbor");
const write_workspace_edit = @import("project_manager").test_internal.write_workspace_edit;

const a = std.testing.allocator;

fn expect_workspace_edit(json: []const u8, expected_json: []const u8) !void {
    const workspace_edit = try cbor.fromJsonAlloc(a, json);
    defer a.free(workspace_edit);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try write_workspace_edit(&result.writer, workspace_edit);
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
        \\[["/src/a.zig",null,[[1,2,1,5,"foo"],[7,0,8,0,""]]],["/src/b.zig",null,[[0,0,0,0,"bar\n"]]]]
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
        \\[["/src/a.zig",4,[[1,2,1,5,"foo"]]],["/src/b.zig",null,[[3,0,3,1,"x"]]]]
    );
}

test "workspace edit: documentChanges is preferred over changes" {
    try expect_workspace_edit(
        \\{"changes":{"file:///src/a.zig":[]},
        \\ "documentChanges":[{"textDocument":{"uri":"file:///src/b.zig","version":1},"edits":[]}]}
    ,
        \\[["/src/b.zig",1,[]]]
    );
}

test "workspace edit: resource operations are skipped" {
    try expect_workspace_edit(
        \\{"documentChanges":[
        \\  {"kind":"create","uri":"file:///src/new.zig"},
        \\  {"textDocument":{"uri":"file:///src/new.zig","version":null},"edits":[
        \\    {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]},
        \\  {"kind":"rename","oldUri":"file:///src/a.zig","newUri":"file:///src/b.zig"},
        \\  {"kind":"delete","uri":"file:///src/c.zig"}
        \\]}
    ,
        \\[["/src/new.zig",null,[[0,0,0,0,"x"]]]]
    );
}

test "workspace edit: percent encoded uri" {
    try expect_workspace_edit(
        \\{"changes":{"file:///src/a%20b.zig":[]}}
    ,
        \\[["/src/a b.zig",null,[]]]
    );
}

test "workspace edit: neither changes nor documentChanges" {
    const workspace_edit = try cbor.fromJsonAlloc(a, "{}");
    defer a.free(workspace_edit);
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    try std.testing.expectError(error.InvalidWorkspaceEdit, write_workspace_edit(&result.writer, workspace_edit));
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
