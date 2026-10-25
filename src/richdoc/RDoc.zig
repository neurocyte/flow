//! a rich text document

const std = @import("std");
const cbor = @import("cbor");
const rich_line = @import("rich_line.zig");

const Allocator = std.mem.Allocator;
const Style = rich_line.Style;
const Attrs = rich_line.Attrs;
const Span = rich_line.Span;

/// `["blocks", block...]`
raw: cbor.Raw = .empty,

const RDoc = @This();

pub const Wrap = enum { words, cells };

pub const Row = enum { none, head, body };

/// a block under construction
pub const BlockBuilder = struct {
    first_prefix: []const u8 = "",
    prefix: []const u8 = "",
    prefix_style: Style = .{},
    wrap: Wrap = .words,
    fill: []const u8 = "",
    space_before: u8 = 0,
    sloc: ?[2]usize = null,
    table: ?[]const []const u8 = null,
    row: Row = .none,
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    children: std.ArrayList(*@This()) = .empty,

    pub fn write(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try cbor.writeArrayHeader(writer, 4 + self.children.items.len);
        var count: usize = 1;
        if (self.first_prefix.len > 0) count += 1;
        if (self.prefix.len > 0) count += 1;
        const styled = self.first_prefix.len > 0 or self.prefix.len > 0 or self.fill.len > 0 or self.table != null;
        if (styled) count += 1;
        if (self.table) |_| count += 1;
        if (self.row != .none) count += 1;
        if (self.fill.len > 0) count += 1;
        if (self.space_before > 0) count += 1;
        if (self.sloc) |_| count += 1;
        try cbor.writeMapHeader(writer, count);
        if (self.first_prefix.len > 0) {
            try cbor.writeValue(writer, "first_prefix");
            try cbor.writeValue(writer, self.first_prefix);
        }
        if (self.prefix.len > 0) {
            try cbor.writeValue(writer, "prefix");
            try cbor.writeValue(writer, self.prefix);
        }
        if (styled) {
            try cbor.writeValue(writer, "prefix_style");
            try (Attrs{ .style = self.prefix_style }).write(writer);
        }
        try cbor.writeValue(writer, "wrap");
        try cbor.writeValue(writer, @tagName(self.wrap));
        if (self.fill.len > 0) {
            try cbor.writeValue(writer, "fill");
            try cbor.writeValue(writer, self.fill);
        }
        if (self.space_before > 0) {
            try cbor.writeValue(writer, "space_before");
            try cbor.writeValue(writer, self.space_before);
        }
        if (self.table) |columns| {
            try cbor.writeValue(writer, "table");
            try cbor.writeArrayHeader(writer, columns.len);
            for (columns) |column| try cbor.writeValue(writer, column);
        }
        if (self.row != .none) {
            try cbor.writeValue(writer, "row");
            try cbor.writeValue(writer, @tagName(self.row));
        }
        if (self.sloc) |sloc| {
            try cbor.writeValue(writer, "sloc");
            try cbor.writeArrayHeader(writer, 2);
            try cbor.writeValue(writer, sloc[0]);
            try cbor.writeValue(writer, sloc[1]);
        }
        try cbor.writeValue(writer, rich_line.display_width(self.text.items));
        try cbor.writeValue(writer, self.text.items);
        try cbor.writeArrayHeader(writer, self.spans.items.len);
        for (self.spans.items) |span| try rich_line.write_span(writer, span);
        for (self.children.items) |child| try child.write(writer);
    }

    /// encode the children of this block as the top level blocks
    pub fn encode(self: *const @This(), allocator: Allocator) error{OutOfMemory}!RDoc {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        self.write_top(&out.writer) catch return error.OutOfMemory;
        return .{ .raw = .{ .bytes = out.toOwnedSlice() catch return error.OutOfMemory } };
    }

    fn write_top(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try cbor.writeArrayHeader(writer, 1 + self.children.items.len);
        try cbor.writeValue(writer, "blocks");
        for (self.children.items) |child| try child.write(writer);
    }
};

// reader

