//! render documents as rich text

const std = @import("std");
const syntax = @import("syntax");
const syntax_validator = @import("syntax_validator");
const build_options = @import("build_options");
const SDoc = @import("SDoc.zig");
const RDoc = @import("RDoc.zig");
const RDocLayout = @import("RDocLayout.zig");

const Allocator = std.mem.Allocator;
const Style = RDoc.Style;
const BlockBuilder = RDoc.BlockBuilder;

const render = @This();

pub const FontStyle = enum { normal, bold, italic, underline, undercurl, strikethrough };

pub const Token = struct {
    fg: ?u24 = null,
    fs: ?FontStyle = null,
};

pub const Theme = struct {
    context: *const anyopaque,
    find: *const fn (context: *const anyopaque, scope: []const u8) ?Token,

    fn lookup(self: @This(), scope: []const u8) ?Token {
        return self.find(self.context, scope);
    }
};

pub const Options = struct {
    default_lang: ?[]const u8 = null,
    injection_depth: u8 = 2,
};

pub const Error = error{ OutOfMemory, InvalidSDoc };

/// render a structured document as rich text
pub fn from_sdoc(allocator: Allocator, doc: SDoc, theme: Theme, query_cache: *syntax.QueryCache, opts: Options) Error!RDoc {
    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    var builder: Builder = .{
        .allocator = allocator,
        .arena = arena_.allocator(),
        .theme = theme,
        .query_cache = query_cache,
        .opts = opts,
    };
    var top: BlockBuilder = .{};
    try builder.blocks(&top, try SDoc.Element.root(doc), .container);
    return top.encode(allocator);
}

pub const CodeOverflow = enum { wrap, clip };

pub const LayoutOptions = struct {
    width: usize,
    tab_width: usize,
    code_overflow: CodeOverflow = .wrap,
};

/// lay out rich text in lines of `opts.width` cells, appended to `layout`
/// `metrics` measures graphemes with `egc_length(text, &cols, col, tab_width)`
pub fn to_layout(layout: *RDocLayout, rdoc: RDoc, metrics: anytype, opts: LayoutOptions) error{ OutOfMemory, InvalidRDoc }!void {
    var builder: LayoutBuilder(@TypeOf(metrics)) = .{
        .layout = layout,
        .arena = layout.allocator(),
        .metrics = metrics,
        .width = @max(1, opts.width),
        .tab_width = opts.tab_width,
        .code_overflow = opts.code_overflow,
    };
    var blocks = try RDoc.BlockIterator.root(rdoc);
    while (try blocks.next()) |block| try builder.block(block);
}

pub const PlaneOptions = struct {
    /// links drawn as terminal hyperlinks (OSC 8)
    terminal_link: *const fn (href: []const u8) bool = no_terminal_links,
    underline_links: bool = false,

    fn no_terminal_links(_: []const u8) bool {
        return false;
    }
};

/// draw the lines of `layout` from `first_row` on, at most `rows`, styled over `base`
pub fn to_plane(layout: *const RDocLayout, plane: anytype, first_row: usize, rows: usize, first_col: usize, base: Style, opts: PlaneOptions) void {
    defer plane.style = base;
    const lines = layout.lines.items;
    for (lines[@min(first_row, lines.len)..], 0..) |line, row| {
        if (row >= rows) break;
        plane.cursor_move_yx(@intCast(row), @intCast(first_col));
        for (line.runs) |run| write_run(plane, base, run, opts);
    }
}

/// the link at cell `col` of layout line `line`, measured with `metrics` as in `to_layout`
pub fn link_at(layout: *const RDocLayout, line: usize, col: usize, metrics: anytype) ?[]const u8 {
    const lines = layout.lines.items;
    if (line >= lines.len) return null;
    var x: usize = 0;
    for (lines[line].runs) |run| {
        const w = text_width(metrics, run.text, x, 1); // tabs are expanded in the layout
        if (col < x + w) return if (run.attrs.link.len > 0) run.attrs.link else null;
        x += w;
    }
    return null;
}

