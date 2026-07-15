const std = @import("std");
const Snippet = @import("snippet");

const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "bare tabstop" {
    const parsed = try Snippet.parse(allocator, "a$1b", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("ab", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(1, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "braced tabstop without placeholder" {
    const parsed = try Snippet.parse(allocator, "System.out.println(${0});", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("System.out.println();", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(19, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "braced tabstop with placeholder" {
    const parsed = try Snippet.parse(allocator, "for (${1:item}) {}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("for (item) {}", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(5, parsed.tabstops[0][0].begin[0]);
    try expectEqual(9, parsed.tabstops[0][0].end.?[0]);
}

test "mixed braced tabstops" {
    const parsed = try Snippet.parse(allocator, "${1} and ${2:two}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings(" and two", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
    try expectEqual(5, parsed.tabstops[1][0].begin[0]);
    try expectEqual(8, parsed.tabstops[1][0].end.?[0]);
}

test "trailing bare tabstop" {
    const parsed = try Snippet.parse(allocator, "foo($1)$0", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("foo()", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(4, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
    try expectEqual(5, parsed.tabstops[1][0].begin[0]);
    try expect(parsed.tabstops[1][0].end == null);
}

test "tabstop zero is ordered last" {
    const parsed = try Snippet.parse(allocator, "a${0}b${1}c", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("abc", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(2, parsed.tabstops[0][0].begin[0]); // ${1}
    try expectEqual(1, parsed.tabstops[1][0].begin[0]); // ${0}
}

test "sparse tabstop ids keep ascending order" {
    const parsed = try Snippet.parse(allocator, "a${7}b${0}c${3}d${7}e", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("abcde", parsed.text);
    try expectEqual(3, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len); // ${3}
    try expectEqual(3, parsed.tabstops[0][0].begin[0]);
    try expectEqual(2, parsed.tabstops[1].len); // ${7}, both occurrences in order
    try expectEqual(1, parsed.tabstops[1][0].begin[0]);
    try expectEqual(4, parsed.tabstops[1][1].begin[0]);
    try expectEqual(1, parsed.tabstops[2].len); // ${0} last
    try expectEqual(2, parsed.tabstops[2][0].begin[0]);
}

test "repeated tabstop id is grouped" {
    const parsed = try Snippet.parse(allocator, "${1:a} $1", null);
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
    const parsed = try Snippet.parse(allocator, "$1{}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("{}", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0].len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "nested placeholder" {
    const parsed = try Snippet.parse(allocator, "${1:${2:nested}}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("nested", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]); // ${1} spans the whole content
    try expectEqual(6, parsed.tabstops[0][0].end.?[0]);
    try expectEqual(0, parsed.tabstops[1][0].begin[0]); // ${2} spans the same text
    try expectEqual(6, parsed.tabstops[1][0].end.?[0]);
}

test "nested bare tabstop closes its placeholder" {
    const parsed = try Snippet.parse(allocator, "a${1:b$2c}d", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("abcd", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0][0].begin[0]); // ${1} spans "bc"
    try expectEqual(3, parsed.tabstops[0][0].end.?[0]);
    try expectEqual(2, parsed.tabstops[1][0].begin[0]); // $2 sits between b and c
    try expect(parsed.tabstops[1][0].end == null);
}

test "nested placeholder does not clobber the outer id" {
    const parsed = try Snippet.parse(allocator, "${3:x${1:y}z}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("xyz", parsed.text);
    try expectEqual(2, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0][0].begin[0]); // ${1} spans "y"
    try expectEqual(2, parsed.tabstops[0][0].end.?[0]);
    try expectEqual(0, parsed.tabstops[1][0].begin[0]); // ${3} spans "xyz"
    try expectEqual(3, parsed.tabstops[1][0].end.?[0]);
}

test "dollar in placeholder content starts a tabstop" {
    // now that content can nest, a literal '$' must be escaped there, the same
    // as at the top level
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "${1:a $ b}", null));
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "a $ b", null));
    const parsed = try Snippet.parse(allocator, "${1:a \\$ b}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("a $ b", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
}

test "unterminated nested placeholder is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "${1:a$2", null));
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "${1:${2:x}", null));
}

test "escaped dollar is literal" {
    const parsed = try Snippet.parse(allocator, "\\$1", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("$1", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "escaped brace and backslash are literal" {
    const parsed = try Snippet.parse(allocator, "\\\\ and \\}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("\\ and }", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "escaped brace in placeholder content is literal" {
    const parsed = try Snippet.parse(allocator, "${1:a\\}b}", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("a}b", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expectEqual(3, parsed.tabstops[0][0].end.?[0]);
}

test "multi digit tabstop id" {
    const parsed = try Snippet.parse(allocator, "${10}x", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("x", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
}

test "snippet without tabstops" {
    const parsed = try Snippet.parse(allocator, "plain text", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("plain text", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "empty snippet" {
    const parsed = try Snippet.parse(allocator, "", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "allocation failure does not leak" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = fail_index });
        const parsed = Snippet.parse(failing.allocator(), "a${1:one} $1 ${2} ${0}", null) catch continue;
        parsed.deinit(failing.allocator());
    }
}

test "empty braced tabstop is invalid" {
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "${}", null));
}

test "tabstop id followed by a letter is not a variable" {
    const parsed = try Snippet.parse(allocator, "$1a", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("a", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expect(parsed.tabstops[0][0].end == null);
}

test "braced variable with an id prefix is invalid" {
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "${1a}", null));
}

/// SET resolves to a value, EMPTY is defined but unset, anything else is unknown
fn test_resolver(a: std.mem.Allocator, name: []const u8) Snippet.VariableError!?[]const u8 {
    if (std.mem.eql(u8, name, "SET")) return try a.dupe(u8, "value");
    if (std.mem.eql(u8, name, "EMPTY")) return try a.dupe(u8, "");
    return null;
}

test "variable with a value" {
    const parsed = try Snippet.parse(allocator, "a$SET.b", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("avalue.b", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "braced variable with a value" {
    const parsed = try Snippet.parse(allocator, "a${SET}b", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("avalueb", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "variable at end of snippet" {
    const parsed = try Snippet.parse(allocator, "a$SET", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("avalue", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "unset variable falls back to its default" {
    const parsed = try Snippet.parse(allocator, "a${EMPTY:fallback}b", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("afallbackb", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "unset variable without a default inserts nothing" {
    const parsed = try Snippet.parse(allocator, "a${EMPTY}b", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("ab", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "a variable with a value skips its default" {
    const parsed = try Snippet.parse(allocator, "a${SET:skipped}b", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("avalueb", parsed.text);
    try expectEqual(0, parsed.tabstops.len);
}

test "a skipped default drops the tabstops inside it" {
    const parsed = try Snippet.parse(allocator, "${SET:${1:skipped}}$0", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("value", parsed.text);
    try expectEqual(1, parsed.tabstops.len); // only $0 survives
    try expectEqual(5, parsed.tabstops[0][0].begin[0]);
}

test "an unset variable keeps the tabstops in its default" {
    const parsed = try Snippet.parse(allocator, "${EMPTY:${1:kept}}", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("kept", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]);
    try expectEqual(4, parsed.tabstops[0][0].end.?[0]);
}

test "unknown variable becomes a placeholder over its name" {
    const parsed = try Snippet.parse(allocator, "a$UNKNOWN_VAR.b", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("aUNKNOWN_VAR.b", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
    try expectEqual(1, parsed.tabstops[0][0].begin[0]);
    try expectEqual(12, parsed.tabstops[0][0].end.?[0]);
}

test "unknown variables are numbered after the spelled out tabstops" {
    const parsed = try Snippet.parse(allocator, "${2:x} $FOO $BAR ${0}", test_resolver);
    defer parsed.deinit(allocator);
    try expectEqualStrings("x FOO BAR ", parsed.text);
    try expectEqual(4, parsed.tabstops.len);
    try expectEqual(0, parsed.tabstops[0][0].begin[0]); // ${2}
    try expectEqual(2, parsed.tabstops[1][0].begin[0]); // $FOO -> id 3
    try expectEqual(6, parsed.tabstops[2][0].begin[0]); // $BAR -> id 4
    try expectEqual(10, parsed.tabstops[3][0].begin[0]); // ${0} still last
}

test "a resolver is not required" {
    const parsed = try Snippet.parse(allocator, "$SET", null);
    defer parsed.deinit(allocator);
    try expectEqualStrings("SET", parsed.text);
    try expectEqual(1, parsed.tabstops.len);
}

test "tabstop id that overflows is invalid" {
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "${99999999999999999999}", null));
    try expectError(error.InvalidIdValue, Snippet.parse(allocator, "$99999999999999999999", null));
}

test "unterminated placeholder is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "${1:foo", null));
}

test "unterminated braced tabstop is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "${1", null));
}

test "trailing dollar is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "foo$", null));
}

test "trailing escape is invalid" {
    try expectError(error.UnexpectedEndOfDocument, Snippet.parse(allocator, "foo\\", null));
}
