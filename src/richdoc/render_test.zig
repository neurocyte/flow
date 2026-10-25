const std = @import("std");
const syntax = @import("syntax");
const build_options = @import("build_options");
const markdown = @import("markdown.zig");
const RDoc = @import("RDoc.zig");
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
    try expect("# Head *em* **b**\n\npara `code` [l](http://x) [rel](a.md)", .{}, "(blocks (block :wrap \"words\" :width 9 \"Head em b\" (span 0 5 :fg 0x000001 :bold true) (span 5 7 :fg 0x000001 :bold true :italic true) (span 7 8 :fg 0x000001 :bold true) (span 8 9 :fg 0x000002 :bold true)) (block :wrap \"words\" :space_before 1 :width 15 \"para code l rel\" (span 0 5) (span 5 9 :fg 0x000003) (span 9 10) (span 10 11 :fg 0x000004 :ul_style 1 :link \"http://x\") (span 11 12) (span 12 15 :fg 0x000004 :ul_style 1)))");
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
    try std.testing.expectEqual(.single, span.attrs.style.ul_style);
    try std.testing.expectEqual([2]usize{ 2, 18 }, span.attrs.sloc.?);
    try std.testing.expectEqual(null, try top.next());
}

test "pipe table" {
    try expect("| a | b |\n|:--|--:|\n| 1 | **2** |\n", .{}, "(blocks (block :prefix_style { :fg 0x000005 } :wrap \"cells\" :table [\"left\" \"right\"] :width 0 \"\" (block :wrap \"cells\" :row \"head\" :width 0 \"\" (block :wrap \"cells\" :width 1 \"a\" (span 0 1 :bold true)) (block :wrap \"cells\" :width 1 \"b\" (span 0 1 :bold true))) (block :wrap \"cells\" :row \"body\" :width 0 \"\" (block :wrap \"cells\" :width 1 \"1\" (span 0 1)) (block :wrap \"cells\" :width 1 \"2\" (span 0 1 :fg 0x000002 :bold true)))))");
}
