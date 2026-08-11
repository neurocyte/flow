//! git wildcard matching

const std = @import("std");

pub const Options = struct {
    case_insensitive: bool = false, // simple ASCII folding, like git
};

pub const CompileError = error{OutOfMemory};

const Range = struct { off: u32, len: u32 };

const Set = [4]u64;

inline fn set_add(s: *Set, c: u8) void {
    s[c >> 6] |= @as(u64, 1) << @as(u6, @truncate(c));
}

inline fn set_has(s: *const Set, c: u8) bool {
    return s[c >> 6] & (@as(u64, 1) << @as(u6, @truncate(c))) != 0;
}

inline fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

pub const Bracket = struct {
    set: Set = .{ 0, 0, 0, 0 },
    folded: Set = .{ 0, 0, 0, 0 },
    negated: bool = false,

    fn matches(self: *const Bracket, c: u8, opts: Options) bool {
        // never matches '/' whatever the set says
        if (c == '/') return false;
        const hit = if (opts.case_insensitive)
            set_has(&self.folded, lower(c))
        else
            set_has(&self.set, c);
        return hit != self.negated;
    }

    fn add_char(self: *Bracket, c: u8) void {
        set_add(&self.set, c);
        set_add(&self.folded, lower(c));
    }

    fn add_range(self: *Bracket, lo: u8, hi: u8) void {
        var c: usize = lo;
        while (c <= hi) : (c += 1) set_add(&self.set, @intCast(c));
        var f: usize = lower(lo);
        const fe = lower(hi);
        while (f <= fe) : (f += 1) set_add(&self.folded, @intCast(f));
    }

    fn add_class(self: *Bracket, cls: Class) void {
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            if (cls.matches(@intCast(c))) {
                set_add(&self.set, @intCast(c));
                set_add(&self.folded, @intCast(c));
            }
        }
    }
};

/// ASCII-only ctype semantics
const Class = enum {
    alnum,
    alpha,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    xdigit,

    fn matches(self: Class, c: u8) bool {
        const is_upper = c >= 'A' and c <= 'Z';
        const is_lower = c >= 'a' and c <= 'z';
        const is_digit = c >= '0' and c <= '9';
        const is_alpha = is_upper or is_lower;
        const is_alnum = is_alpha or is_digit;
        const is_graph = c >= 0x21 and c <= 0x7e;
        return switch (self) {
            .alnum => is_alnum,
            .alpha => is_alpha,
            .blank => c == ' ' or c == '\t',
            .cntrl => c < 0x20 or c == 0x7f,
            .digit => is_digit,
            .graph => is_graph,
            .lower => is_lower,
            .print => c >= 0x20 and c <= 0x7e,
            .punct => is_graph and !is_alnum,
            .space => c == ' ' or (c >= '\t' and c <= '\r'),
            .upper => is_upper,
            .xdigit => is_digit or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
        };
    }
};

fn class_from_name(name: []const u8) ?Class {
    return std.meta.stringToEnum(Class, name);
}

const Token = union(enum) {
    literal: Range, // escapes already resolved
    any_char,
    star,
    bracket: u32, // index into Compiled.brackets
};

const Component = union(enum) {
    globstar,
    tokens: Range,
};

pub const Compiled = struct {
    comps: []const Component = &.{},
    tokens: []const Token = &.{},
    literals: []const u8 = &.{},
    brackets: []const Bracket = &.{},
    never_matches: bool = false,

    pub fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(self.comps);
        gpa.free(self.tokens);
        gpa.free(self.literals);
        gpa.free(self.brackets);
        self.* = .{};
    }
};

/// index past the closing `]`, or null if not found
fn parse_bracket(pattern: []const u8, start: usize, out: ?*Bracket) ?usize {
    var i = start + 1;
    if (out) |o| o.* = .{};
    // both '!' and '^' negate
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        if (out) |o| o.negated = true;
        i += 1;
    }
    var first = true;
    var prev: ?u8 = null;
    while (i < pattern.len) {
        const c = pattern[i];
        // a ']' in first position is a literal member
        if (c == ']' and !first) return i + 1;
        first = false;
        if (c == '[' and i + 1 < pattern.len and pattern[i + 1] == ':') {
            const close = std.mem.indexOfPos(u8, pattern, i + 2, ":]") orelse return null;
            const cls = class_from_name(pattern[i + 2 .. close]) orelse return null;
            if (out) |o| o.add_class(cls);
            i = close + 2;
            prev = null;
            continue;
        }
        if (c == '\\') {
            if (i + 1 >= pattern.len) return null;
            i += 1;
            if (out) |o| o.add_char(pattern[i]);
            prev = pattern[i];
            i += 1;
            continue;
        }
        // a range needs a preceding member and a follower that is not ']';
        // git then clears prev so `a-c-e` does not chain
        if (c == '-' and prev != null and i + 1 < pattern.len and pattern[i + 1] != ']') {
            i += 1;
            var hi = pattern[i];
            if (hi == '\\') {
                if (i + 1 >= pattern.len) return null;
                i += 1;
                hi = pattern[i];
            }
            if (out) |o| o.add_range(prev.?, hi);
            prev = null;
            i += 1;
            continue;
        }
        if (out) |o| o.add_char(c);
        prev = c;
        i += 1;
    }
    return null;
}

