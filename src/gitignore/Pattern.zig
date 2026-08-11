const std = @import("std");
const wildmatch = @import("wildmatch.zig");

const Pattern = @This();

pub const Flags = packed struct(u8) {
    negative: bool = false, // leading '!'
    must_be_dir: bool = false, // trailing '/'
    no_dir: bool = false, // no '/' beginning in the pattern, so match the basename at any depth
    ends_with: bool = false, // "*literal", so a basename match is a suffix compare
    _reserved: u4 = 0,
};

text: []const u8, // trimmed leading `!` and trailing `/`
raw: []const u8,
no_wildcard_len: u32,
line_no: u32,
flags: Flags,
compiled: ?wildmatch.Compiled, // null for a pure literal

fn simple_length(s: []const u8) u32 {
    for (s, 0..) |c, i| switch (c) {
        '*', '?', '[', '\\' => return @intCast(i),
        else => {},
    };
    return @intCast(s.len);
}

fn no_wildcard(s: []const u8) bool {
    return simple_length(s) == s.len;
}

fn trim_trailing_spaces(buf: []const u8) []const u8 {
    var last_space: ?usize = null;
    var p: usize = 0;
    while (p < buf.len) : (p += 1) {
        switch (buf[p]) {
            ' ' => if (last_space == null) {
                last_space = p;
            },
            '\\' => {
                p += 1;
                if (p >= buf.len) return buf;
                last_space = null;
            },
            else => last_space = null,
        }
    }
    return if (last_space) |i| buf[0..i] else buf;
}

pub fn parse(gpa: std.mem.Allocator, raw: []const u8, line_no: u32) wildmatch.CompileError!?Pattern {
    // tested before any unescaping, so "\#foo" survives as a pattern
    if (raw.len == 0) return null;
    if (raw[0] == '#') return null;

    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    line = trim_trailing_spaces(line);
    if (line.len == 0) return null;
    const raw_trimmed = line;

    var flags: Flags = .{};
    if (line[0] == '!') {
        flags.negative = true;
        line = line[1..];
    }
    if (line.len > 0 and line[line.len - 1] == '/') {
        flags.must_be_dir = true;
        line = line[0 .. line.len - 1];
    }

    flags.no_dir = std.mem.indexOfScalar(u8, line, '/') == null;

    var nwl = simple_length(line);
    if (nwl > line.len) nwl = @intCast(line.len);
    if (line.len > 0 and line[0] == '*' and no_wildcard(line[1..])) flags.ends_with = true;

    return .{
        .text = line,
        .raw = raw_trimmed,
        .no_wildcard_len = nwl,
        .line_no = line_no,
        .flags = flags,
        .compiled = if (nwl == line.len) null else try wildmatch.compile(gpa, line),
    };
}

pub fn deinit(self: *Pattern, gpa: std.mem.Allocator) void {
    if (self.compiled) |*c| c.deinit(gpa);
    self.compiled = null;
}

pub fn match_basename(self: *const Pattern, basename: []const u8, opts: wildmatch.Options) bool {
    if (self.no_wildcard_len == self.text.len)
        return wildmatch.eql(self.text, basename, opts);
    if (self.flags.ends_with) {
        const suffix = self.text[1..];
        return suffix.len <= basename.len and
            wildmatch.eql(suffix, basename[basename.len - suffix.len ..], opts);
    }
    return wildmatch.match(&self.compiled.?, basename, opts);
}

pub fn match_pathname(
    self: *const Pattern,
    rel: []const u8,
    base: []const u8, // the directory the owning list is anchored to
    opts: wildmatch.Options,
) bool {
    var pat = self.text;
    var nwl = self.no_wildcard_len;
    if (pat.len > 0 and pat[0] == '/') {
        pat = pat[1..]; // the base already supplies the anchor
        nwl -|= 1;
    }

    var name = rel;
    if (base.len > 0) {
        if (rel.len <= base.len) return false;
        if (rel[base.len] != '/') return false;
        if (!wildmatch.eql(rel[0..base.len], base, opts)) return false;
        name = rel[base.len + 1 ..];
    }

    if (nwl > 0) {
        if (nwl > name.len) return false;
        if (!wildmatch.eql(pat[0..nwl], name[0..nwl], opts)) return false;
    }
    if (self.compiled) |*c| return wildmatch.match(c, name, opts);
    return pat.len == name.len; // pure literal, already compared above
}

const testing = std.testing;

fn parse_one(raw: []const u8) !Pattern {
    return (try parse(testing.allocator, raw, 1)).?;
}

test "skipped lines" {
    try testing.expect(try parse(testing.allocator, "", 1) == null);
    try testing.expect(try parse(testing.allocator, "#comment", 1) == null);
    try testing.expect(try parse(testing.allocator, "#", 1) == null);
    try testing.expect(try parse(testing.allocator, "   ", 1) == null);
    try testing.expect(try parse(testing.allocator, "\r", 1) == null);
}

test "leading whitespace does not make a comment" {
    var p = try parse_one("  # foo");
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("  # foo", p.text);
}

