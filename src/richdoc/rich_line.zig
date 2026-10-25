//! rich line: `[display_width, text, spans]`, with `span = [start, end, attrs]`

const std = @import("std");
const cbor = @import("cbor");
const vaxis = @import("vaxis");

pub const Style = vaxis.Cell.Style;
pub const Color = vaxis.Cell.Color;

pub const Attrs = struct {
    style: Style = .{},
    link: []const u8 = "",
    link_id: []const u8 = "",
    sloc: ?[2]usize = null,

    pub fn write(self: Attrs, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    pub fn read(iter: *[]const u8) error{InvalidRichLine}!Attrs {
        return read_(iter) catch error.InvalidRichLine;
    }

    fn read_(iter: *[]const u8) !Attrs {
        var self: Attrs = .{};
        var len = try cbor.decodeMapHeader(iter);
        while (len > 0) : (len -= 1) {
            var key: []const u8 = undefined;
            if (!try cbor.matchString(iter, &key)) return error.InvalidRichLine;
            if (std.mem.eql(u8, key, "fg")) {
                self.style.fg = try read_color(iter);
            } else if (std.mem.eql(u8, key, "bg")) {
                self.style.bg = try read_color(iter);
            } else if (std.mem.eql(u8, key, "ul")) {
                self.style.ul = try read_color(iter);
            } else if (std.mem.eql(u8, key, "ul_style")) {
                var value: u8 = 0;
                if (!try cbor.matchInt(u8, iter, &value)) return error.InvalidRichLine;
                self.style.ul_style = std.enums.fromInt(Style.Underline, value) orelse .off;
            } else if (std.mem.eql(u8, key, "link")) {
                if (!try cbor.matchString(iter, &self.link)) return error.InvalidRichLine;
            } else if (std.mem.eql(u8, key, "link_id")) {
                if (!try cbor.matchString(iter, &self.link_id)) return error.InvalidRichLine;
            } else if (std.mem.eql(u8, key, "sloc")) {
                var start: usize = 0;
                var end: usize = 0;
                if (!try cbor.matchValue(iter, .{ cbor.extract(&start), cbor.extract(&end) })) return error.InvalidRichLine;
                self.sloc = .{ start, end };
            } else if (bool_key(key)) |field| {
                var value: bool = false;
                if (!try cbor.matchBool(iter, &value)) return error.InvalidRichLine;
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
};

pub fn write_span(writer: *std.Io.Writer, span: Span) std.Io.Writer.Error!void {
    try cbor.writeArrayHeader(writer, 3);
    try cbor.writeValue(writer, span.start);
    try cbor.writeValue(writer, span.end);
    try span.attrs.write(writer);
}

pub const SpanIterator = struct {
    iter: []const u8,
    remaining: usize,

    pub fn init(spans: cbor.Raw) error{InvalidRichLine}!SpanIterator {
        var iter = spans.bytes;
        const len = cbor.decodeArrayHeader(&iter) catch return error.InvalidRichLine;
        return .{ .iter = iter, .remaining = len };
    }

    pub fn next(self: *SpanIterator) error{InvalidRichLine}!?Span {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const len = cbor.decodeArrayHeader(&self.iter) catch return error.InvalidRichLine;
        if (len != 3) return error.InvalidRichLine;
        var start: usize = 0;
        var end: usize = 0;
        if (!(cbor.matchInt(usize, &self.iter, &start) catch false)) return error.InvalidRichLine;
        if (!(cbor.matchInt(usize, &self.iter, &end) catch false)) return error.InvalidRichLine;
        return .{ .start = start, .end = end, .attrs = try Attrs.read(&self.iter) };
    }
};

/// the width in cells of the widest line of `text`
pub fn display_width(text: []const u8) usize {
    var width: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| width = @max(width, vaxis.gwidth.gwidth(line, .unicode));
    return width;
}

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
    try write_span(&out.writer, .{ .start = 0, .end = 2, .attrs = .{ .style = .{ .italic = true } } });
    try write_span(&out.writer, .{ .start = 2, .end = 5, .attrs = .{} });
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