const Builder = struct {
    gpa: std.mem.Allocator,
    comps: std.ArrayList(Component) = .empty,
    tokens: std.ArrayList(Token) = .empty,
    literals: std.ArrayList(u8) = .empty,
    brackets: std.ArrayList(Bracket) = .empty,
    never: bool = false,

    fn deinit(b: *Builder) void {
        b.comps.deinit(b.gpa);
        b.tokens.deinit(b.gpa);
        b.literals.deinit(b.gpa);
        b.brackets.deinit(b.gpa);
    }

    fn flush_literal(b: *Builder, start: *?usize) error{OutOfMemory}!void {
        const s = start.* orelse return;
        try b.tokens.append(b.gpa, .{ .literal = .{
            .off = @intCast(s),
            .len = @intCast(b.literals.items.len - s),
        } });
        start.* = null;
    }

    fn add_component(b: *Builder, text: []const u8) error{OutOfMemory}!void {
        if (text.len >= 2 and all_stars(text)) return b.comps.append(b.gpa, .globstar);

        const tok_start = b.tokens.items.len;
        var lit_start: ?usize = null;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            switch (c) {
                '*', '?', '[' => {
                    try b.flush_literal(&lit_start);
                    switch (c) {
                        // a run inside a component is just one star
                        '*' => {
                            while (i < text.len and text[i] == '*') i += 1;
                            try b.tokens.append(b.gpa, .star);
                        },
                        '?' => {
                            try b.tokens.append(b.gpa, .any_char);
                            i += 1;
                        },
                        else => {
                            var br: Bracket = .{};
                            if (parse_bracket(text, i, &br)) |e| {
                                try b.tokens.append(b.gpa, .{ .bracket = @intCast(b.brackets.items.len) });
                                try b.brackets.append(b.gpa, br);
                                i = e;
                            } else {
                                b.never = true;
                                i = text.len;
                            }
                        },
                    }
                },
                '\\' => {
                    if (i + 1 >= text.len) {
                        b.never = true;
                        i += 1;
                        continue;
                    }
                    if (lit_start == null) lit_start = b.literals.items.len;
                    try b.literals.append(b.gpa, text[i + 1]);
                    i += 2;
                },
                else => {
                    if (lit_start == null) lit_start = b.literals.items.len;
                    try b.literals.append(b.gpa, c);
                    i += 1;
                },
            }
        }
        try b.flush_literal(&lit_start);
        try b.comps.append(b.gpa, .{ .tokens = .{
            .off = @intCast(tok_start),
            .len = @intCast(b.tokens.items.len - tok_start),
        } });
    }
};

pub fn compile(gpa: std.mem.Allocator, pattern: []const u8) CompileError!Compiled {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.deinit();

    // A '/' inside a bracket is an ordinary member and must not split, so this
    // has to be bracket-aware. An escaped "\/" does split.
    var i: usize = 0;
    var start: usize = 0;
    while (i < pattern.len) {
        switch (pattern[i]) {
            '[' => {
                if (parse_bracket(pattern, i, null)) |e| {
                    i = e;
                } else {
                    b.never = true;
                    i = pattern.len;
                }
            },
            '\\' => {
                if (i + 1 >= pattern.len) {
                    b.never = true; // a trailing lone backslash cannot be satisfied
                    i += 1;
                } else if (pattern[i + 1] == '/') {
                    try b.add_component(pattern[start..i]);
                    i += 2;
                    start = i;
                } else {
                    i += 2;
                }
            },
            '/' => {
                try b.add_component(pattern[start..i]);
                i += 1;
                start = i;
            },
            else => i += 1,
        }
    }
    try b.add_component(pattern[start..]);

    return .{
        .comps = try b.comps.toOwnedSlice(gpa),
        .tokens = try b.tokens.toOwnedSlice(gpa),
        .literals = try b.literals.toOwnedSlice(gpa),
        .brackets = try b.brackets.toOwnedSlice(gpa),
        .never_matches = b.never,
    };
}