test "escaped comment and bang markers survive" {
    var h = try parse_one("\\#foo");
    defer h.deinit(testing.allocator);
    try testing.expectEqualStrings("\\#foo", h.text);
    try testing.expect(!h.flags.negative);
    // the backslash forces it through wildmatch rather than a literal compare
    try testing.expectEqual(@as(u32, 0), h.no_wildcard_len);
    try testing.expect(h.match_basename("#foo", .{}));

    var b = try parse_one("\\!foo");
    defer b.deinit(testing.allocator);
    try testing.expect(!b.flags.negative);
    try testing.expect(b.match_basename("!foo", .{}));
}

test "negation" {
    var p = try parse_one("!foo");
    defer p.deinit(testing.allocator);
    try testing.expect(p.flags.negative);
    try testing.expectEqualStrings("foo", p.text);
}

test "trailing whitespace" {
    var a = try parse_one("foo   ");
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("foo", a.text);

    // an escaped space is kept
    var b = try parse_one("foo\\ ");
    defer b.deinit(testing.allocator);
    try testing.expect(b.match_basename("foo ", .{}));

    // a tab is NOT trailing whitespace for git
    var c = try parse_one("foo\t");
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("foo\t", c.text);
    try testing.expect(!c.match_basename("foo", .{}));

    // "foo \" keeps the backslash, which makes the pattern unmatchable
    var d = try parse_one("foo \\");
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("foo \\", d.text);
    try testing.expect(!d.match_basename("foo", .{}));
    try testing.expect(!d.match_basename("foo ", .{}));
}

test "carriage return is stripped" {
    var p = try parse_one("foo\r");
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("foo", p.text);
}

test "raw keeps what check-ignore -v reports" {
    // git prints the trimmed line including the '!' and the trailing '/'
    const cases = [_]struct { raw: []const u8, reported: []const u8 }{
        .{ .raw = "a/", .reported = "a/" },
        .{ .raw = "!a", .reported = "!a" },
        .{ .raw = "/a", .reported = "/a" },
        .{ .raw = "*.log", .reported = "*.log" },
        .{ .raw = "a  ", .reported = "a" },
        .{ .raw = "a\\ ", .reported = "a\\ " },
        .{ .raw = "!keep.log", .reported = "!keep.log" },
    };
    for (cases) |c| {
        var p = try parse_one(c.raw);
        defer p.deinit(testing.allocator);
        try testing.expectEqualStrings(c.reported, p.raw);
    }
}

test "anchoring and dtype flag matrix" {
    // The four-way split that the parse order has to produce.
    const Case = struct { raw: []const u8, must_be_dir: bool, no_dir: bool, text: []const u8 };
    const cases = [_]Case{
        .{ .raw = "/foo/", .must_be_dir = true, .no_dir = false, .text = "/foo" },
        .{ .raw = "/foo", .must_be_dir = false, .no_dir = false, .text = "/foo" },
        .{ .raw = "foo/", .must_be_dir = true, .no_dir = true, .text = "foo" },
        .{ .raw = "foo", .must_be_dir = false, .no_dir = true, .text = "foo" },
    };
    for (cases) |c| {
        var p = try parse_one(c.raw);
        defer p.deinit(testing.allocator);
        try testing.expectEqual(c.must_be_dir, p.flags.must_be_dir);
        try testing.expectEqual(c.no_dir, p.flags.no_dir);
        try testing.expectEqualStrings(c.text, p.text);
    }
}

test "anchored patterns match relative to the base" {
    var p = try parse_one("/foo");
    defer p.deinit(testing.allocator);
    try testing.expect(p.match_pathname("foo", "", .{}));
    try testing.expect(!p.match_pathname("sub/foo", "", .{}));
    // the same pattern in sub/.gitignore anchors to sub/
    try testing.expect(p.match_pathname("sub/foo", "sub", .{}));
    try testing.expect(!p.match_pathname("foo", "sub", .{}));
    try testing.expect(!p.match_pathname("sub/deep/foo", "sub", .{}));
}

test "unanchored patterns match a basename at any depth" {
    var p = try parse_one("foo");
    defer p.deinit(testing.allocator);
    try testing.expect(p.flags.no_dir);
    try testing.expect(p.match_basename("foo", .{}));
    try testing.expect(!p.match_basename("foo_file", .{}));
    try testing.expect(!p.match_basename("xfoo", .{}));
}

test "embedded slash anchors" {
    var p = try parse_one("a/b");
    defer p.deinit(testing.allocator);
    try testing.expect(!p.flags.no_dir);
    try testing.expect(p.match_pathname("a/b", "", .{}));
    try testing.expect(!p.match_pathname("x/a/b", "", .{}));
}

test "ends_with fast path" {
    var p = try parse_one("*.log");
    defer p.deinit(testing.allocator);
    try testing.expect(p.flags.ends_with);
    try testing.expect(p.match_basename("x.log", .{}));
    try testing.expect(p.match_basename(".log", .{}));
    try testing.expect(!p.match_basename("log", .{}));
    try testing.expect(!p.match_basename("x.logg", .{}));
}

test "lone bang and lone slash are inert" {
    var b = try parse_one("!");
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), b.text.len);
    try testing.expect(!b.match_basename("anything", .{}));

    var s = try parse_one("/");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.text.len);
    try testing.expect(s.flags.must_be_dir);
    try testing.expect(!s.match_basename("anything", .{}));
    try testing.expect(!s.match_pathname("anything", "", .{}));
}
