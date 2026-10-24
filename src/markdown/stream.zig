//! convert a structured document to a rich text stream

const std = @import("std");
const cbor = @import("cbor");
const syntax = @import("syntax");
const syntax_validator = @import("syntax_validator");
const build_options = @import("build_options");
const document = @import("document.zig");
const rich_line = @import("rich_line.zig");

const Allocator = std.mem.Allocator;
const Style = rich_line.Style;
const Attrs = rich_line.Attrs;
const Span = rich_line.Span;

pub const FontStyle = enum { normal, bold, italic, underline, undercurl, strikethrough };

pub const Token = struct {
    fg: ?u24 = null,
    fs: ?FontStyle = null,
};

pub const Theme = struct {
    context: *const anyopaque,
    find: *const fn (context: *const anyopaque, scope: []const u8) ?Token,

    fn lookup(self: Theme, scope: []const u8) ?Token {
        return self.find(self.context, scope);
    }
};

pub const Options = struct {
    default_lang: ?[]const u8 = null,
    injection_depth: u8 = 2,
};

pub const Error = error{ OutOfMemory, InvalidDocument };

pub fn build(allocator: Allocator, doc: []const u8, theme: Theme, query_cache: *syntax.QueryCache, opts: Options) Error![]u8 {
    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    var builder: Builder = .{
        .allocator = allocator,
        .arena = arena_.allocator(),
        .theme = theme,
        .query_cache = query_cache,
        .opts = opts,
    };
    var top: Block = .{};
    try builder.blocks(&top, try document.root(doc), .container);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    write_stream(&out.writer, &top) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const Wrap = enum { words, cells };

const Block = struct {
    first_prefix: []const u8 = "",
    prefix: []const u8 = "",
    prefix_style: Style = .{},
    wrap: Wrap = .words,
    fill: []const u8 = "",
    space_before: u8 = 0,
    sloc: ?[2]usize = null,
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    children: std.ArrayList(*Block) = .empty,

    fn write(self: *const Block, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try cbor.writeArrayHeader(writer, 4 + self.children.items.len);
        var count: usize = 1;
        if (self.first_prefix.len > 0) count += 1;
        if (self.prefix.len > 0) count += 1;
        const styled = self.first_prefix.len > 0 or self.prefix.len > 0 or self.fill.len > 0;
        if (styled) count += 1;
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
};

fn write_stream(writer: *std.Io.Writer, top: *const Block) std.Io.Writer.Error!void {
    try cbor.writeArrayHeader(writer, 1 + top.children.items.len);
    try cbor.writeValue(writer, "blocks");
    for (top.children.items) |child| try child.write(writer);
}

const Spacing = enum {
    container,
    tight,
};

const Inline = struct {
    style: Style,
    link: []const u8 = "",
    sloc: ?[2]usize = null,
};

const Builder = struct {
    allocator: Allocator,
    arena: Allocator,
    theme: Theme,
    query_cache: *syntax.QueryCache,
    opts: Options,

    const Delta = struct {
        scopes: []const []const u8,
        bit: ?FontStyle = null,
    };

    fn delta_for(tag: []const u8) ?Delta {
        const eql = std.mem.eql;
        if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6')
            return .{ .scopes = &.{ "markup.heading", "text.title" }, .bit = .bold };
        if (eql(u8, tag, "strong")) return .{ .scopes = &.{ "markup.bold", "text.strong" }, .bit = .bold };
        if (eql(u8, tag, "em")) return .{ .scopes = &.{ "markup.italic", "text.emphasis" }, .bit = .italic };
        if (eql(u8, tag, "del")) return .{ .scopes = &.{"markup.strikethrough"}, .bit = .strikethrough };
        if (eql(u8, tag, "code") or eql(u8, tag, "pre")) return .{ .scopes = &.{ "markup.raw", "text.literal", "string" } };
        if (eql(u8, tag, "a")) return .{ .scopes = &.{ "markup.underline.link", "text.reference" }, .bit = .underline };
        if (eql(u8, tag, "html")) return .{ .scopes = &.{"comment"} };
        return null;
    }

    const list_prefix: Delta = .{ .scopes = &.{ "markup.list", "punctuation.special", "punctuation" } };
    const quote_prefix: Delta = .{ .scopes = &.{ "markup.quote", "punctuation.special", "comment" } };

    fn apply(self: *const Builder, base: Style, delta: Delta) Style {
        var style = base;
        for (delta.scopes) |scope| if (self.theme.lookup(scope)) |token| if (token.fg != null or token.fs != null) {
            if (token.fg) |fg| style.fg = rich_line.Color.rgbFromUint(fg);
            if (token.fs) |fs| add_bit(&style, fs);
            break;
        };
        if (delta.bit) |bit| add_bit(&style, bit);
        return style;
    }

    fn apply_tag(self: *const Builder, base: Style, tag: []const u8) Style {
        return if (delta_for(tag)) |delta| self.apply(base, delta) else base;
    }

    fn new_block(self: *const Builder, parent: *Block, elem: document.Element, spacing: Spacing) error{OutOfMemory}!*Block {
        const b = try self.arena.create(Block);
        b.* = .{
            .sloc = elem.sloc(),
            .space_before = if (parent.children.items.len > 0 and spacing == .container) 1 else 0,
        };
        try parent.children.append(self.arena, b);
        return b;
    }

    fn blocks(self: *Builder, parent: *Block, elem: document.Element, spacing: Spacing) Error!void {
        var iter = elem.iterate();
        while (try iter.next()) |child| switch (child) {
            .element => |e| try self.block(parent, e, spacing),
            .text => |t| {
                const b = try self.arena.create(Block);
                b.* = .{ .space_before = if (parent.children.items.len > 0 and spacing == .container) 1 else 0 };
                try parent.children.append(self.arena, b);
                try self.add_text(b, t, .{ .style = .{} });
            },
        };
    }

    fn block(self: *Builder, parent: *Block, elem: document.Element, spacing: Spacing) Error!void {
        const eql = std.mem.eql;
        const tag = elem.tag;
        if (eql(u8, tag, "blockquote")) {
            const b = try self.new_block(parent, elem, spacing);
            b.first_prefix = "▎ ";
            b.prefix = "▎ ";
            b.prefix_style = self.apply(.{}, quote_prefix);
            try self.blocks(b, elem, .container);
        } else if (eql(u8, tag, "ul") or eql(u8, tag, "ol")) {
            try self.list(parent, elem, spacing);
        } else if (eql(u8, tag, "pre")) {
            const b = try self.new_block(parent, elem, spacing);
            b.wrap = .cells;
            try self.code(b, elem);
        } else if (eql(u8, tag, "hr")) {
            const b = try self.new_block(parent, elem, spacing);
            b.fill = "─";
            b.prefix_style = self.apply(.{}, quote_prefix);
        } else if (eql(u8, tag, "html")) {
            const b = try self.new_block(parent, elem, spacing);
            b.wrap = .cells;
            try self.inlines(b, elem, .{ .style = self.apply_tag(.{}, tag), .sloc = elem.sloc() });
        } else {
            const b = try self.new_block(parent, elem, spacing);
            try self.inlines(b, elem, .{ .style = self.apply_tag(.{}, tag), .sloc = elem.sloc() });
        }
    }

    fn list(self: *Builder, parent: *Block, elem: document.Element, spacing: Spacing) Error!void {
        const container = try self.new_block(parent, elem, spacing);
        var number = elem.attr_uint("start") orelse 1;
        const ordered = elem.is("ol");
        const prefix_style = self.apply(.{}, list_prefix);
        var iter = elem.iterate();
        while (try iter.next()) |child| {
            const li = switch (child) {
                .element => |e| e,
                .text => continue,
            };
            const loose = is_loose_item(li);
            const item = try self.new_block(container, li, if (loose) .container else .tight);
            const marker = if (ordered) try std.fmt.allocPrint(self.arena, "{d}. ", .{number}) else "• ";
            number += 1;
            item.first_prefix = if (li.attr_bool("checked")) |checked|
                try std.mem.concat(self.arena, u8, &.{ marker, if (checked) "[x] " else "[ ] " })
            else
                marker;
            item.prefix = try self.spaces(rich_line.display_width(marker));
            item.prefix_style = prefix_style;
            try self.item_content(item, li, loose);
        }
    }

    fn is_loose_item(li: document.Element) bool {
        var iter = li.iterate();
        const first = (iter.next() catch return false) orelse return false;
        return first == .element and first.element.is("p");
    }

    fn item_content(self: *Builder, item: *Block, li: document.Element, loose: bool) Error!void {
        const base: Inline = .{ .style = .{}, .sloc = li.sloc() };
        var iter = li.iterate();
        while (try iter.next()) |child| switch (child) {
            .text => |t| try self.add_text(item, t, base),
            .element => |e| if (is_block_tag(e.tag))
                try self.block(item, e, if (loose) .container else .tight)
            else
                try self.inline_element(item, e, base),
        };
    }

    fn spaces(self: *const Builder, n: usize) error{OutOfMemory}![]const u8 {
        const s = try self.arena.alloc(u8, n);
        @memset(s, ' ');
        return s;
    }

    fn add_text(self: *const Builder, b: *Block, text: []const u8, in: Inline) error{OutOfMemory}!void {
        if (text.len == 0) return;
        const start = b.text.items.len;
        try b.text.appendSlice(self.arena, text);
        try b.spans.append(self.arena, .{
            .start = start,
            .end = b.text.items.len,
            .attrs = .{ .style = in.style, .link = in.link, .sloc = in.sloc },
        });
    }

    fn inlines(self: *Builder, b: *Block, elem: document.Element, in: Inline) Error!void {
        var iter = elem.iterate();
        while (try iter.next()) |child| switch (child) {
            .text => |t| try self.add_text(b, t, in),
            .element => |e| try self.inline_element(b, e, in),
        };
    }

    fn inline_element(self: *Builder, b: *Block, elem: document.Element, in: Inline) Error!void {
        const tag = elem.tag;
        if (elem.is("br")) {
            try b.text.append(self.arena, '\n');
        } else if (elem.is("img")) {
            try self.add_text(b, elem.attr_string("alt") orelse "", .{ .style = in.style, .link = in.link, .sloc = elem.sloc() });
        } else if (elem.is("a")) {
            const href = elem.attr_string("href") orelse "";
            try self.inlines(b, elem, .{
                .style = self.apply_tag(in.style, tag),
                .link = if (is_absolute_uri(href)) href else in.link,
                .sloc = elem.sloc(),
            });
        } else {
            try self.inlines(b, elem, .{ .style = self.apply_tag(in.style, tag), .link = in.link, .sloc = elem.sloc() });
        }
    }

    fn code(self: *Builder, b: *Block, elem: document.Element) Error!void {
        var iter = elem.iterate();
        const text = while (try iter.next()) |child| switch (child) {
            .text => |t| break t,
            .element => {},
        } else "";
        const base = self.apply_tag(.{}, "pre");
        const sloc = elem.sloc();
        const lang = elem.attr_string("lang") orelse self.opts.default_lang;
        try b.text.appendSlice(self.arena, text);
        if (text.len == 0) return;
        if (lang) |l| if (self.highlight(b, text, l, base, sloc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => false,
        }) return;
        try b.spans.append(self.arena, .{ .start = 0, .end = text.len, .attrs = .{ .style = base, .sloc = sloc } });
    }

    /// add highlight spans for `text`, false if the language is unknown
    fn highlight(self: *Builder, b: *Block, text: []const u8, lang: []const u8, base: Style, sloc: ?[2]usize) !bool {
        if (!build_options.use_tree_sitter) return false;
        const syn = create_syntax(self.allocator, lang, self.query_cache) orelse return false;
        defer syn.destroy();
        try syn.refresh_from_string(try self.arena.dupeSentinel(u8, text, 0));

        const Ctx = struct {
            builder: *Builder,
            base: Style,
            rank: []i64,
            styles: []Style,
            fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, _: u32, idx: usize, priority: i32, pattern_index: u32, _: *const syntax.Node) error{Stop}!void {
                if (idx > 0) return;
                const token = ctx.builder.theme.lookup(scope) orelse return;
                var style = ctx.base;
                if (token.fg) |fg| style.fg = rich_line.Color.rgbFromUint(fg);
                if (token.fs) |fs| add_bit(&style, fs);
                // nvim style ranking, as in the editor
                const rank: i64 = (@as(i64, priority) << 32) | @as(i64, pattern_index);
                const end = @min(range.end_byte, ctx.rank.len);
                for (@min(range.start_byte, end)..end) |i| {
                    if (rank < ctx.rank[i]) continue;
                    ctx.rank[i] = rank;
                    ctx.styles[i] = style;
                }
            }
        };
        var ctx: Ctx = .{
            .builder = self,
            .base = base,
            .rank = try self.arena.alloc(i64, text.len),
            .styles = try self.arena.alloc(Style, text.len),
        };
        @memset(ctx.rank, std.math.minInt(i64));
        @memset(ctx.styles, base);
        syn.render(&ctx, Ctx.cb, syntax_validator.Validator(*Ctx), null, self.opts.injection_depth) catch return false;

        var start: usize = 0;
        for (1..text.len + 1) |i| {
            if (i < text.len and ctx.styles[i].eql(ctx.styles[start])) continue;
            try b.spans.append(self.arena, .{ .start = start, .end = i, .attrs = .{ .style = ctx.styles[start], .sloc = sloc } });
            start = i;
        }
        return true;
    }
};

fn create_syntax(allocator: Allocator, lang: []const u8, query_cache: *syntax.QueryCache) ?*syntax {
    var buf: [32]u8 = undefined;
    if (lang.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, lang);
    return syntax.create_file_type_static(allocator, normalize_lang_name(lower), query_cache) catch null;
}

/// common code fence language aliases, as flow-syntax maps them for injections
fn normalize_lang_name(name: []const u8) []const u8 {
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "js", "javascript" }, .{ "kt", "kotlin" },      .{ "ts", "typescript" },
        .{ "py", "python" },     .{ "python3", "python" }, .{ "rb", "ruby" },
        .{ "sh", "bash" },       .{ "shell", "bash" },     .{ "zsh", "bash" },
        .{ "c++", "cpp" },       .{ "cs", "c-sharp" },     .{ "csharp", "c-sharp" },
        .{ "yml", "yaml" },      .{ "md", "markdown" },    .{ "rs", "rust" },
        .{ "golang", "go" },     .{ "console", "bash" },   .{ "jsonc", "json" },
    };
    for (aliases) |alias| if (std.mem.eql(u8, name, alias[0])) return alias[1];
    return name;
}

