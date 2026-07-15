const std = @import("std");
const fl = @import("file_link");

test "find_in_line: empty string" {
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_in_line(""));
}

test "find_in_line: no valid link" {
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_in_line("just some plain text"));
}

test "find_in_line: dots only is not a link" {
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_in_line("..."));
}

test "find_in_line: slashes only is not a link" {
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_in_line("//"));
}

test "find_in_line: dots and slashes only is not a link" {
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_in_line("../"));
}

test "find_in_line: mixed dots-slashes tokens in text are skipped" {
    const text = "see ... // ./ src/file_link.zig for details";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/file_link.zig", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expect(dest.file.exists);
}

test "find_in_line: bare file:line" {
    const text = "main.zig:42";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("main.zig:42", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 42), dest.file.line);
}

test "find_in_line: file:line:col" {
    const text = "src/main.zig:10:5";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: file:line:col:end_col" {
    const text = "src/main.zig:10:5:12";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5:12", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
    try std.testing.expectEqual(@as(?usize, 12), dest.file.end_column);
}

test "find_in_line: bracket-style file(line,col)" {
    const text = "src/main.zig(10,5)";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig(10,5)", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: byte-offset style" {
    const text = "src/main.zig:b1024";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:b1024", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 1024), dest.file.offset);
}

test "find_in_line: link inside error message" {
    const text = "error: src/main.zig:10:5: undefined identifier";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: trailing colon stripped" {
    const text = "src/main.zig:10:5: error: foo";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: trailing slashes stripped" {
    const text = "src/main.zig:10:5:/// error: foo";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: trailing misc stripped" {
    const text = "src/main.zig:10:5:$@1a!";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: surrounded by double quotes" {
    const text =
        \\"src/main.zig:10:5"
    ;
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: surrounded by parentheses" {
    const text = "(src/main.zig:10:5)";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: surrounded by quotes and parentheses" {
    const text = "(\"src/main.zig:10:5\")";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: surrounded by parentheses and quotes" {
    const text = "\"(src/main.zig:10:5)\"";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: link with trailing comma" {
    const text = "see src/main.zig:10:5, for details";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: link with no trailing colon" {
    const text = "see src/main.zig:10:5 for details";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: link with unbalanced parentheses" {
    const text = "std.testing.expectEqualStrings(\"src/main.zig:10:5\", text[r.start..r.end]);";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: link with trailing garbage" {
    const text = "       src/main.zig:10:5␃";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_in_line: link with garbage row segment" {
    const text = "       src/main.zig:10aa:5␃";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, null), dest.file.column);
}

test "find_in_line: returns first valid link" {
    const text = "build.zig:3 and src/main.zig:10:5";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("build.zig:3", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 3), dest.file.line);
}

test "find_in_line: return first then second valid link" {
    const text = "build.zig:3 and src/main.zig:10:5";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("build.zig:3", text[r.start..r.end]);
    const r2 = fl.find_in_line(text[r.end..]) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.end..][r2.start..r2.end]);
    const dest2 = try fl.parse(text[r.end..][r2.start..r2.end]);
    try std.testing.expect(dest2 == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest2.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest2.file.column);
}

test "find_in_line: skips non-link tokens to reach link" {
    const text = "error: src/main.zig:7";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:7", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 7), dest.file.line);
}

test "find_at_point: point within link" {
    const text = "error: src/main.zig:10:5: message";
    const r = fl.find_at_point(text, 15) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_at_point: point at first char of link" {
    const text = "error: src/main.zig:10:5: message";
    const link_start = std.mem.indexOf(u8, text, "src").?;
    const r = fl.find_at_point(text, link_start) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_at_point: point at last char of link" {
    const text = "src/main.zig:10:5";
    const r = fl.find_at_point(text, text.len - 1) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_at_point: point on whitespace returns null" {
    const text = "error: src/main.zig:10:5: message";
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_at_point(text, 6));
}

test "find_at_point: point on non-link token returns null" {
    const text = "error: src/main.zig:10:5";
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_at_point(text, 2));
}

test "find_at_point: point beyond string length returns null" {
    const text = "src/main.zig:10";
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_at_point(text, text.len + 5));
}

