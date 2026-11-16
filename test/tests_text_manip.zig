const std = @import("std");
const text_manip = @import("text_manip");

const allocator = std.testing.allocator;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expect_toggle(prefix: []const u8, input: []const u8, expected: []const u8) !void {
    const output = try text_manip.toggle_prefix_in_text(prefix, input, allocator);
    defer allocator.free(output);
    try expectEqualStrings(expected, output);
}

test "add prefix to multiple lines with trailing newline" {
    try expect_toggle("//", "one\ntwo\n", "// one\n// two\n");
}

test "add prefix to multiple lines without trailing newline" {
    try expect_toggle("//", "one\ntwo", "// one\n// two");
}

test "remove prefix from multiple lines with trailing newline" {
    try expect_toggle("//", "// one\n// two\n", "one\ntwo\n");
}

test "remove prefix from multiple lines without trailing newline" {
    try expect_toggle("//", "// one\n// two", "one\ntwo");
}

test "add prefix to single line without newline" {
    try expect_toggle("//", "one", "// one");
}

test "remove prefix from single line without newline" {
    try expect_toggle("//", "// one", "one");
}

test "empty text is prefixed" {
    try expect_toggle("//", "", "//");
}

test "empty text round-trips back to empty" {
    try expect_toggle("//", "//", "");
}

test "blank lines are preserved and not prefixed" {
    try expect_toggle("//", "one\n\ntwo\n", "// one\n\n// two\n");
}

test "prefix is added at the common indent" {
    try expect_toggle("//", "    one\n    two\n", "    // one\n    // two\n");
}

test "prefix is removed from indented lines" {
    try expect_toggle("//", "    // one\n    // two\n", "    one\n    two\n");
}

test "mixed prefixed and unprefixed lines are all prefixed" {
    try expect_toggle("//", "// one\ntwo\n", "// // one\n// two\n");
}

test "add and remove round-trip" {
    const input = "one\n  two\n\nthree";
    const commented = try text_manip.toggle_prefix_in_text("//", input, allocator);
    defer allocator.free(commented);
    const output = try text_manip.toggle_prefix_in_text("//", commented, allocator);
    defer allocator.free(output);
    try expectEqualStrings(input, output);
}

test "line_matches_fragments: empty query matches everything" {
    try std.testing.expect(text_manip.line_matches_fragments("anything", ""));
    try std.testing.expect(text_manip.line_matches_fragments("", "   "));
}

test "line_matches_fragments: all fragments must match in any order" {
    const line = "  12 | const foo = bar(baz);";
    try std.testing.expect(text_manip.line_matches_fragments(line, "foo"));
    try std.testing.expect(text_manip.line_matches_fragments(line, "baz foo"));
    try std.testing.expect(text_manip.line_matches_fragments(line, "  bar\tconst  "));
    try std.testing.expect(!text_manip.line_matches_fragments(line, "foo qux"));
    try std.testing.expect(text_manip.line_matches_fragments(line, "12 |"));
}

fn expand_tabs(line: []const u8, tab_width: usize) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    try text_manip.write_tabs_expanded(&result.writer, line, tab_width);
    return result.toOwnedSlice();
}

test "write_tabs_expanded: lines without tabs are copied unchanged" {
    const line = "no tabs here";
    const expanded = try expand_tabs(line, 4);
    defer allocator.free(expanded);
    try expectEqualStrings(line, expanded);
}

test "write_tabs_expanded: expands to the next tab stop" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "\tx", .expected = "    x" },
        .{ .input = "a\tb", .expected = "a   b" },
        .{ .input = "abcd\te", .expected = "abcd    e" },
        .{ .input = "ab\tcd\tef", .expected = "ab  cd  ef" },
    };
    for (cases) |case| {
        const expanded = try expand_tabs(case.input, 4);
        defer allocator.free(expanded);
        try expectEqualStrings(case.expected, expanded);
    }
}