fn add_bit(style: *Style, fs: FontStyle) void {
    switch (fs) {
        .normal => {},
        .bold => style.bold = true,
        .italic => style.italic = true,
        .underline => style.ul_style = .single,
        .undercurl => style.ul_style = .curly,
        .strikethrough => style.strikethrough = true,
    }
}

fn is_block_tag(tag: []const u8) bool {
    const tags = [_][]const u8{ "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "pre", "hr", "html", "table" };
    for (tags) |t| if (std.mem.eql(u8, tag, t)) return true;
    return false;
}

fn is_absolute_uri(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(uri[0])) return false;
    for (uri[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    return true;
}

// reader

pub const BlockReader = struct {
    attrs: []const u8,
    display_width: usize,
    text: []const u8,
    spans: []const u8,
    children: []const u8,
    child_count: usize,

    pub fn iterate(self: BlockReader) BlockIterator {
        return .{ .iter = self.children, .remaining = self.child_count };
    }

    pub fn span_iterator(self: BlockReader) error{InvalidRichLine}!rich_line.SpanIterator {
        return rich_line.SpanIterator.init(self.spans);
    }

    fn attr(self: BlockReader, name: []const u8) ?[]const u8 {
        var iter = self.attrs;
        var len = cbor.decodeMapHeader(&iter) catch return null;
        while (len > 0) : (len -= 1) {
            var key: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &key) catch return null)) return null;
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch return null)) return null;
            if (std.mem.eql(u8, key, name)) return value;
        }
        return null;
    }

    fn attr_string(self: BlockReader, name: []const u8) []const u8 {
        var iter = self.attr(name) orelse return "";
        var value: []const u8 = "";
        return if (cbor.matchString(&iter, &value) catch false) value else "";
    }

    pub fn first_prefix(self: BlockReader) []const u8 {
        return self.attr_string("first_prefix");
    }

    pub fn prefix(self: BlockReader) []const u8 {
        return self.attr_string("prefix");
    }

    pub fn fill(self: BlockReader) []const u8 {
        return self.attr_string("fill");
    }

    pub fn prefix_style(self: BlockReader) Style {
        var iter = self.attr("prefix_style") orelse return .{};
        return (Attrs.read(&iter) catch return .{}).style;
    }

    pub fn wrap(self: BlockReader) Wrap {
        return if (std.mem.eql(u8, self.attr_string("wrap"), "cells")) .cells else .words;
    }

    pub fn space_before(self: BlockReader) usize {
        var iter = self.attr("space_before") orelse return 0;
        var value: usize = 0;
        return if (cbor.matchInt(usize, &iter, &value) catch false) value else 0;
    }
};