fn all_stars(text: []const u8) bool {
    for (text) |c| if (c != '*') return false;
    return true;
}

const Cursor = struct {
    text: []const u8,
    off: ?usize,

    fn init(text: []const u8) Cursor {
        return .{ .text = text, .off = if (text.len == 0) null else 0 };
    }

    fn get(self: Cursor) ?[]const u8 {
        const o = self.off orelse return null;
        const e = std.mem.indexOfScalarPos(u8, self.text, o, '/') orelse self.text.len;
        return self.text[o..e];
    }

    fn advance(self: *Cursor) void {
        const o = self.off orelse return;
        if (std.mem.indexOfScalarPos(u8, self.text, o, '/')) |s| {
            self.off = s + 1;
        } else {
            self.off = null;
        }
    }
};

pub fn eql(a: []const u8, b: []const u8, opts: Options) bool {
    if (a.len != b.len) return false;
    if (!opts.case_insensitive) return std.mem.eql(u8, a, b);
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn match_component(
    c: *const Compiled,
    toks: []const Token,
    text: []const u8, // single path component with no `/`
    opts: Options,
) bool {
    var i: usize = 0;
    var j: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < text.len) {
        if (j < toks.len) {
            switch (toks[j]) {
                .star => {
                    star = j;
                    mark = i;
                    j += 1;
                    continue;
                },
                .any_char => {
                    i += 1;
                    j += 1;
                    continue;
                },
                .bracket => |bi| {
                    if (c.brackets[bi].matches(text[i], opts)) {
                        i += 1;
                        j += 1;
                        continue;
                    }
                },
                .literal => |r| {
                    const lit = c.literals[r.off..][0..r.len];
                    if (text.len - i >= lit.len and eql(text[i..][0..lit.len], lit, opts)) {
                        i += lit.len;
                        j += 1;
                        continue;
                    }
                },
            }
        }
        if (star) |s| {
            mark += 1;
            i = mark;
            j = s + 1;
            continue;
        }
        return false;
    }
    while (j < toks.len and toks[j] == .star) j += 1;
    return j == toks.len;
}

pub fn match(
    c: *const Compiled,
    text: []const u8, // must be normalized relative path
    opts: Options,
) bool {
    if (c.never_matches) return false;
    const m = c.comps.len;
    var i = Cursor.init(text);
    var mark = i;
    var j: usize = 0;
    var star: ?usize = null;
    while (i.get()) |tc| {
        if (j < m) {
            switch (c.comps[j]) {
                .globstar => {
                    // a trailing globstar needs at least one component
                    if (j == m - 1) return true;
                    star = j;
                    mark = i;
                    j += 1;
                    continue;
                },
                .tokens => |r| {
                    if (match_component(c, c.tokens[r.off..][0..r.len], tc, opts)) {
                        i.advance();
                        j += 1;
                        continue;
                    }
                },
            }
        }
        if (star) |s| {
            mark.advance();
            i = mark;
            j = s + 1;
            continue;
        }
        return false;
    }
    while (j < m) {
        switch (c.comps[j]) {
            .globstar => {
                if (j == m - 1) return false;
                j += 1;
            },
            else => break,
        }
    }
    return j == m;
}

const testing = std.testing;

fn expect_match(pattern: []const u8, text: []const u8, expected: bool) !void {
    var c = try compile(testing.allocator, pattern);
    defer c.deinit(testing.allocator);
    const got = match(&c, text, .{});
    if (got != expected) {
        std.debug.print("pattern '{s}' vs '{s}': expected {}, got {}\n", .{ pattern, text, expected, got });
        return error.TestExpectedEqual;
    }
}

test "literals and separators" {
    try expect_match("foo", "foo", true);
    try expect_match("foo", "foobar", false);
    try expect_match("foo/bar", "foo/bar", true);
    try expect_match("foo/bar", "foo/baz", false);
    // an escaped separator is still a separator
    try expect_match("a\\/b", "a/b", true);
    try expect_match("a\\/b", "ab", false);
}

test "star does not cross a separator" {
    try expect_match("foo*bar", "foobar", true);
    try expect_match("foo*bar", "fooXbar", true);
    try expect_match("foo*bar", "foo/baz/bar", false);
    // a star run inside a component behaves as a single star
    try expect_match("foo**bar", "fooXbar", true);
    try expect_match("foo**bar", "foo/baz/bar", false);
    try expect_match("*", "foo", true);
    try expect_match("*", "foo/bar", false);
}