test "find_at_point: point on leading trim char finds inner link" {
    const text = "(src/main.zig:10:5)";
    const r = fl.find_at_point(text, 0) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_at_point: bracket-style link" {
    const text = "see src/main.zig(10,5) for details";
    const r = fl.find_at_point(text, 8) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig(10,5)", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_at_point: point at start of standalone link" {
    const text = "src/main.zig:10";
    const r = fl.find_at_point(text, 0) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
}

test "find_in_line: plain filename" {
    const text = "build.zig";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("build.zig", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expect(dest.file.exists);
}

test "find_in_line: plain path with directory" {
    const text = "src/file_link.zig";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/file_link.zig", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expect(dest.file.exists);
}

test "find_in_line: plain filename in sentence" {
    const text = "see src/file_link.zig for details";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/file_link.zig", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expect(dest.file.exists);
}

test "find_at_point: point within plain filename" {
    const text = "src/file_link.zig";
    const r = fl.find_at_point(text, 5) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/file_link.zig", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expect(dest.file.exists);
}

test "find_at_point: plain path that does not exist is found but parse shows it absent" {
    const text = "no_such_file.zig";
    const r = fl.find_at_point(text, 0) orelse return error.NotFound;
    try std.testing.expectEqualStrings("no_such_file.zig", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expect(!dest.file.exists);
}

test "find_in_line: escaped space kept in colon-style link" {
    const text = "my\\ file.zig:10";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("my\\ file.zig:10", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
}

test "find_in_line: escaped space in link inside text" {
    const text = "error at my\\ file.zig:10:5 done";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("my\\ file.zig:10:5", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
}

test "find_at_point: point before escaped space" {
    const text = "my\\ file.zig:10";
    // point 1 is 'y', before the backslash, still within the same token
    const r = fl.find_at_point(text, 1) orelse return error.NotFound;
    try std.testing.expectEqualStrings("my\\ file.zig:10", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
}

test "find_at_point: point on escaped space" {
    const text = "my\\ file.zig:10";
    // point 3 is the space after the backslash, part of the token, not a separator
    const r = fl.find_at_point(text, 3) orelse return error.NotFound;
    try std.testing.expectEqualStrings("my\\ file.zig:10", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
}

test "find_at_point: point after escaped space" {
    const text = "my\\ file.zig:10";
    // point 4 is 'f', after the escaped space, same token
    const r = fl.find_at_point(text, 4) orelse return error.NotFound;
    try std.testing.expectEqualStrings("my\\ file.zig:10", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
}

test "find_at_point: unescaped space is still a separator" {
    const text = "my file.zig:10";
    // point 2 is the unescaped space, should return null (it's a separator)
    try std.testing.expectEqual(@as(?fl.Range, null), fl.find_at_point(text, 2));
}

test "find_in_line: file:line:col:end_line:end_col" {
    const text = "src/main.zig:10:5:12:9";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5:12:9", text[r.start..r.end]);
    const dest = try fl.parse(text[r.start..r.end]);
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 10), dest.file.line);
    try std.testing.expectEqual(@as(?usize, 5), dest.file.column);
    try std.testing.expectEqual(@as(?usize, 12), dest.file.end_line);
    try std.testing.expectEqual(@as(?usize, 9), dest.file.end_column);
}

test "parse: three numbers leave end_line unset" {
    const dest = try fl.parse("src/main.zig:10:5:12");
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 12), dest.file.end_column);
    try std.testing.expectEqual(@as(?usize, null), dest.file.end_line);
}

test "parse: a non numeric fourth segment is not an end column" {
    const dest = try fl.parse("src/main.zig:10:5:12:oops");
    try std.testing.expect(dest == .file);
    try std.testing.expectEqual(@as(?usize, 12), dest.file.end_column);
    try std.testing.expectEqual(@as(?usize, null), dest.file.end_line);
}

test "find_in_line: fifth number is not part of the link" {
    const text = "src/main.zig:10:5:12:9:7";
    const r = fl.find_in_line(text) orelse return error.NotFound;
    try std.testing.expectEqualStrings("src/main.zig:10:5:12:9", text[r.start..r.end]);
}
