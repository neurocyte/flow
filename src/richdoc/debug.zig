const std = @import("std");
const cbor = @import("cbor");
const document = @import("document.zig");
const rich_text = @import("rich_text.zig");

pub fn json(allocator: std.mem.Allocator, value: cbor.Raw) ![]const u8 {
    return cbor.toJsonPrettyAlloc(allocator, value.bytes);
}

pub const SExprOptions = struct {
    sloc: bool = false,
};

/// a structured document as an s-expression
pub fn sexpr(writer: *std.Io.Writer, doc: document.Document, opts: SExprOptions) !void {
    try write_element(writer, try document.Element.root(doc), opts);
}

pub fn sexpr_alloc(allocator: std.mem.Allocator, doc: document.Document, opts: SExprOptions) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try sexpr(&out.writer, doc, opts);
    return out.toOwnedSlice();
}

/// rich text as s-expressions:
/// `(block :first_prefix "• " :wrap "words" "text" (span 0 4 :bold true))`
pub fn rich_text_sexpr(writer: *std.Io.Writer, text: rich_text.RichText, opts: SExprOptions) !void {
    try writer.writeAll("(blocks");
    var iter = try rich_text.read_blocks(text);
    while (try iter.next()) |block| try write_block(writer, block, opts);
    try writer.writeByte(')');
}

pub fn rich_text_sexpr_alloc(allocator: std.mem.Allocator, text: rich_text.RichText, opts: SExprOptions) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try rich_text_sexpr(&out.writer, text, opts);
    return out.toOwnedSlice();
}

fn write_block(writer: *std.Io.Writer, block: rich_text.BlockReader, opts: SExprOptions) !void {
    try writer.writeAll(" (block");
    try write_map(writer, block.attrs, opts);
    try writer.print(" :width {d} \"{f}\"", .{ block.display_width, std.zig.fmtString(block.text) });
    const spans = try block.span_iterator();
    var iter = spans.iter;
    for (0..spans.remaining) |_| {
        _ = try cbor.decodeArrayHeader(&iter);
        var start: usize = 0;
        var end: usize = 0;
        _ = try cbor.matchInt(usize, &iter, &start);
        _ = try cbor.matchInt(usize, &iter, &end);
        var attrs: cbor.Raw = undefined;
        _ = try cbor.matchValue(&iter, cbor.extract(&attrs));
        try writer.print(" (span {d} {d}", .{ start, end });
        try write_map(writer, attrs, opts);
        try writer.writeByte(')');
    }
    var children = block.iterate();
    while (try children.next()) |child| try write_block(writer, child, opts);
    try writer.writeByte(')');
}

fn write_map(writer: *std.Io.Writer, map: cbor.Raw, opts: SExprOptions) !void {
    var iter = map.bytes;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var key: []const u8 = undefined;
        if (!try cbor.matchString(&iter, &key)) return error.InvalidDocument;
        var value: cbor.Raw = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract(&value))) return error.InvalidDocument;
        if (!opts.sloc and std.mem.eql(u8, key, "sloc")) continue;
        try writer.print(" :{s} ", .{key});
        var color: u24 = 0;
        var color_iter = value.bytes;
        if (is_color_key(key) and try cbor.matchInt(u24, &color_iter, &color)) {
            try writer.print("0x{x:0>6}", .{color});
        } else if (value.bytes.len > 0 and value.bytes[0] >> 5 == 5) {
            try writer.writeByte('{');
            try write_map(writer, value, opts);
            try writer.writeAll(" }");
        } else try write_value(writer, value);
    }
}

fn is_color_key(key: []const u8) bool {
    return std.mem.eql(u8, key, "fg") or std.mem.eql(u8, key, "bg") or std.mem.eql(u8, key, "ul");
}

fn write_element(writer: *std.Io.Writer, elem: document.Element, opts: SExprOptions) !void {
    try writer.print("({s}", .{elem.tag});
    try write_map(writer, elem.attrs, opts);
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

fn write_value(writer: *std.Io.Writer, value: cbor.Raw) !void {
    var iter = value.bytes;
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
        var item: cbor.Raw = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract(&item))) return error.InvalidDocument;
        if (!first) try writer.writeByte(' ');
        first = false;
        try write_value(writer, item);
    }
    try writer.writeByte(']');
}