test "write_tabs_expanded: zero tab width is treated as one" {
    const expanded = try expand_tabs("a\tb", 0);
    defer allocator.free(expanded);
    try expectEqualStrings("a b", expanded);
}

test "compiled query: agrees with line_matches_fragments" {
    const line = "fn ReadFile(path) void";
    const queries = [_][]const u8{
        "readfile", "ReadFile", "Readfile", "VOID ReadFile", "void ReadFile", "PATH", "  ",
    };
    for (queries) |query| {
        const compiled = text_manip.compile_query(query);
        try std.testing.expectEqual(text_manip.line_matches_fragments(line, query), compiled.matches(line, text_manip.has_unicode_upper(line)));
    }
}

test "compiled query: over 32 fragments are matched uncompiled" {
    const limit = 32;
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(allocator);
    for (0..limit) |i| {
        if (i > 0) try query.append(allocator, ' ');
        try query.append(allocator, 'a');
    }
    const at_limit = text_manip.compile_query(query.items);
    try std.testing.expect(!at_limit.overflow);
    try std.testing.expectEqual(@as(usize, limit), at_limit.len);

    try query.append(allocator, ' ');
    try query.append(allocator, 'a');
    const over_limit = text_manip.compile_query(query.items);
    try std.testing.expect(over_limit.overflow);
    try std.testing.expectEqual(@as(usize, 0), over_limit.len);
    try std.testing.expect(over_limit.needs_prefix);
    try std.testing.expect(over_limit.needs_number);
    try std.testing.expect(over_limit.matches("a", false));
    try std.testing.expect(!over_limit.matches("b", false));
}

test "compiled query: overflow path filters lines and numbers" {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(allocator);
    for (0..40) |i| {
        if (i > 0) try query.append(allocator, ' ');
        try query.append(allocator, 'a');
    }
    const compiled = text_manip.compile_query(query.items);
    try std.testing.expect(compiled.overflow);
    const cases = [_]struct { line: []const u8, expected: bool }{
        .{ .line = "", .expected = false },
        .{ .line = "a", .expected = true },
        .{ .line = "A", .expected = true },
        .{ .line = "b", .expected = false },
        .{ .line = "aaa", .expected = true },
        .{ .line = "İa", .expected = true },
        .{ .line = "İz", .expected = false },
    };
    for (cases) |case|
        try std.testing.expectEqual(case.expected, compiled.matches(case.line, text_manip.has_unicode_upper(case.line)));

    try query.appendSlice(allocator, " 12");
    const with_number = text_manip.compile_query(query.items);
    try std.testing.expect(with_number.overflow);
    try std.testing.expect(with_number.matches_with_number("12", "a", false));
    try std.testing.expect(with_number.matches_with_number("12", "a", true));
    try std.testing.expect(!with_number.matches_with_number("13", "a", false));
    try std.testing.expect(!with_number.matches_with_number("12", "b", false));
    try std.testing.expect(!with_number.matches_with_number("12", "İz", true));
}

test "line_matches_fragments: folded search crosses vector boundaries" {
    const lengths = [_]usize{ 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127 };
    for (lengths) |len| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendNTimes(allocator, 'x', len);
        try line.appendSlice(allocator, "Needle");
        try std.testing.expect(text_manip.line_matches_fragments(line.items, "needle"));

        line.clearRetainingCapacity();
        try line.appendNTimes(allocator, 'N', len);
        try line.appendSlice(allocator, "eedle");
        try std.testing.expect(text_manip.line_matches_fragments(line.items, "needle"));
        try std.testing.expect(!text_manip.line_matches_fragments(line.items, "zed"));
        try std.testing.expect(!text_manip.line_matches_fragments(line.items, "needleZ"));
    }
}