pub const BlockIterator = struct {
    iter: []const u8,
    remaining: usize,

    pub fn next(self: *BlockIterator) error{InvalidStream}!?BlockReader {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return read_block(&self.iter) catch error.InvalidStream;
    }
};

fn read_block(iter: *[]const u8) !BlockReader {
    const len = try cbor.decodeArrayHeader(iter);
    if (len < 4) return error.InvalidStream;
    var attrs: []const u8 = undefined;
    if (!try cbor.matchValue(iter, cbor.extract_cbor(&attrs))) return error.InvalidStream;
    var width: usize = 0;
    if (!try cbor.matchInt(usize, iter, &width)) return error.InvalidStream;
    var text: []const u8 = undefined;
    if (!try cbor.matchString(iter, &text)) return error.InvalidStream;
    var spans: []const u8 = undefined;
    if (!try cbor.matchValue(iter, cbor.extract_cbor(&spans))) return error.InvalidStream;
    const start = iter.*;
    for (0..len - 4) |_| try cbor.skipValue(iter);
    return .{
        .attrs = attrs,
        .display_width = width,
        .text = text,
        .spans = spans,
        .children = start[0 .. start.len - iter.len],
        .child_count = len - 4,
    };
}

/// iterate the top level blocks of a stream
pub fn read_blocks(stream: []const u8) error{InvalidStream}!BlockIterator {
    var iter = stream;
    const len = cbor.decodeArrayHeader(&iter) catch return error.InvalidStream;
    if (len < 1) return error.InvalidStream;
    var tag: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &tag) catch false) or !std.mem.eql(u8, tag, "blocks")) return error.InvalidStream;
    return .{ .iter = iter, .remaining = len - 1 };
}
