const std = @import("std");
const Snippet = @import("snippet");

const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "bare tabstop" {
    const parsed = try Snippet.parse(allocator, "a$1b");
    defer parsed.deinit(allocator);
    try expectEqualStrings("ab", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(1, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "braced tabstop without placeholder" {
    const parsed = try Snippet.parse(allocator, "System.out.println(${0});");
    defer parsed.deinit(allocator);
    try expectEqualStrings("System.out.println();", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(19, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "braced tabstop with placeholder" {
    const parsed = try Snippet.parse(allocator, "for (${1:item}) {}");
    defer parsed.deinit(allocator);
    try expectEqualStrings("for (item) {}", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(5, parsed.tabstops[0][0].begin[0]);
    try expectEqual(9, parsed.tabstops[0][0].end.?[0]);
}

test "mixed braced tabstops" {
    const parsed = try Snippet.parse(allocator, "${1} and ${2:two}");
    defer parsed.deinit(allocator);
    try expectEqualStrings(" and two", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
    try expectEqual(5, parsed.tabstops[1][0].begin[0]);
    try expectEqual(8, parsed.tabstops[1][0].end.?[0]);
}

test "trailing bare tabstop" {
    const parsed = try Snippet.parse(allocator, "foo($1)$0");
    defer parsed.deinit(allocator);
    try expectEqualStrings("foo()", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(4, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
    try expectEqual(5, parsed.tabstops[1][0].begin[0]);
    try expect(parsed.tabstops[1][0].end == null);
}

test "tabstop zero is ordered last" {
    const parsed = try Snippet.parse(allocator, "a${0}b${1}c");
    defer parsed.deinit(allocator);
    try expectEqualStrings("abc", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(2, parsed.tabstops[0][0].begin[0]); // ${1}
    try expectEqual(1, parsed.tabstops[1][0].begin[0]); // ${0}
}

test "repeated tabstop id is grouped" {
    const parsed = try Snippet.parse(allocator, "${1:a} $1");
    defer parsed.deinit(allocator);
    try expectEqualStrings("a ", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(2, parsed.tabstops[0].len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expectEqual(1, parsed.tabstops[0][0].end.?[0]);
    try expectEqual(2, parsed.tabstops[0][1].begin[0]);
    try expect(parsed.tabstops[0][1].end == null);
}

test "bare tabstop followed by a brace literal" {
    const parsed = try Snippet.parse(allocator, "$1{}");
    defer parsed.deinit(allocator);
    try expectEqualStrings("{}", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "escaped dollar is literal" {
    const parsed = try Snippet.parse(allocator, "\\$1");
    defer parsed.deinit(allocator);
    try expectEqualStrings("$1", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "allocation failure does not leak" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = fail_index });
        const parsed = Snippet.parse(failing.allocator(), "a${1:one} $1 ${2} ${0}") catch continue;
        parsed.deinit(failing.allocator());
    }
}

test "empty braced tabstop is invalid" {
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "${}"));
}

test "tabstop without id is invalid" {
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "$x"));
}

test "unterminated placeholder is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "${1:foo"));
}

test "trailing dollar is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "foo$"));
}
