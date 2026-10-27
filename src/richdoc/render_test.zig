const std = @import("std");
const syntax = @import("syntax");
const build_options = @import("build_options");
const markdown = @import("markdown.zig");
const RDoc = @import("RDoc.zig");
const RDocLayout = @import("RDocLayout.zig");
const render = @import("render.zig");
const debug = @import("debug.zig");

const test_theme = struct {
    fn find(_: *const anyopaque, scope: []const u8) ?render.Token {
        const tokens = [_]struct { []const u8, render.Token }{
            .{ "markup.heading", .{ .fg = 0x000001 } },
            .{ "markup.bold", .{ .fg = 0x000002 } },
            .{ "text.emphasis", .{ .fs = .italic } },
            .{ "markup.raw", .{ .fg = 0x000003 } },
            .{ "markup.underline.link", .{ .fg = 0x000004 } },
            .{ "punctuation.special", .{ .fg = 0x000005 } },
            .{ "comment", .{ .fg = 0x000006 } },
            .{ "keyword", .{ .fg = 0x000007, .fs = .bold } },
            .{ "number", .{ .fg = 0x000008 } },
        };
        for (tokens) |t| if (std.mem.eql(u8, t[0], scope)) return t[1];
        return null;
    }
    const theme: render.Theme = .{ .context = undefined, .find = find };
};

fn dump(source: []const u8, opts: render.Options) ![]const u8 {
    const gpa = std.testing.allocator;
    const query_cache = try syntax.QueryCache.create(std.testing.io, gpa, .{});
    defer query_cache.deinit();
    const sdoc = try markdown.parse(gpa, source, query_cache);
    defer gpa.free(sdoc.raw.bytes);
    const rdoc = try render.from_sdoc(gpa, sdoc, test_theme.theme, query_cache, opts);
    defer gpa.free(rdoc.raw.bytes);
    return debug.rdoc_sexpr_alloc(gpa, rdoc, .{});
}

