//! a rich text document
//!
//! A block is `[attrs, display_width, text, spans, child...]`, with
//! `span = [start, end, attrs]`.

const std = @import("std");
const cbor = @import("cbor");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

pub const Style = vaxis.Cell.Style;
pub const Color = vaxis.Cell.Color;

/// `["blocks", block...]`
raw: cbor.Raw = .empty,

const RDoc = @This();

pub const Wrap = enum { words, cells };

pub const Row = enum { none, head, body };

pub const Attrs = struct {
    style: Style = .{},
    link: []const u8 = "",
    link_id: []const u8 = "",
    sloc: ?[2]usize = null,

    pub fn write(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = self.style;
        var count: usize = 0;
        if (s.fg != .default) count += 1;
        if (s.bg != .default) count += 1;
        if (s.ul != .default) count += 1;
        if (s.ul_style != .off) count += 1;
        inline for (bool_keys) |key| {
            if (@field(s, key)) count += 1;
        }
        if (self.link.len > 0) count += 1;
        if (self.link_id.len > 0) count += 1;
        if (self.sloc) |_| count += 1;

        try cbor.writeMapHeader(writer, count);
        if (s.fg != .default) try write_color(writer, "fg", s.fg);
        if (s.bg != .default) try write_color(writer, "bg", s.bg);
        if (s.ul != .default) try write_color(writer, "ul", s.ul);
        if (s.ul_style != .off) {
            try cbor.writeValue(writer, "ul_style");
            try cbor.writeValue(writer, @backingInt(s.ul_style));
        }
        inline for (bool_keys) |key| if (@field(s, key)) {
            try cbor.writeValue(writer, key);
            try cbor.writeValue(writer, true);
        };
        if (self.link.len > 0) {
            try cbor.writeValue(writer, "link");
            try cbor.writeValue(writer, self.link);
        }
        if (self.link_id.len > 0) {
            try cbor.writeValue(writer, "link_id");
            try cbor.writeValue(writer, self.link_id);
        }
        if (self.sloc) |sloc| {
            try cbor.writeValue(writer, "sloc");
            try cbor.writeArrayHeader(writer, 2);
            try cbor.writeValue(writer, sloc[0]);
            try cbor.writeValue(writer, sloc[1]);
        }
    }

    pub fn read(iter: *[]const u8) error{InvalidRichText}!Attrs {
        return read_(iter) catch error.InvalidRichText;
    }

    fn read_(iter: *[]const u8) !Attrs {
        var self: Attrs = .{};
        var len = try cbor.decodeMapHeader(iter);
        while (len > 0) : (len -= 1) {
            var key: []const u8 = undefined;
            if (!try cbor.matchString(iter, &key)) return error.InvalidRichText;
            if (std.mem.eql(u8, key, "fg")) {
                self.style.fg = try read_color(iter);
            } else if (std.mem.eql(u8, key, "bg")) {
                self.style.bg = try read_color(iter);
            } else if (std.mem.eql(u8, key, "ul")) {
                self.style.ul = try read_color(iter);
            } else if (std.mem.eql(u8, key, "ul_style")) {
                var value: u8 = 0;
                if (!try cbor.matchInt(u8, iter, &value)) return error.InvalidRichText;
                self.style.ul_style = std.enums.fromInt(Style.Underline, value) orelse .off;
            } else if (std.mem.eql(u8, key, "link")) {
                if (!try cbor.matchString(iter, &self.link)) return error.InvalidRichText;
            } else if (std.mem.eql(u8, key, "link_id")) {
                if (!try cbor.matchString(iter, &self.link_id)) return error.InvalidRichText;
            } else if (std.mem.eql(u8, key, "sloc")) {
                var start: usize = 0;
                var end: usize = 0;
                if (!try cbor.matchValue(iter, .{ cbor.extract(&start), cbor.extract(&end) })) return error.InvalidRichText;
                self.sloc = .{ start, end };
            } else if (bool_key(key)) |field| {
                var value: bool = false;
                if (!try cbor.matchBool(iter, &value)) return error.InvalidRichText;
                set_bool(&self.style, field, value);
            } else {
                try cbor.skipValue(iter);
            }
        }
        return self;
    }
};

const bool_keys = [_][]const u8{ "bold", "dim", "italic", "blink", "reverse", "invisible", "strikethrough" };

