const std = @import("std");
const syntax = @import("syntax");
const build_options = @import("build_options");
const markdown = @import("markdown.zig");
const debug = @import("debug.zig");

fn dump(source: []const u8, sloc: bool) ![]const u8 {
    const gpa = std.testing.allocator;
    const query_cache = try syntax.QueryCache.create(std.testing.io, gpa, .{});
    defer query_cache.deinit();
    const sdoc = try markdown.parse(gpa, source, query_cache);
    defer gpa.free(sdoc.raw.bytes);
    return debug.sdoc_sexpr_alloc(gpa, sdoc, .{ .sloc = sloc });
}

fn expect(source: []const u8, expected: []const u8) !void {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const actual = try dump(source, false);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "headings" {
    try expect("# One\n\nTwo\n===\n\n### Three ###\n", "(body (h1 \"One\") (h1 \"Two\") (h3 \"Three\"))");
}

test "soft and hard line breaks" {
    try expect("a soft\nbreak and a hard  \nbreak and\\\nanother", "(body (p \"a soft break and a hard\" (br) \"break and\" (br) \"another\"))");
}

test "emphasis, strong and strikethrough" {
    try expect("*em* **strong** ***both*** *a **b** c* ~~del~~ ~one~", "(body (p (em \"em\") \" \" (strong \"strong\") \" \" (em (strong \"both\")) \" \" (em \"a \" (strong \"b\") \" c\") \" \" (del \"del\") \" \" (del \"one\")))");
}

test "code spans" {
    try expect("`code` `` a`b `` `  ` ` x `", "(body (p (code \"code\") \" \" (code \"a`b\") \" \" (code \"  \") \" \" (code \"x\")))");
}

test "links and reference definitions" {
    try expect("[a](http://a \"T\") [b][r] [r][] [r] [nope] <http://c> <x@y.z>\n\n[r]: <http://r> 'R'\n", "(body (p (a :href \"http://a\" :title \"T\" \"a\") \" \" (a :href \"http://r\" :title \"R\" \"b\") \" \" (a :href \"http://r\" :title \"R\" \"r\") \" \" (a :href \"http://r\" :title \"R\" \"r\") \" [nope] \" (a :href \"http://c\" \"http://c\") \" \" (a :href \"mailto:x@y.z\" \"x@y.z\")))");
}

test "images" {
    try expect("![alt *text*](i.png \"T\")", "(body (p (img :src \"i.png\" :alt \"alt text\" :title \"T\")))");
}

test "escapes and entities" {
    try expect("\\*no\\* &amp; &#65; &#x42; &bogus; &copy;", "(body (p \"*no* & A B &bogus; ©\"))");
}

test "escaped plain text renders as itself" {
    var md: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer md.deinit();
    try markdown.write_escaped(&md.writer, "# a*b*_c_ [d](e) `f` <g> &amp; 1. \\x\nnext: - line");
    try expect(md.written(), "(body (p \"# a*b*_c_ [d](e) `f` <g> &amp; 1. \\\\x\" (br) \"next: - line\"))");
}

test "tight list" {
    try expect("- a\n- b\n  more\n* c", "(body (ul (li \"a\") (li \"b more\")) (ul (li \"c\")))");
}

test "loose list" {
    try expect("- a\n\n- b", "(body (ul (li (p \"a\")) (li (p \"b\"))))");
}

test "loose list with two paragraphs in an item" {
    try expect("- a\n\n  para\n- b", "(body (ul (li (p \"a\") (p \"para\")) (li (p \"b\"))))");
}

test "ordered list start" {
    try expect("3. x\n4. y", "(body (ol :start 3 (li \"x\") (li \"y\")))");
}

test "task list items" {
    try expect("- [ ] todo\n- [x] done", "(body (ul (li :checked false \"todo\") (li :checked true \"done\")))");
}

test "nested lists" {
    try expect("- a\n  - b\n    - c\n- d", "(body (ul (li \"a\" (ul (li \"b\" (ul (li \"c\"))))) (li \"d\")))");
}

test "block quote with continuation lines" {
    try expect("> quote *a\n> b* c\n>\n> second", "(body (blockquote (p \"quote \" (em \"a b\") \" c\") (p \"second\")))");
}

test "fenced code in a list item" {
    try expect("1. ```zig\n   const x = 1;\n   ```\n2. y", "(body (ol (li (pre :lang \"zig\" \"const x = 1;\")) (li \"y\")))");
}

test "indented code" {
    try expect("para\n\n    indented\n    code\n\nafter", "(body (p \"para\") (pre \"indented\\ncode\") (p \"after\"))");
}

test "thematic break" {
    try expect("a\n\n***\n\nb", "(body (p \"a\") (hr) (p \"b\"))");
}

test "html block" {
    try expect("<div>\nhtml\n</div>\n\nafter", "(body (html \"<div>\\nhtml\\n</div>\") (p \"after\"))");
}

test "empty document" {
    try expect("", "(body)");
}

test "clangd hover" {
    try expect(@embedFile("test/clangd_hover.md"), "(body (h3 \"function \" (code \"snprintf\")) (p \"provided by \" (code \"<stdio.h>\")) (hr) (p \"→ \" (code \"int\") (br) \"Parameters:\") (ul (li (code \"char *restrict __s\")) (li (code \"size_t __maxlen (aka unsigned long)\")) (li (code \"const char *restrict __format\"))) (p \"Maximum chars of output to write in MAXLEN.\") (hr) (pre :lang \"cpp\" \"extern int snprintf(char *restrict __s, size_t __maxlen,\\n                    const char *restrict __format, ...)\"))");
}

test "rust-analyzer hover" {
    try expect(@embedFile("test/rust_analyzer_hover.md"), "(body (pre :lang \"rust\" \"alloc::vec::Vec\") (pre :lang \"rust\" \"pub fn with_capacity(capacity: usize) -> Self\") (hr) (p \"Constructs a new, empty \" (code \"Vec<T>\") \" with at least the specified capacity.\") (p \"The vector will be able to hold at least \" (code \"capacity\") \" elements without reallocating. See \" (a :href \"https://doc.rust-lang.org/stable/alloc/vec/struct.Vec.html#method.reserve\" (code \"Vec::reserve\")) \" for details.\") (h1 \"Panics\") (p \"Panics if the new capacity exceeds \" (code \"isize::MAX\") \" \" (em \"bytes\") \".\") (h1 \"Examples\") (pre :lang \"rust\" \"let mut vec = Vec::with_capacity(10);\\nassert_eq!(vec.len(), 0);\"))");
}

test "zls hover" {
    try expect(@embedFile("test/zls_hover.md"), "(body (pre :lang \"zig\" \"fn add(a: i32, b: i32) i32\") (pre :lang \"zig\" \"(fn (i32, i32) i32)\") (p \"Adds two numbers.\") (p \"Returns the \" (strong \"sum\") \" of \" (code \"a\") \" and \" (code \"b\") \".\") (pre :lang \"zig\" \"const x = add(1, 2);\"))");
}

test "source locations" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const actual = try dump("# a *b*\n\n> c\n", true);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("(body :sloc [0 13] :src_row 0 (h1 :sloc [0 8] :src_row 0 \"a \" (em :sloc [4 7] :src_row 0 \"b\")) (blockquote :sloc [9 13] :src_row 2 (p :sloc [11 13] :src_row 2 \"c\")))", actual);
}