fn expect(source: []const u8, opts: render.Options, expected: []const u8) !void {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const actual = try dump(source, opts);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "heading and inline styles" {
    try expect("# Head *em* **b**\n\npara `code` [l](http://x) [rel](a.md)", .{}, "(blocks (block :wrap \"words\" :width 9 \"Head em b\" (span 0 5 :fg 0x000001 :bold true) (span 5 7 :fg 0x000001 :bold true :italic true) (span 7 8 :fg 0x000001 :bold true) (span 8 9 :fg 0x000002 :bold true)) (block :wrap \"words\" :space_before 1 :width 15 \"para code l rel\" (span 0 5) (span 5 9 :fg 0x000003) (span 9 10) (span 10 11 :fg 0x000004 :link \"http://x\") (span 11 12) (span 12 15 :fg 0x000004 :link \"a.md\")))");
}

test "nested inline styles" {
    try expect("*a **b** c*", .{}, "(blocks (block :wrap \"words\" :width 5 \"a b c\" (span 0 2 :italic true) (span 2 3 :fg 0x000002 :bold true :italic true) (span 3 5 :italic true)))");
}

test "tight lists, task items and ordered start" {
    try expect("- a\n- [x] b\n  - c\n\n3. one\n4. two", .{}, "(blocks (block :wrap \"words\" :width 0 \"\" (block :first_prefix \"• \" :prefix \"  \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 1 \"a\" (span 0 1)) (block :first_prefix \"• [x] \" :prefix \"  \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 1 \"b\" (span 0 1) (block :wrap \"words\" :width 0 \"\" (block :first_prefix \"• \" :prefix \"  \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 1 \"c\" (span 0 1))))) (block :wrap \"words\" :space_before 1 :width 0 \"\" (block :first_prefix \"3. \" :prefix \"   \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 3 \"one\" (span 0 3)) (block :first_prefix \"4. \" :prefix \"   \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 3 \"two\" (span 0 3))))");
}

test "loose list" {
    try expect("- a\n\n- b\n\n  more", .{}, "(blocks (block :wrap \"words\" :width 0 \"\" (block :first_prefix \"• \" :prefix \"  \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 0 \"\" (block :wrap \"words\" :width 1 \"a\" (span 0 1))) (block :first_prefix \"• \" :prefix \"  \" :prefix_style { :fg 0x000005 } :wrap \"words\" :space_before 1 :width 0 \"\" (block :wrap \"words\" :width 1 \"b\" (span 0 1)) (block :wrap \"words\" :space_before 1 :width 4 \"more\" (span 0 4)))))");
}

test "block quote with a list" {
    try expect("> quote\n>\n> - item", .{}, "(blocks (block :first_prefix \"▎ \" :prefix \"▎ \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 0 \"\" (block :wrap \"words\" :width 5 \"quote\" (span 0 5)) (block :wrap \"words\" :space_before 1 :width 0 \"\" (block :first_prefix \"• \" :prefix \"  \" :prefix_style { :fg 0x000005 } :wrap \"words\" :width 4 \"item\" (span 0 4)))))");
}

test "hard break, thematic break and image" {
    try expect("line  \nbreak\n\n***\n\n![alt](i.png)", .{}, "(blocks (block :wrap \"words\" :width 5 \"line\\nbreak\" (span 0 4) (span 5 10)) (block :prefix_style { :fg 0x000005 } :wrap \"words\" :fill \"─\" :space_before 1 :width 0 \"\") (block :wrap \"words\" :space_before 1 :width 3 \"alt\" (span 0 3)))");
}

test "code highlights" {
    try expect("```zig\nconst x = 1;\n```", .{}, "(blocks (block :wrap \"cells\" :width 12 \"const x = 1;\" (span 0 5 :fg 0x000007 :bold true) (span 5 10 :fg 0x000003) (span 10 11 :fg 0x000008) (span 11 12 :fg 0x000003)))");
}

test "code without a language" {
    try expect("```\nplain\n```", .{}, "(blocks (block :wrap \"cells\" :width 5 \"plain\" (span 0 5 :fg 0x000003)))");
}

test "code with an unknown language" {
    try expect("```nosuchlang\nx\n```", .{}, "(blocks (block :wrap \"cells\" :width 1 \"x\" (span 0 1 :fg 0x000003)))");
}

test "html block" {
    try expect("<div>\nraw\n</div>", .{}, "(blocks (block :wrap \"cells\" :width 6 \"<div>\\nraw\\n</div>\" (span 0 16 :fg 0x000006)))");
}

test "code with the default language" {
    try expect("```\nconst y = 2;\n```", .{ .default_lang = "zig" }, "(blocks (block :wrap \"cells\" :width 12 \"const y = 2;\" (span 0 5 :fg 0x000007 :bold true) (span 5 10 :fg 0x000003) (span 10 11 :fg 0x000008) (span 11 12 :fg 0x000003)))");
}

test "rdoc reader" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const query_cache = try syntax.QueryCache.create(std.testing.io, gpa, .{});
    defer query_cache.deinit();
    const sdoc = try markdown.parse(gpa, "- [link](http://x)\n", query_cache);
    defer gpa.free(sdoc.raw.bytes);
    const rdoc = try render.from_sdoc(gpa, sdoc, test_theme.theme, query_cache, .{});
    defer gpa.free(rdoc.raw.bytes);
    var top = try RDoc.BlockIterator.root(rdoc);
    const list = (try top.next()).?;
    var items = list.iterate();
    const item = (try items.next()).?;
    try std.testing.expectEqualStrings("• ", item.first_prefix());
    try std.testing.expectEqualStrings("  ", item.prefix());
    try std.testing.expectEqual(.words, item.wrap());
    try std.testing.expectEqualStrings("link", item.text);
    var spans = try item.span_iterator();
    const span = (try spans.next()).?;
    try std.testing.expectEqualStrings("http://x", span.attrs.link);
    try std.testing.expectEqual(.off, span.attrs.style.ul_style);
    try std.testing.expectEqual([2]usize{ 2, 18 }, span.attrs.sloc.?);
    try std.testing.expectEqual(null, try top.next());
}

test "pipe table" {
    try expect("| a | b |\n|:--|--:|\n| 1 | **2** |\n", .{}, "(blocks (block :prefix_style { :fg 0x000005 } :wrap \"cells\" :table [\"left\" \"right\"] :width 0 \"\" (block :wrap \"cells\" :row \"head\" :width 0 \"\" (block :wrap \"cells\" :width 1 \"a\" (span 0 1 :bold true)) (block :wrap \"cells\" :width 1 \"b\" (span 0 1 :bold true))) (block :wrap \"cells\" :row \"body\" :width 0 \"\" (block :wrap \"cells\" :width 1 \"1\" (span 0 1)) (block :wrap \"cells\" :width 1 \"2\" (span 0 1 :fg 0x000002 :bold true)))))");
}