fn bool_key(key: []const u8) ?usize {
    for (bool_keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
    return null;
}

fn set_bool(style: *Style, field: usize, value: bool) void {
    inline for (bool_keys, 0..) |key, i| if (i == field) {
        @field(style, key) = value;
    };
}

fn write_color(writer: *std.Io.Writer, key: []const u8, color: Color) std.Io.Writer.Error!void {
    try cbor.writeValue(writer, key);
    switch (color) {
        .default => try cbor.writeValue(writer, null),
        .rgb => |rgb| try cbor.writeValue(writer, @as(u24, rgb[0]) << 16 | @as(u24, rgb[1]) << 8 | rgb[2]),
        .index => |index| {
            try cbor.writeArrayHeader(writer, 1);
            try cbor.writeValue(writer, index);
        },
    }
}

fn read_color(iter: *[]const u8) !Color {
    var rgb: u24 = 0;
    if (try cbor.matchInt(u24, iter, &rgb)) return Color.rgbFromUint(rgb);
    var index: u8 = 0;
    if (try cbor.matchValue(iter, .{cbor.extract(&index)})) return .{ .index = index };
    try cbor.skipValue(iter);
    return .default;
}

pub const Span = struct {
    start: usize,
    end: usize,
    attrs: Attrs,

    pub fn write(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try cbor.writeArrayHeader(writer, 3);
        try cbor.writeValue(writer, self.start);
        try cbor.writeValue(writer, self.end);
        try self.attrs.write(writer);
    }
};

/// the width in cells of the widest line of `text`
pub fn display_width(text: []const u8) usize {
    var width: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| width = @max(width, vaxis.gwidth.gwidth(line, .unicode));
    return width;
}

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
        try cbor.writeValue(writer, display_width(self.text.items));
        try cbor.writeValue(writer, self.text.items);
        try cbor.writeArrayHeader(writer, self.spans.items.len);
        for (self.spans.items) |span| try span.write(writer);
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

    pub fn span_iterator(self: @This()) error{InvalidRichText}!SpanIterator {
        return SpanIterator.init(self.spans);
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

pub const SpanIterator = struct {
    iter: []const u8,
    remaining: usize,

    pub fn init(spans: cbor.Raw) error{InvalidRichText}!SpanIterator {
        var iter = spans.bytes;
        const len = cbor.decodeArrayHeader(&iter) catch return error.InvalidRichText;
        return .{ .iter = iter, .remaining = len };
    }

    pub fn next(self: *@This()) error{InvalidRichText}!?Span {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const len = cbor.decodeArrayHeader(&self.iter) catch return error.InvalidRichText;
        if (len != 3) return error.InvalidRichText;
        var start: usize = 0;
        var end: usize = 0;
        if (!(cbor.matchInt(usize, &self.iter, &start) catch false)) return error.InvalidRichText;
        if (!(cbor.matchInt(usize, &self.iter, &end) catch false)) return error.InvalidRichText;
        return .{ .start = start, .end = end, .attrs = try Attrs.read(&self.iter) };
    }
};

test "attrs round trip" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const attrs: Attrs = .{
        .style = .{
            .fg = .{ .rgb = .{ 0x12, 0x34, 0x56 } },
            .bg = .{ .index = 4 },
            .ul = .{ .rgb = .{ 1, 2, 3 } },
            .ul_style = .curly,
            .bold = true,
            .dim = true,
            .italic = true,
            .blink = true,
            .reverse = true,
            .invisible = true,
            .strikethrough = true,
        },
        .link = "http://x",
        .link_id = "id1",
        .sloc = .{ 3, 9 },
    };
    try attrs.write(&out.writer);
    var iter: []const u8 = out.written();
    const read = try Attrs.read(&iter);
    try std.testing.expect(read.style.eql(attrs.style));
    try std.testing.expectEqualStrings("http://x", read.link);
    try std.testing.expectEqualStrings("id1", read.link_id);
    try std.testing.expectEqual(attrs.sloc, read.sloc);
    try std.testing.expectEqual(0, iter.len);
}

test "default attrs are an empty map and unknown keys are skipped" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Attrs{}).write(&writer);
    try std.testing.expectEqualSlices(u8, &.{0xa0}, writer.buffered());

    var iter: []const u8 = cbor.fmt(&buf, .{ .other = 1, .bold = true });
    const read = try Attrs.read(&iter);
    try std.testing.expect(read.style.bold);
}

test "spans" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cbor.writeArrayHeader(&out.writer, 2);
    try (Span{ .start = 0, .end = 2, .attrs = .{ .style = .{ .italic = true } } }).write(&out.writer);
    try (Span{ .start = 2, .end = 5, .attrs = .{} }).write(&out.writer);
    var spans = try SpanIterator.init(.{ .bytes = out.written() });
    const a = (try spans.next()).?;
    try std.testing.expect(a.attrs.style.italic);
    const b = (try spans.next()).?;
    try std.testing.expectEqual(5, b.end);
    try std.testing.expectEqual(null, try spans.next());
}

test "display width" {
    try std.testing.expectEqual(5, display_width("ab\nabcde\n"));
    try std.testing.expectEqual(4, display_width("日本"));
}
