const std = @import("std");
const cbor = @import("cbor");
const SDoc = @import("SDoc.zig");
const RDoc = @import("RDoc.zig");

pub fn json(allocator: std.mem.Allocator, value: cbor.Raw) ![]const u8 {
    return cbor.toJsonPrettyAlloc(allocator, value.bytes);
}

pub const SExprOptions = struct {
    sloc: bool = false,
};

/// a structured document as an s-expression
pub fn sdoc_sexpr(writer: *std.Io.Writer, sdoc: SDoc, opts: SExprOptions) error{ WriteFailed, InvalidSDoc }!void {
    write_element(writer, try SDoc.Element.root(sdoc), opts) catch |e| return switch (e) {
        error.WriteFailed => error.WriteFailed,
        else => error.InvalidSDoc,
    };
}

pub fn sdoc_sexpr_alloc(allocator: std.mem.Allocator, sdoc: SDoc, opts: SExprOptions) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try sdoc_sexpr(&out.writer, sdoc, opts);
    return out.toOwnedSlice();
}

/// a rich text document as s-expressions:
/// `(block :first_prefix "• " :wrap "words" "text" (span 0 4 :bold true))`
pub fn rdoc_sexpr(writer: *std.Io.Writer, rdoc: RDoc, opts: SExprOptions) error{ WriteFailed, InvalidRDoc }!void {
    write_blocks(writer, rdoc, opts) catch |e| return switch (e) {
        error.WriteFailed => error.WriteFailed,
        else => error.InvalidRDoc,
    };
}

pub fn rdoc_sexpr_alloc(allocator: std.mem.Allocator, rdoc: RDoc, opts: SExprOptions) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try rdoc_sexpr(&out.writer, rdoc, opts);
    return out.toOwnedSlice();
}

fn write_blocks(writer: *std.Io.Writer, rdoc: RDoc, opts: SExprOptions) !void {
    try writer.writeAll("(blocks");
    var iter = try RDoc.BlockIterator.root(rdoc);
    while (try iter.next()) |block| try write_block(writer, block, opts);
    try writer.writeByte(')');
}

fn write_block(writer: *std.Io.Writer, block: RDoc.BlockReader, opts: SExprOptions) !void {
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
        if (!try cbor.matchString(&iter, &key)) return error.InvalidCbor;
        var value: cbor.Raw = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract(&value))) return error.InvalidCbor;
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

fn write_element(writer: *std.Io.Writer, elem: SDoc.Element, opts: SExprOptions) !void {
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
        if (!try cbor.matchValue(&iter, cbor.extract(&item))) return error.InvalidCbor;
        if (!first) try writer.writeByte(' ');
        first = false;
        try write_value(writer, item);
    }
    try writer.writeByte(']');
}
