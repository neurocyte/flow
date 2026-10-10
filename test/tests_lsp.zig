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