const test_metrics = struct {
    pub fn egc_length(_: @This(), text: []const u8, cols: *usize, _: usize, _: usize) usize {
        cols.* = 1;
        return std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    }
}{};

fn layout_of(source: []const u8, width: usize) !TestLayout {
    return layout_with(source, width, test_metrics);
}

/// three byte UTF-8 sequences are two cells wide
const wide_metrics = struct {
    pub fn egc_length(_: @This(), text: []const u8, cols: *usize, _: usize, _: usize) usize {
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        cols.* = if (len >= 3) 2 else 1;
        return len;
    }
}{};

/// the layout's runs point into the rdoc, so both live until deinit
const TestLayout = struct {
    layout: RDocLayout,
    rdoc: []const u8,

    fn deinit(self: *TestLayout) void {
        self.layout.deinit();
        std.testing.allocator.free(self.rdoc);
    }
};

fn layout_with(source: []const u8, width: usize, metrics: anytype) !TestLayout {
    const gpa = std.testing.allocator;
    const query_cache = try syntax.QueryCache.create(std.testing.io, gpa, .{});
    defer query_cache.deinit();
    const sdoc = try markdown.parse(gpa, source, query_cache);
    defer gpa.free(sdoc.raw.bytes);
    const rdoc = try render.from_sdoc(gpa, sdoc, test_theme.theme, query_cache, .{});
    errdefer gpa.free(rdoc.raw.bytes);
    var layout: RDocLayout = .init(gpa);
    errdefer layout.deinit();
    try render.to_layout(&layout, rdoc, metrics, .{ .width = width, .tab_width = 8 });
    return .{ .layout = layout, .rdoc = rdoc.raw.bytes };
}

fn expect_rows(source: []const u8, width: usize, expected: []const ?usize) !void {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var t = try layout_of(source, width);
    defer t.deinit();
    const layout = &t.layout;
    const rows = try gpa.alloc(?usize, layout.lines.items.len);
    defer gpa.free(rows);
    for (layout.lines.items, rows) |line, *row| row.* = line.src_row;
    try std.testing.expectEqualSlices(?usize, expected, rows);
}

test "layout source rows of a heading, a paragraph and a code block" {
    try expect_rows("# Head\n\npara\n\n```zig\na\nb\n```\n", 40, &.{ 0, null, 2, null, 5, 6 });
}

test "layout source rows of hard breaks and wrapped lines" {
    try expect_rows("line  \nbreak\n\naaa bbb ccc\n", 5, &.{ 0, 1, null, 3, 3, 3 });
}

test "layout source rows of a code block in a list item" {
    try expect_rows("- item\n\n  ```\n  x\n  y\n  ```\n", 40, &.{ 0, null, 3, 4 });
}

test "layout source rows of a table" {
    try expect_rows("| a |\n|---|\n| 1 |\n| 2 |\n", 40, &.{ 0, null, 2, 3 });
}

test "layout line of a source row" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    // lines: Head 0, blank, para 2, blank, a 5, b 6
    var t = try layout_of("# Head\n\npara\n\n```zig\na\nb\n```\n", 40);
    defer t.deinit();
    const layout = &t.layout;
    try std.testing.expectEqual(0, layout.line_of_src_row(0));
    try std.testing.expectEqual(0, layout.line_of_src_row(1));
    try std.testing.expectEqual(2, layout.line_of_src_row(2));
    try std.testing.expectEqual(2, layout.line_of_src_row(4));
    try std.testing.expectEqual(4, layout.line_of_src_row(5));
    try std.testing.expectEqual(5, layout.line_of_src_row(6));
    try std.testing.expectEqual(5, layout.line_of_src_row(100));
}

test "layout line of a source row in wrapped lines" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    // lines: line 0, break 1, blank, aaa 3, bbb 3, ccc 3
    var t = try layout_of("line  \nbreak\n\naaa bbb\nccc\n", 5);
    defer t.deinit();
    const layout = &t.layout;
    try std.testing.expectEqual(1, layout.line_of_src_row(2));
    try std.testing.expectEqual(3, layout.line_of_src_row(3));
    try std.testing.expectEqual(3, layout.line_of_src_row(4));
}