test "line_matches_fragments: smartcase per fragment" {
    const line = "fn ReadFile(path) void";
    try std.testing.expect(text_manip.line_matches_fragments(line, "readfile"));
    try std.testing.expect(text_manip.line_matches_fragments(line, "ReadFile"));
    try std.testing.expect(!text_manip.line_matches_fragments(line, "Readfile"));
    try std.testing.expect(!text_manip.line_matches_fragments(line, "VOID ReadFile"));
    try std.testing.expect(text_manip.line_matches_fragments(line, "void ReadFile"));
    try std.testing.expect(!text_manip.line_matches_fragments(line, "PATH"));
}

test "line_matches_fragments: smartcase folds only all-lowercase fragments" {
    try std.testing.expect(text_manip.line_matches_fragments("foo2", "foo2"));
    try std.testing.expect(text_manip.line_matches_fragments("FOO2", "FOO2"));
    try std.testing.expect(!text_manip.line_matches_fragments("FOO2", "foo2"));
    try std.testing.expect(!text_manip.line_matches_fragments("foo2", "FOO2"));
    try std.testing.expect(text_manip.line_matches_fragments("FOO BAR", "foo bar"));
    try std.testing.expect(text_manip.line_matches_fragments("foo_bar", "foo_bar"));
    try std.testing.expect(!text_manip.line_matches_fragments("FOO_BAR", "foo_bar"));
    try std.testing.expect(!text_manip.line_matches_fragments("FOO-BAR", "foo-bar"));
}

test "compiled query: matches ad's numbered line" {
    const line = "const value = 42;";
    const number = "12";
    const cases = [_]struct { query: []const u8, needs_prefix: bool, expected: bool }{
        .{ .query = "12", .needs_prefix = true, .expected = true },
        .{ .query = "13", .needs_prefix = true, .expected = false },
        .{ .query = "1", .needs_prefix = true, .expected = true },
        .{ .query = "|", .needs_prefix = true, .expected = true },
        .{ .query = "||", .needs_prefix = false, .expected = false },
        .{ .query = "12 |", .needs_prefix = true, .expected = true },
        .{ .query = "12 value", .needs_prefix = true, .expected = true },
        .{ .query = "12 | value", .needs_prefix = true, .expected = true },
        .{ .query = "13 value", .needs_prefix = true, .expected = false },
        .{ .query = "|value", .needs_prefix = false, .expected = false },
        .{ .query = "value", .needs_prefix = false, .expected = true },
        .{ .query = "missing", .needs_prefix = false, .expected = false },
        .{ .query = "42", .needs_prefix = true, .expected = true },
    };
    for (cases) |case| {
        const compiled = text_manip.compile_query(case.query);
        try std.testing.expectEqual(case.needs_prefix, compiled.needs_prefix);
        try std.testing.expectEqual(case.expected, compiled.matches_with_number(number, line, false));
    }
}