pub const BlockReader = struct {
    attrs: cbor.Raw,
    display_width: usize,
    text: []const u8,
    spans: cbor.Raw,
    children: cbor.Raw,
    child_count: usize,

    pub fn iterate(self: @This()) BlockIterator {
        return .{ .iter = self.children.bytes, .remaining = self.child_count };
    }

    pub fn span_iterator(self: @This()) error{InvalidRichLine}!rich_line.SpanIterator {
        return rich_line.SpanIterator.init(self.spans);
    }

    fn attr(self: @This(), name: []const u8) ?cbor.Raw {
        var iter = self.attrs.bytes;
        var len = cbor.decodeMapHeader(&iter) catch return null;
        while (len > 0) : (len -= 1) {
            var key: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &key) catch return null)) return null;
            var value: cbor.Raw = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract(&value)) catch return null)) return null;
            if (std.mem.eql(u8, key, name)) return value;
        }
        return null;
    }

    fn attr_string(self: @This(), name: []const u8) []const u8 {
        var iter = (self.attr(name) orelse return "").bytes;
        var value: []const u8 = "";
        return if (cbor.matchString(&iter, &value) catch false) value else "";
    }

    pub fn first_prefix(self: @This()) []const u8 {
        return self.attr_string("first_prefix");
    }

    pub fn prefix(self: @This()) []const u8 {
        return self.attr_string("prefix");
    }

    pub fn fill(self: @This()) []const u8 {
        return self.attr_string("fill");
    }

    pub fn prefix_style(self: @This()) Style {
        var iter = (self.attr("prefix_style") orelse return .{}).bytes;
        return (Attrs.read(&iter) catch return .{}).style;
    }

    pub fn wrap(self: @This()) Wrap {
        return if (std.mem.eql(u8, self.attr_string("wrap"), "cells")) .cells else .words;
    }

    pub fn is_table(self: @This()) bool {
        return self.attr("table") != null;
    }

    pub const Align = enum { none, left, center, right };

    pub fn column_align(self: @This(), column: usize) Align {
        var iter = (self.attr("table") orelse return .none).bytes;
        const len = cbor.decodeArrayHeader(&iter) catch return .none;
        if (column >= len) return .none;
        for (0..column) |_| cbor.skipValue(&iter) catch return .none;
        var value: []const u8 = "";
        if (!(cbor.matchString(&iter, &value) catch false)) return .none;
        return std.meta.stringToEnum(Align, value) orelse .none;
    }

    pub fn row(self: @This()) Row {
        return std.meta.stringToEnum(Row, self.attr_string("row")) orelse .none;
    }

    pub fn space_before(self: @This()) usize {
        var iter = (self.attr("space_before") orelse return 0).bytes;
        var value: usize = 0;
        return if (cbor.matchInt(usize, &iter, &value) catch false) value else 0;
    }

    pub fn read(iter: *[]const u8) !BlockReader {
        const len = try cbor.decodeArrayHeader(iter);
        if (len < 4) return error.InvalidRichText;
        var attrs: cbor.Raw = undefined;
        if (!try cbor.matchValue(iter, cbor.extract(&attrs))) return error.InvalidRichText;
        var width: usize = 0;
        if (!try cbor.matchInt(usize, iter, &width)) return error.InvalidRichText;
        var text: []const u8 = undefined;
        if (!try cbor.matchString(iter, &text)) return error.InvalidRichText;
        var spans: cbor.Raw = undefined;
        if (!try cbor.matchValue(iter, cbor.extract(&spans))) return error.InvalidRichText;
        const start = iter.*;
        for (0..len - 4) |_| try cbor.skipValue(iter);
        return .{
            .attrs = attrs,
            .display_width = width,
            .text = text,
            .spans = spans,
            .children = .{ .bytes = start[0 .. start.len - iter.len] },
            .child_count = len - 4,
        };
    }
};

pub const BlockIterator = struct {
    iter: []const u8,
    remaining: usize,

    pub fn next(self: *@This()) error{InvalidRichText}!?BlockReader {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return BlockReader.read(&self.iter) catch error.InvalidRichText;
    }

    /// iterate the top level blocks of rich text
    pub fn root(doc: RDoc) error{InvalidRichText}!BlockIterator {
        var iter = doc.raw.bytes;
        const len = cbor.decodeArrayHeader(&iter) catch return error.InvalidRichText;
        if (len < 1) return error.InvalidRichText;
        var tag: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &tag) catch false) or !std.mem.eql(u8, tag, "blocks")) return error.InvalidRichText;
        return .{ .iter = iter, .remaining = len - 1 };
    }
};