test "layout line of a source row before any mapped line" {
    var layout: RDocLayout = .init(std.testing.allocator);
    defer layout.deinit();
    try layout.add_line("plain", 5);
    try std.testing.expectEqual(null, layout.line_of_src_row(3));
}

test "link at a cell of a wrapped link" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    // lines: "see aaa", "bbb end", the link text is "aaa bbb"
    var t = try layout_of("see [aaa bbb](other.md) end\n", 7);
    defer t.deinit();
    const layout = &t.layout;
    try std.testing.expectEqual(null, render.link_at(layout, 0, 2, test_metrics));
    try std.testing.expectEqualStrings("other.md", render.link_at(layout, 0, 4, test_metrics).?);
    try std.testing.expectEqualStrings("other.md", render.link_at(layout, 1, 0, test_metrics).?);
    try std.testing.expectEqual(null, render.link_at(layout, 1, 5, test_metrics));
    try std.testing.expectEqual(null, render.link_at(layout, 0, 40, test_metrics));
    try std.testing.expectEqual(null, render.link_at(layout, 9, 0, test_metrics));
}

test "link at a cell after a wide character" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    // "中 l": the wide character takes cells 0 and 1, the link is at cell 3
    var t = try layout_with("中 [l](#top)\n", 40, wide_metrics);
    defer t.deinit();
    const layout = &t.layout;
    try std.testing.expectEqual(null, render.link_at(layout, 0, 1, wide_metrics));
    try std.testing.expectEqual(null, render.link_at(layout, 0, 2, wide_metrics));
    try std.testing.expectEqualStrings("#top", render.link_at(layout, 0, 3, wide_metrics).?);
}

/// records one mark per cell: '.' plain, 'u' underlined, 'l' terminal link, 'L' both
const MarkPlane = struct {
    style: RDoc.Style = .{},
    marks: [64]u8 = undefined,
    len: usize = 0,

    const Cell = struct { char: u8 = ' ', link: bool = false };

    fn mark(self: *MarkPlane, link: bool) void {
        const ul = self.style.ul_style != .off;
        self.marks[self.len] = if (link and ul) 'L' else if (link) 'l' else if (ul) 'u' else '.';
        self.len += 1;
    }
    pub fn cursor_move_yx(_: *MarkPlane, _: usize, _: usize) void {}
    pub fn putstr(self: *MarkPlane, text: []const u8) !usize {
        for (text) |_| self.mark(false);
        return text.len;
    }
    pub fn cell_init(_: *MarkPlane) Cell {
        return .{};
    }
    pub fn cell_load(_: *MarkPlane, cell: *Cell, text: []const u8) !usize {
        cell.char = text[0];
        return 1;
    }
    pub fn cell_set_link(_: *MarkPlane, cell: *Cell, _: []const u8, _: []const u8) void {
        cell.link = true;
    }
    pub fn putc(self: *MarkPlane, cell: *Cell) !usize {
        self.mark(cell.link);
        return 1;
    }
};

test "draw links as terminal links and underlined" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    var t = try layout_of("a [b](x.md) [c](https://x)\n", 40);
    defer t.deinit();
    var plain: MarkPlane = .{};
    render.to_plane(&t.layout, &plain, 0, 1, 0, .{}, .{});
    try std.testing.expectEqualStrings(".....", plain.marks[0..plain.len]);
    var links: MarkPlane = .{};
    render.to_plane(&t.layout, &links, 0, 1, 0, .{}, .{ .terminal_link = render.is_absolute_uri });
    try std.testing.expectEqualStrings("....l", links.marks[0..links.len]);
    var all: MarkPlane = .{};
    render.to_plane(&t.layout, &all, 0, 1, 0, .{}, .{ .terminal_link = render.is_absolute_uri, .underline = .all });
    try std.testing.expectEqualStrings("..u.L", all.marks[0..all.len]);
    var hovered: MarkPlane = .{};
    render.to_plane(&t.layout, &hovered, 0, 1, 0, .{}, .{ .terminal_link = render.is_absolute_uri, .underline = .{ .link = "x.md" } });
    try std.testing.expectEqualStrings("..u.l", hovered.marks[0..hovered.len]);
}