fn naive_line_matches(line: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |fragment| {
        var sensitive = false;
        for (fragment) |c| if (!std.ascii.isLower(c)) {
            sensitive = true;
            break;
        };
        if (sensitive) {
            if (std.mem.find(u8, line, fragment) == null) return false;
        } else {
            var found = false;
            if (fragment.len <= line.len) {
                var i: usize = 0;
                while (i + fragment.len <= line.len) : (i += 1) {
                    if (std.ascii.eqlIgnoreCase(line[i..][0..fragment.len], fragment)) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) return false;
        }
    }
    return true;
}

test "line_matches_fragments: agrees with the naive rule on short and long lines" {
    const lines = [_][]const u8{
        "",
        "a",
        "A",
        "abc",
        "Needle in a haystack",
        "naysayer needle",
        "needle NEEDLE Needle",
        "0123456789",
        "!@#$%^&*()",
        "line with\ttabs\tand text",
        "aBcDeFgHiJkLmNoPqRsTuVwXyZ",
        "\x80\x81\xfe\xff needle \x80",
    };
    // Crosses a vector block: non-matching first bytes, full match at the end.
    var long_line: std.ArrayList(u8) = .empty;
    defer long_line.deinit(allocator);
    try long_line.appendSlice(allocator, "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn");
    try long_line.appendSlice(allocator, " not here, but Needle appears at the end");

    const queries = [_][]const u8{
        "n", "N",    "ne", "NE", "nee", "Needle", "needle",     "NEEDLE",
        "e", "E",    "7",  "!",  " ",   "a b",    "needle not", "xyz",
        "0", "\x80",
    };
    for (lines) |line| {
        for (queries) |q|
            try std.testing.expectEqual(naive_line_matches(line, q), text_manip.line_matches_fragments(line, q));
    }
    for (queries) |q|
        try std.testing.expectEqual(naive_line_matches(long_line.items, q), text_manip.line_matches_fragments(long_line.items, q));
}

test "query_extends: only prefix extensions" {
    try std.testing.expect(text_manip.query_extends("", "a"));
    try std.testing.expect(text_manip.query_extends("a", "ab"));
    try std.testing.expect(text_manip.query_extends("a", "a "));
    try std.testing.expect(text_manip.query_extends("a ", "a b"));
    try std.testing.expect(text_manip.query_extends("aB", "aBc"));
    try std.testing.expect(!text_manip.query_extends("ab", "ab"));
    try std.testing.expect(!text_manip.query_extends("ab", "a"));
    try std.testing.expect(!text_manip.query_extends("ab", "aB"));
    try std.testing.expect(!text_manip.query_extends("abc", "ab c"));
}

test "query_extends: a split UTF-8 space is not an extension" {
    const prev = "a\xE3\x80";
    const next = "a\u{3000}";
    try std.testing.expect(!text_manip.query_extends(prev, next));
    try std.testing.expect(text_manip.line_matches_fragments("a", next));
    try std.testing.expect(!text_manip.line_matches_fragments("a", prev));
}

test "has_non_ascii: finds a high byte at any offset" {
    try std.testing.expect(!text_manip.has_non_ascii(""));
    try std.testing.expect(text_manip.has_non_ascii("\x80"));
    const lengths = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65 };
    for (lengths) |len| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.appendNTimes(allocator, 'x', len);
        try std.testing.expect(!text_manip.has_non_ascii(text.items));
        try text.appendSlice(allocator, "\u{17C}");
        try std.testing.expect(text_manip.has_non_ascii(text.items));
    }
}

test "query_extends: longer queries match a subset" {
    const lines = [_][]const u8{
        "ab",   "a b",    "aB",       "Ab",       "ab c",    "xayb",
        "line", "line 0", "line 012", "LINE 012", "nee dle", "needle",
    };
    const pairs = [_]struct { prev: []const u8, next: []const u8 }{
        .{ .prev = "a", .next = "ab" },
        .{ .prev = "a", .next = "a b" },
        .{ .prev = "a", .next = "aB" },
        .{ .prev = "A", .next = "Ab" },
        .{ .prev = "aB", .next = "aBc" },
        .{ .prev = "line", .next = "line 0" },
        .{ .prev = "line 0", .next = "line 012" },
        .{ .prev = "nee", .next = "needle" },
        .{ .prev = "a ", .next = "a b" },
    };
    for (pairs) |pair| {
        try std.testing.expect(text_manip.query_extends(pair.prev, pair.next));
        for (lines) |line| {
            if (text_manip.line_matches_fragments(line, pair.next))
                try std.testing.expect(text_manip.line_matches_fragments(line, pair.prev));
        }
    }
}