test "pipe table" {
    try expect("| a | b | c | d |\n|:--|--:|:-:|---|\n| 1 | **2** | `3` | 4 \\| 5 |\n| x |\n", "(body (table (thead (tr (th :align \"left\" \"a\") (th :align \"right\" \"b\") (th :align \"center\" \"c\") (th \"d\"))) (tbody (tr (td :align \"left\" \"1\") (td :align \"right\" (strong \"2\")) (td :align \"center\" (code \"3\")) (td \"4 | 5\")) (tr (td :align \"left\" \"x\")))))");
}

test "inline html" {
    try expect("a<br>b<BR/>c <b>bold</b> d", "(body (p \"a\" (br) \"b\" (br) \"c \" (html \"<b>\") \"bold\" (html \"</b>\") \" d\"))");
}

fn code_block(lang: ?[]const u8, lines: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try markdown.write_code_block(&out.writer, lang, lines);
    return out.toOwnedSlice();
}

test "write_code_block" {
    const out = try code_block("zig", &.{ "const x = 1;", "", "x += 1;" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("```zig\nconst x = 1;\nx += 1;\n```\n", out);
}

test "write_code_block fence is longer than any backtick run" {
    const out = try code_block(null, &.{ "a ``` b", "````" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("`````\na ``` b\n````\n`````\n", out);
    try expect(out, "(body (pre \"a ``` b\\n````\"))");
}