test "globstar" {
    try expect_match("**/bar", "bar", true);
    try expect_match("**/bar", "foo/bar", true);
    try expect_match("**/bar", "foo/baz/bar", true);
    try expect_match("**/bar", "foobar", false);
    try expect_match("a/**/b", "a/b", true);
    try expect_match("a/**/b", "a/mid/b", true);
    try expect_match("a/**/b", "a/x/y/b", true);
    try expect_match("a/**/b", "a", false);
    // a trailing globstar needs at least one component
    try expect_match("foo/**", "foo", false);
    try expect_match("foo/**", "foo/x", true);
    try expect_match("foo/**", "foo/bar/baz", true);
}

test "question mark" {
    try expect_match("?", "a", true);
    try expect_match("?", "ab", false);
    try expect_match("a?c", "abc", true);
    try expect_match("a?c", "a/c", false);
}

test "bracket expressions" {
    try expect_match("[abc]", "b", true);
    try expect_match("[abc]", "d", false);
    // both '!' and '^' negate
    try expect_match("[!a]", "a", false);
    try expect_match("[!a]", "b", true);
    try expect_match("[^a]", "a", false);
    try expect_match("[^a]", "b", true);
    try expect_match("[^a]", "^", true);
    // a ']' in first position is a literal member
    try expect_match("[]a]", "]", true);
    try expect_match("[]a]", "a", true);
    // a '-' first or last is a literal member
    try expect_match("[a-]", "-", true);
    try expect_match("[a-]", "a", true);
    try expect_match("[a-]", "b", false);
    try expect_match("[-a]", "-", true);
    // ranges do not chain: [a-c-e] is {a..c, '-', e}
    try expect_match("[a-c-e]", "b", true);
    try expect_match("[a-c-e]", "d", false);
    try expect_match("[a-c-e]", "e", true);
    try expect_match("[a-c-e]", "-", true);
    // a '[' that does not open a POSIX class is a literal member
    try expect_match("[[]", "[", true);
    try expect_match("[[]", "]", false);
    // backslash escapes inside the set
    try expect_match("[\\]]", "]", true);
    try expect_match("[\\]]", "\\", false);
    // a bracket never matches '/', so it cannot split a component
    try expect_match("a[x/y]b", "axb", true);
    try expect_match("a[x/y]b", "ayb", true);
    try expect_match("a[x/y]b", "a/b", false);
    try expect_match("a[/]b", "a/b", false);
    try expect_match("a[/]b", "axb", false);
}

test "posix classes" {
    try expect_match("[[:digit:]]", "5", true);
    try expect_match("[[:digit:]]", "a", false);
    try expect_match("[[:digit:]]", ":", false);
    try expect_match("[[:alpha:]][[:digit:]]", "a1", true);
    try expect_match("[[:punct:]]", "!", true);
    try expect_match("[[:punct:]]", "a", false);
}

test "malformed patterns match nothing" {
    // unterminated '[' aborts the whole pattern, not just that position
    try expect_match("[a", "a", false);
    try expect_match("[a", "[a", false);
    try expect_match("x[a", "x[a", false);
    try expect_match("x[a", "xa", false);
    // unknown POSIX class
    try expect_match("[[:foo:]]", "x", false);
    try expect_match("[[:foo:]]", ":", false);
    // a trailing lone backslash can never be satisfied
    try expect_match("foo\\", "foo", false);
    try expect_match("foo\\", "foo\\", false);
}

test "escapes" {
    try expect_match("\\*", "*", true);
    try expect_match("\\*", "x", false);
    try expect_match("\\?", "?", true);
    try expect_match("\\[", "[", true);
    try expect_match("\\#foo", "#foo", true);
    try expect_match("\\!foo", "!foo", true);
}

test "case folding" {
    var c = try compile(testing.allocator, "FOO");
    defer c.deinit(testing.allocator);
    try testing.expect(match(&c, "FOO", .{}));
    try testing.expect(!match(&c, "foo", .{}));
    try testing.expect(match(&c, "foo", .{ .case_insensitive = true }));

    var r = try compile(testing.allocator, "[A-Z]");
    defer r.deinit(testing.allocator);
    try testing.expect(match(&r, "M", .{}));
    try testing.expect(!match(&r, "m", .{}));
    try testing.expect(match(&r, "m", .{ .case_insensitive = true }));
    try testing.expect(match(&r, "M", .{ .case_insensitive = true }));

    var l = try compile(testing.allocator, "[a-z]");
    defer l.deinit(testing.allocator);
    try testing.expect(match(&l, "M", .{ .case_insensitive = true }));
    try testing.expect(!match(&l, "M", .{}));
}

test "no exponential blowup" {
    // the matcher must not backtrack exponentially
    var c = try compile(testing.allocator, "a*a*a*a*a*a*a*a*b");
    defer c.deinit(testing.allocator);
    try testing.expect(!match(&c, "a" ** 64, .{}));
}