test "line_matches_fragments: Unicode case like Rust's to_lowercase" {
    // Expected values come from ad's filter run in Rust.
    const cases = [_]struct { line: []const u8, query: []const u8, expected: bool }{
        .{ .line = "Żółw", .query = "żółw", .expected = true },
        .{ .line = "ŻÓŁW", .query = "żółw", .expected = true },
        .{ .line = "żółw", .query = "Żółw", .expected = false },
        .{ .line = "ÀB", .query = "àb", .expected = true },
        .{ .line = "CAFÉ", .query = "café", .expected = true },
        .{ .line = "café", .query = "CAFÉ", .expected = false },
        .{ .line = "İz", .query = "iz", .expected = false },
        .{ .line = "İz", .query = "i\u{307}z", .expected = false },
        .{ .line = "İz", .query = "i", .expected = true },
        .{ .line = "KELVIN", .query = "kelvin", .expected = true },
        .{ .line = "\u{212A}ELVIN", .query = "kelvin", .expected = true },
        .{ .line = "ΟΔΟΣ", .query = "οδος", .expected = true },
        .{ .line = "ΟΔΟΣ", .query = "οδοσ", .expected = false },
        .{ .line = "ΣΑ", .query = "σα", .expected = true },
        .{ .line = "ΣΑ", .query = "ςα", .expected = false },
        .{ .line = "A.Σ", .query = "a.ς", .expected = false },
        .{ .line = "AΣ.B", .query = "aσ.b", .expected = false },
        .{ .line = "xa yb", .query = "a\u{3000}b", .expected = true },
        .{ .line = "a\u{3000}b", .query = "a", .expected = true },
        .{ .line = "ºx", .query = "ºx", .expected = true },
        .{ .line = "ǅ", .query = "ǆ", .expected = true },
        .{ .line = "Ⅷ", .query = "ⅷ", .expected = true },
        .{ .line = "a\u{a0}b", .query = "a b", .expected = true },
        .{ .line = "KELVIN", .query = "foo", .expected = false },
        .{ .line = "\u{212A}ELVIN", .query = "foo", .expected = false },
        .{ .line = "İz", .query = "z", .expected = true },
        .{ .line = "İz", .query = "zz", .expected = false },
        .{ .line = "ΟΔΟΣ", .query = "ο", .expected = true },
        .{ .line = "İz", .query = "k", .expected = false },
        .{ .line = "\u{212A}ELVIN", .query = "i", .expected = true },
        .{ .line = "İz", .query = "i\u{307}", .expected = false },
        .{ .line = "aİz", .query = "iz", .expected = false },
        .{ .line = "\u{212A}ELVIN", .query = "k", .expected = true },
        .{ .line = "ΟΔΟΣ", .query = "ος", .expected = true },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, text_manip.line_matches_fragments(case.line, case.query));
        const compiled = text_manip.compile_query(case.query);
        try std.testing.expectEqual(case.expected, compiled.matches(case.line, text_manip.has_unicode_upper(case.line)));
    }
}

test "compiled query: Unicode lines on both sides of the buffer limit" {
    // 683 bytes still fit the 1024-byte lowercase buffer, 702 bytes do not.
    for ([_]usize{ 681, 700 }) |x_count| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendNTimes(allocator, 'x', x_count);
        try buf.appendSlice(allocator, "\u{130}");
        const line = buf.items;
        const upper = text_manip.has_unicode_upper(line);
        try std.testing.expect(upper);
        try std.testing.expect(text_manip.line_matches_fragments(line, "i"));
        try std.testing.expect(text_manip.compile_query("i").matches(line, upper));
        try std.testing.expect(!text_manip.line_matches_fragments(line, "k"));
        try std.testing.expect(text_manip.line_matches_fragments(line, "x"));
        try std.testing.expect(!text_manip.line_matches_fragments(line, "i\u{307}"));
    }
}

test "compiled query: Unicode text and line number" {
    const line = "Żółw";
    const upper = text_manip.has_unicode_upper(line);
    const query = text_manip.compile_query("12 żółw");
    try std.testing.expect(query.matches_with_number("12", line, upper));
    try std.testing.expect(!query.matches_with_number("13", line, upper));

    const greek = text_manip.compile_query("4 οδος");
    try std.testing.expect(greek.matches_with_number("4", "ΟΔΟΣ", text_manip.has_unicode_upper("ΟΔΟΣ")));
}