/// the width in cells of `text` from `start_col`, measured with `metrics`
pub fn text_width(metrics: anytype, text: []const u8, start_col: usize, tab_width: usize) usize {
    var col = start_col;
    var i: usize = 0;
    while (i < text.len) {
        var cols: usize = 0;
        i += metrics.egc_length(text[i..], &cols, col, tab_width);
        col += cols;
    }
    return col - start_col;
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

        fn for_tag(tag: []const u8) ?@This() {
            const eql = std.mem.eql;
            if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6')
                return .{ .scopes = &.{ "markup.heading", "text.title" }, .bit = .bold };
            if (eql(u8, tag, "strong")) return .{ .scopes = &.{ "markup.bold", "text.strong" }, .bit = .bold };
            if (eql(u8, tag, "em")) return .{ .scopes = &.{ "markup.italic", "text.emphasis" }, .bit = .italic };
            if (eql(u8, tag, "del")) return .{ .scopes = &.{"markup.strikethrough"}, .bit = .strikethrough };
            if (eql(u8, tag, "code") or eql(u8, tag, "pre")) return .{ .scopes = &.{ "markup.raw", "text.literal", "string" } };
            if (eql(u8, tag, "a")) return .{ .scopes = &.{ "markup.underline.link", "text.reference" } };
            if (eql(u8, tag, "html")) return .{ .scopes = &.{"comment"} };
            if (eql(u8, tag, "th")) return .{ .scopes = &.{}, .bit = .bold };
            return null;
        }
    };

    const list_prefix: Delta = .{ .scopes = &.{ "markup.list", "punctuation.special", "punctuation" } };
    const quote_prefix: Delta = .{ .scopes = &.{ "markup.quote", "punctuation.special", "comment" } };

    fn apply(self: *const @This(), base: Style, delta: Delta) Style {
        var style = base;
        for (delta.scopes) |scope| if (self.theme.lookup(scope)) |token| if (token.fg != null or token.fs != null) {
            if (token.fg) |fg| style.fg = RDoc.Color.rgbFromUint(fg);
            if (token.fs) |fs| add_bit(&style, fs);
            break;
        };
        if (delta.bit) |bit| add_bit(&style, bit);
        return style;
    }

    fn apply_tag(self: *const @This(), base: Style, tag: []const u8) Style {
        return if (Delta.for_tag(tag)) |delta| self.apply(base, delta) else base;
    }

    fn new_block(self: *const @This(), parent: *BlockBuilder, elem: SDoc.Element, spacing: Spacing) error{OutOfMemory}!*BlockBuilder {
        const b = try self.arena.create(BlockBuilder);
        b.* = .{
            .sloc = elem.sloc(),
            .src_row = elem.src_row(),
            .space_before = if (parent.children.items.len > 0 and spacing == .container) 1 else 0,
        };
        try parent.children.append(self.arena, b);
        return b;
    }

    fn blocks(self: *@This(), parent: *BlockBuilder, elem: SDoc.Element, spacing: Spacing) Error!void {
        var iter = elem.iterate();
        while (try iter.next()) |child| switch (child) {
            .element => |e| try self.block(parent, e, spacing),
            .text => |t| {
                const b = try self.arena.create(BlockBuilder);
                b.* = .{ .space_before = if (parent.children.items.len > 0 and spacing == .container) 1 else 0 };
                try parent.children.append(self.arena, b);
                try self.add_text(b, t, .{ .style = .{} });
            },
        };
    }

    fn block(self: *@This(), parent: *BlockBuilder, elem: SDoc.Element, spacing: Spacing) Error!void {
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
        } else if (eql(u8, tag, "table")) {
            try self.table(parent, elem, spacing);
        } else if (eql(u8, tag, "html")) {
            const b = try self.new_block(parent, elem, spacing);
            b.wrap = .cells;
            try self.inlines(b, elem, .{ .style = self.apply_tag(.{}, tag), .sloc = elem.sloc() });
        } else {
            const b = try self.new_block(parent, elem, spacing);
            try self.inlines(b, elem, .{ .style = self.apply_tag(.{}, tag), .sloc = elem.sloc() });
        }
    }

    fn list(self: *@This(), parent: *BlockBuilder, elem: SDoc.Element, spacing: Spacing) Error!void {
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
            item.prefix = try self.spaces(RDoc.display_width(marker));
            item.prefix_style = prefix_style;
            try self.item_content(item, li, loose);
        }
    }

    fn table(self: *@This(), parent: *BlockBuilder, elem: SDoc.Element, spacing: Spacing) Error!void {
        const b = try self.new_block(parent, elem, spacing);
        b.wrap = .cells;
        b.prefix_style = self.apply(.{}, list_prefix);
        var columns: std.ArrayList([]const u8) = .empty;
        var sections = elem.iterate();
        while (try sections.next()) |section_| {
            const section = switch (section_) {
                .element => |e| e,
                .text => continue,
            };
            const kind: RDoc.Row = if (section.is("thead")) .head else .body;
            var rows = section.iterate();
            while (try rows.next()) |row_| {
                const tr = switch (row_) {
                    .element => |e| e,
                    .text => continue,
                };
                const row = try self.new_block(b, tr, .tight);
                row.row = kind;
                row.wrap = .cells;
                var cells = tr.iterate();
                var column: usize = 0;
                while (try cells.next()) |cell_| {
                    const cell = switch (cell_) {
                        .element => |e| e,
                        .text => continue,
                    };
                    if (column >= columns.items.len) try columns.append(self.arena, cell.attr_string("align") orelse "");
                    column += 1;
                    const c = try self.new_block(row, cell, .tight);
                    c.wrap = .cells;
                    try self.inlines(c, cell, .{ .style = self.apply_tag(.{}, cell.tag), .sloc = cell.sloc() });
                }
            }
        }
        b.table = columns.items;
    }

    fn is_loose_item(li: SDoc.Element) bool {
        var iter = li.iterate();
        const first = (iter.next() catch return false) orelse return false;
        return first == .element and first.element.is("p");
    }

    fn item_content(self: *@This(), item: *BlockBuilder, li: SDoc.Element, loose: bool) Error!void {
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

    fn spaces(self: *const @This(), n: usize) error{OutOfMemory}![]const u8 {
        const s = try self.arena.alloc(u8, n);
        @memset(s, ' ');
        return s;
    }

    fn add_text(self: *const @This(), b: *BlockBuilder, text: []const u8, in: Inline) error{OutOfMemory}!void {
        if (text.len == 0) return;
        const start = b.text.items.len;
        try b.text.appendSlice(self.arena, text);
        try b.spans.append(self.arena, .{
            .start = start,
            .end = b.text.items.len,
            .attrs = .{ .style = in.style, .link = in.link, .sloc = in.sloc },
        });
    }

    fn inlines(self: *@This(), b: *BlockBuilder, elem: SDoc.Element, in: Inline) Error!void {
        var iter = elem.iterate();
        while (try iter.next()) |child| switch (child) {
            .text => |t| try self.add_text(b, t, in),
            .element => |e| try self.inline_element(b, e, in),
        };
    }

    fn inline_element(self: *@This(), b: *BlockBuilder, elem: SDoc.Element, in: Inline) Error!void {
        const tag = elem.tag;
        if (elem.is("br")) {
            try b.text.append(self.arena, '\n');
        } else if (elem.is("img")) {
            try self.add_text(b, elem.attr_string("alt") orelse "", .{ .style = in.style, .link = in.link, .sloc = elem.sloc() });
        } else if (elem.is("a")) {
            const href = elem.attr_string("href") orelse "";
            try self.inlines(b, elem, .{
                .style = self.apply_tag(in.style, tag),
                .link = if (href.len > 0) href else in.link,
                .sloc = elem.sloc(),
            });
        } else {
            try self.inlines(b, elem, .{ .style = self.apply_tag(in.style, tag), .link = in.link, .sloc = elem.sloc() });
        }
    }

    fn code(self: *@This(), b: *BlockBuilder, elem: SDoc.Element) Error!void {
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
    fn highlight(self: *@This(), b: *BlockBuilder, text: []const u8, lang: []const u8, base: Style, sloc: ?[2]usize) !bool {
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
                if (token.fg) |fg| style.fg = RDoc.Color.rgbFromUint(fg);
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

pub fn is_absolute_uri(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(uri[0])) return false;
    for (uri[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    return true;
}

// layout

const Prefix = struct {
    first: []const u8,
    rest: []const u8,
    attrs: RDoc.Attrs,
    used: bool = false,
};

fn LayoutBuilder(comptime Metrics: type) type {
    return struct {
        layout: *RDocLayout,
        arena: Allocator,
        metrics: Metrics,
        width: usize,
        tab_width: usize,
        code_overflow: CodeOverflow,
        prefixes: std.ArrayList(Prefix) = .empty,
        src_row: ?usize = null,

        fn text_width(self: *const @This(), text: []const u8, start_col: usize) usize {
            return render.text_width(self.metrics, text, start_col, self.tab_width);
        }

        fn prefix_runs(self: *@This(), runs: *std.ArrayList(RDocLayout.Run), consume: bool) !usize {
            var width: usize = 0;
            for (self.prefixes.items) |*p| {
                const text = if (p.used) p.rest else p.first;
                if (consume) p.used = true;
                if (text.len == 0) continue;
                try runs.append(self.arena, .{ .text = text, .attrs = p.attrs });
                width += self.text_width(text, width);
            }
            return width;
        }

        fn next_prefix_width(self: *const @This()) usize {
            var width: usize = 0;
            for (self.prefixes.items) |p| width += self.text_width(if (p.used) p.rest else p.first, width);
            return width;
        }

        fn blank_line(self: *@This()) !void {
            var runs: std.ArrayList(RDocLayout.Run) = .empty;
            var width: usize = 0;
            for (self.prefixes.items) |p| if (p.used) {
                if (p.rest.len == 0) continue;
                try runs.append(self.arena, .{ .text = p.rest, .attrs = p.attrs });
                width += self.text_width(p.rest, width);
            };
            // no trailing spaces on a line without content
            while (runs.items.len > 0) {
                const last = &runs.items[runs.items.len - 1];
                const trimmed = std.mem.trimEnd(u8, last.text, " ");
                width -= self.text_width(last.text, 0) - self.text_width(trimmed, 0);
                if (trimmed.len > 0) {
                    last.text = trimmed;
                    break;
                }
                _ = runs.pop();
            }
            try self.layout.lines.append(self.arena, .{ .runs = runs.items, .width = width });
        }

        fn emit(self: *@This(), text: []const u8, segs: []const RDocLayout.Run, start: usize, end: usize) !void {
            var runs: std.ArrayList(RDocLayout.Run) = .empty;
            var col = try self.prefix_runs(&runs, true);
            var pos: usize = 0;
            for (segs) |seg| {
                const seg_start = pos;
                pos += seg.text.len;
                const s = @max(start, seg_start);
                const e = @min(end, pos);
                if (s >= e) continue;
                const part = try self.expand_tabs(text[s..e], col);
                col += self.text_width(part, col);
                try runs.append(self.arena, .{ .text = part, .attrs = seg.attrs });
            }
            try self.layout.lines.append(self.arena, .{ .runs = runs.items, .width = col, .src_row = self.src_row });
        }

        fn expand_tabs(self: *const @This(), text: []const u8, start_col: usize) ![]const u8 {
            if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
            var out: std.ArrayList(u8) = .empty;
            var col = start_col;
            for (text) |c| if (c == '\t') {
                const n = self.tab_width - (col % self.tab_width);
                try out.appendNTimes(self.arena, ' ', n);
                col += n;
            } else {
                try out.append(self.arena, c);
                col += 1;
            };
            return out.items;
        }

        fn segments(self: *const @This(), b: RDoc.BlockReader) ![]RDocLayout.Run {
            var list: std.ArrayList(RDocLayout.Run) = .empty;
            var pos: usize = 0;
            var spans = try b.span_iterator();
            while (try spans.next()) |span| {
                if (span.start > pos) try list.append(self.arena, .{ .text = b.text[pos..span.start] });
                const start = @max(pos, span.start);
                const end = @min(span.end, b.text.len);
                if (end > start) try list.append(self.arena, .{ .text = b.text[start..end], .attrs = span.attrs });
                pos = @max(pos, end);
            }
            if (pos < b.text.len) try list.append(self.arena, .{ .text = b.text[pos..] });
            return list.items;
        }

        fn block(self: *@This(), b: RDoc.BlockReader) error{ OutOfMemory, InvalidRDoc }!void {
            for (0..b.space_before()) |_| try self.blank_line();
            const first_prefix = b.first_prefix();
            const prefix = b.prefix();
            const has_prefix = first_prefix.len > 0 or prefix.len > 0;
            if (has_prefix) try self.prefixes.append(self.arena, .{
                .first = first_prefix,
                .rest = prefix,
                .attrs = .{ .style = b.prefix_style() },
            });
            const lines_before = self.layout.lines.items.len;
            self.src_row = b.src_row();

            const fill = b.fill();
            if (b.is_table()) {
                try self.table(b);
            } else if (fill.len > 0) {
                const fill_width = @max(1, self.text_width(fill, 0));
                var line: std.ArrayList(u8) = .empty;
                for (0..self.avail() / fill_width) |_| try line.appendSlice(self.arena, fill);
                const seg: [1]RDocLayout.Run = .{.{ .text = line.items, .attrs = .{ .style = b.prefix_style() } }};
                const prefix_width = self.next_prefix_width();
                try self.emit(line.items, &seg, 0, line.items.len);
                try self.layout.fills.append(self.arena, .{ .line = self.layout.lines.items.len - 1, .fill = fill, .fill_width = fill_width, .prefix_width = prefix_width });
            } else if (b.text.len > 0) {
                try self.wrap(b);
            }

            if (!b.is_table()) {
                var children = b.iterate();
                while (try children.next()) |child| try self.block(child);
            }

            if (has_prefix) {
                self.src_row = b.src_row();
                if (self.layout.lines.items.len == lines_before) try self.emit("", &.{}, 0, 0);
                _ = self.prefixes.pop();
            }
        }

        /// a line of text and the runs that style it
        const LineText = struct {
            text: std.ArrayList(u8) = .empty,
            segs: std.ArrayList(RDocLayout.Run) = .empty,

            fn add(self: *LineText, arena: Allocator, text: []const u8, attrs: RDoc.Attrs) !void {
                if (text.len == 0) return;
                try self.text.appendSlice(arena, text);
                try self.segs.append(arena, .{ .text = text, .attrs = attrs });
            }
        };

        const CellLine = struct { segs: []const RDocLayout.Run, width: usize };
        const TableCell = struct { lines: []const CellLine, width: usize };
        const TableRow = struct { head: bool, height: usize, cells: []const TableCell, src_row: ?usize };

        /// the lines of a cell, split at hard breaks
        fn cell_lines(self: *const @This(), cell: RDoc.BlockReader) !TableCell {
            var lines: std.ArrayList(CellLine) = .empty;
            var segs: std.ArrayList(RDocLayout.Run) = .empty;
            var width: usize = 0;
            for (try self.segments(cell)) |seg| {
                var parts = std.mem.splitScalar(u8, seg.text, '\n');
                var first = true;
                while (parts.next()) |part| {
                    if (!first) {
                        try lines.append(self.arena, .{ .segs = segs.items, .width = width });
                        segs = .empty;
                        width = 0;
                    }
                    first = false;
                    if (part.len == 0) continue;
                    try segs.append(self.arena, .{ .text = part, .attrs = seg.attrs });
                    width += self.text_width(part, width);
                }
            }
            try lines.append(self.arena, .{ .segs = segs.items, .width = width });
            var max: usize = 0;
            for (lines.items) |line| max = @max(max, line.width);
            return .{ .lines = lines.items, .width = max };
        }

        /// columns sized to their widest cell, or one wrapped line per row line if that does not fit
        fn table(self: *@This(), b: RDoc.BlockReader) !void {
            var rows: std.ArrayList(TableRow) = .empty;
            var widths: std.ArrayList(usize) = .empty;
            var row_iter = b.iterate();
            while (try row_iter.next()) |row| {
                var cells: std.ArrayList(TableCell) = .empty;
                var height: usize = 1;
                var cell_iter = row.iterate();
                while (try cell_iter.next()) |cell| {
                    const table_cell = try self.cell_lines(cell);
                    if (cells.items.len >= widths.items.len) try widths.append(self.arena, 0);
                    widths.items[cells.items.len] = @max(widths.items[cells.items.len], table_cell.width);
                    height = @max(height, table_cell.lines.len);
                    try cells.append(self.arena, table_cell);
                }
                try rows.append(self.arena, .{ .head = row.row() == .head, .height = height, .cells = cells.items, .src_row = row.src_row() });
            }
            const separator = " │ ";
            const border: RDoc.Attrs = .{ .style = b.prefix_style() };
            var total: usize = 0;
            for (widths.items) |w| total += w;
            total += (widths.items.len -| 1) * self.text_width(separator, 0);
            const fits = total <= self.avail();

            for (rows.items) |row| {
                for (0..row.height) |k| {
                    self.src_row = if (row.src_row) |r| r + k else null;
                    var line: LineText = .{};
                    for (widths.items, 0..) |width, i| {
                        if (i > 0) try line.add(self.arena, separator, border);
                        const cell_line: CellLine = if (i < row.cells.len and k < row.cells[i].lines.len)
                            row.cells[i].lines[k]
                        else
                            .{ .segs = &.{}, .width = 0 };
                        const pad = if (fits) width -| cell_line.width else 0;
                        const left = switch (b.column_align(i)) {
                            .right => pad,
                            .center => pad / 2,
                            .none, .left => 0,
                        };
                        try line.add(self.arena, try self.spaces(left), .{});
                        for (cell_line.segs) |seg| try line.add(self.arena, seg.text, seg.attrs);
                        if (i + 1 < widths.items.len) try line.add(self.arena, try self.spaces(pad - left), .{});
                    }
                    if (fits)
                        try self.emit(line.text.items, line.segs.items, 0, line.text.items.len)
                    else
                        try self.wrap_words(line.text.items, line.segs.items, 0, line.text.items.len);
                }
                if (row.head and fits) {
                    self.src_row = null;
                    var rule: LineText = .{};
                    for (widths.items, 0..) |width, i| {
                        if (i > 0) try rule.add(self.arena, "─┼─", border);
                        var dashes: std.ArrayList(u8) = .empty;
                        for (0..width) |_| try dashes.appendSlice(self.arena, "─");
                        try rule.add(self.arena, dashes.items, border);
                    }
                    try self.emit(rule.text.items, rule.segs.items, 0, rule.text.items.len);
                }
            }
        }

        fn spaces(self: *const @This(), n: usize) ![]const u8 {
            const s = try self.arena.alloc(u8, n);
            @memset(s, ' ');
            return s;
        }

        const Grapheme = struct { len: usize, width: usize };

        fn grapheme(self: *const @This(), text: []const u8, col: usize) Grapheme {
            var cols: usize = 0;
            const len = self.metrics.egc_length(text, &cols, col, self.tab_width);
            return .{ .len = @max(1, len), .width = cols };
        }

        fn wrap(self: *@This(), b: RDoc.BlockReader) !void {
            const segs = try self.segments(b);
            const mode: enum { words, cells, clip } = switch (b.wrap()) {
                .words => .words,
                .cells => if (self.code_overflow == .clip) .clip else .cells,
            };
            const first_row = b.src_row();
            var lines = std.mem.splitScalar(u8, b.text, '\n');
            var line_start: usize = 0;
            var k: usize = 0;
            while (lines.next()) |line| : (k += 1) {
                self.src_row = if (first_row) |r| r + k else null;
                const a = line_start;
                const end = a + line.len;
                line_start = end + 1;
                switch (mode) {
                    .words => try self.wrap_words(b.text, segs, a, end),
                    .cells => try self.wrap_cells(b.text, segs, a, end),
                    .clip => try self.clip(b.text, segs, a, end),
                }
            }
        }

        fn avail(self: *const @This()) usize {
            return @max(1, self.width -| self.next_prefix_width());
        }

        fn clip(self: *@This(), text: []const u8, segs: []const RDocLayout.Run, a: usize, end: usize) !void {
            const width = self.avail();
            if (self.text_width(text[a..end], 0) <= width) return self.emit(text, segs, a, end);
            var col: usize = 0;
            var i = a;
            while (i < end) {
                const g = self.grapheme(text[i..end], col);
                if (col + g.width > width -| 1) break;
                col += g.width;
                i += g.len;
            }
            try self.emit(text, segs, a, i);
            const line = &self.layout.lines.items[self.layout.lines.items.len - 1];
            const runs = try self.arena.alloc(RDocLayout.Run, line.runs.len + 1);
            @memcpy(runs[0..line.runs.len], line.runs);
            runs[line.runs.len] = .{ .text = "…", .attrs = if (line.runs.len > 0) line.runs[line.runs.len - 1].attrs else .{} };
            line.runs = runs;
            line.width += 1;
        }

        fn wrap_cells(self: *@This(), text: []const u8, segs: []const RDocLayout.Run, a: usize, end: usize) !void {
            var ls = a;
            var col: usize = 0;
            var i = a;
            var width = self.avail();
            while (i < end) {
                const g = self.grapheme(text[i..end], col);
                if (col + g.width > width and i > ls) {
                    try self.emit(text, segs, ls, i);
                    ls = i;
                    col = 0;
                    width = self.avail();
                }
                col += g.width;
                i += g.len;
            }
            if (ls < end or a == end) try self.emit(text, segs, ls, end);
        }

        fn wrap_words(self: *@This(), text: []const u8, segs: []const RDocLayout.Run, a: usize, end: usize) !void {
            var ls = a;
            var col: usize = 0;
            var word_end = a;
            var i = a;
            var width = self.avail();
            while (i < end) {
                if (text[i] == ' ') {
                    if (ls == i and ls != a) {
                        // no spaces at the start of a wrapped line
                        i += 1;
                        ls = i;
                        word_end = i;
                        continue;
                    }
                    col += 1;
                    i += 1;
                    continue;
                }
                var j = i;
                var word_width: usize = 0;
                while (j < end and text[j] != ' ') {
                    const g = self.grapheme(text[j..end], col + word_width);
                    word_width += g.width;
                    j += g.len;
                }
                if (col + word_width > width and word_end > ls) {
                    try self.emit(text, segs, ls, word_end);
                    ls = i;
                    col = 0;
                    width = self.avail();
                }
                if (word_width > width) {
                    // a word longer than the line breaks at cells
                    var k = i;
                    var c = col;
                    while (k < j) {
                        const g = self.grapheme(text[k..j], c);
                        if (c + g.width > width and k > ls) {
                            try self.emit(text, segs, ls, k);
                            ls = k;
                            c = 0;
                            width = self.avail();
                        }
                        c += g.width;
                        k += g.len;
                    }
                    col = c;
                } else {
                    col += word_width;
                }
                word_end = j;
                i = j;
            }
            if (word_end > ls or a == end) try self.emit(text, segs, ls, word_end);
        }
    };
}

fn write_run(plane: anytype, base: Style, run: RDocLayout.Run, opts: PlaneOptions) void {
    const a = run.attrs.style;
    var style = base;
    if (a.fg != .default) style.fg = a.fg;
    if (a.bg != .default) style.bg = a.bg;
    if (a.ul != .default) style.ul = a.ul;
    if (a.ul_style != .off) style.ul_style = a.ul_style;
    style.bold = style.bold or a.bold;
    style.dim = style.dim or a.dim;
    style.italic = style.italic or a.italic;
    style.blink = style.blink or a.blink;
    style.reverse = style.reverse or a.reverse;
    style.invisible = style.invisible or a.invisible;
    style.strikethrough = style.strikethrough or a.strikethrough;
    if (opts.underline_links and run.attrs.link.len > 0) style.ul_style = .single;
    plane.style = style;
    if (run.attrs.link.len == 0 or !opts.terminal_link(run.attrs.link)) {
        _ = plane.putstr(run.text) catch {};
        return;
    }
    var i: usize = 0;
    while (i < run.text.len) {
        var cell = plane.cell_init();
        const len = plane.cell_load(&cell, run.text[i..]) catch return;
        plane.cell_set_link(&cell, run.attrs.link, run.attrs.link_id);
        const width = plane.putc(&cell) catch return;
        if (width == 0) return;
        i += @max(1, len);
    }
}
