const std = @import("std");
const cbor = @import("cbor");
const document = @import("document.zig");

pub fn json(allocator: std.mem.Allocator, doc: []const u8) ![]const u8 {
    return cbor.toJsonPrettyAlloc(allocator, doc);
}

pub const SExprOptions = struct {
    sloc: bool = false,
};

/// a markdown document as an s-expression
pub fn sexpr(writer: *std.Io.Writer, doc: []const u8, opts: SExprOptions) !void {
    try write_element(writer, try document.root(doc), opts);
}

pub fn sexpr_alloc(allocator: std.mem.Allocator, doc: []const u8, opts: SExprOptions) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try sexpr(&out.writer, doc, opts);
    return out.toOwnedSlice();
}

fn write_element(writer: *std.Io.Writer, elem: document.Element, opts: SExprOptions) !void {
    try writer.print("({s}", .{elem.tag});
    var iter = elem.attrs;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var key: []const u8 = undefined;
        if (!try cbor.matchString(&iter, &key)) return error.InvalidDocument;
        var value: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&value))) return error.InvalidDocument;
        if (!opts.sloc and std.mem.eql(u8, key, "sloc")) continue;
        try writer.print(" :{s} ", .{key});
        try write_value(writer, value);
    }
    var children = elem.iterate();
    while (try children.next()) |child| switch (child) {
        .text => |t| try writer.print(" \"{f}\"", .{std.zig.fmtString(t)}),
        .element => |e| {
            try writer.writeByte(' ');
            try write_element(writer, e, opts);
        },
    };
    try writer.writeByte(')');
}

fn write_value(writer: *std.Io.Writer, value: []const u8) !void {
    var iter = value;
    var s: []const u8 = undefined;
    var n: u64 = 0;
    var b: bool = false;
    if (try cbor.matchString(&iter, &s)) return writer.print("\"{f}\"", .{std.zig.fmtString(s)});
    if (try cbor.matchInt(u64, &iter, &n)) return writer.print("{d}", .{n});
    if (try cbor.matchBool(&iter, &b)) return writer.print("{}", .{b});
    var len = try cbor.decodeArrayHeader(&iter);
    try writer.writeByte('[');
    var first = true;
    while (len > 0) : (len -= 1) {
        var item: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&item))) return error.InvalidDocument;
        if (!first) try writer.writeByte(' ');
        first = false;
        try write_value(writer, item);
    }
    try writer.writeByte(']');
}
