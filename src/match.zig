//! Lua pattern matching

const std = @import("std");

pub const MAX_CAPTURES = 32;
const MAX_MATCH_DEPTH = 200;

const PATTERN_ESC = '%';
const SPECIALS = "^$*+?.([%-";

const CAP_UNFINISHED: isize = -1;
const CAP_POSITION: isize = -2;

pub const Error = error{
    MalformedPattern,
    TooManyCaptures,
    PatternTooComplex,
    InvalidCaptureIndex,
    InvalidPatternCapture,
    UnfinishedCapture,
};

pub const Capture = union(enum) {
    str: []const u8,
    position: usize,
};

pub const Captures = struct {
    buf: [MAX_CAPTURES]Capture = undefined,
    items: []const Capture = &.{},
};

pub const FindResult = struct {
    start: usize,
    end: usize,
    captures: Captures,
};

fn isalpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isdigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isalnum(c: u8) bool {
    return isalpha(c) or isdigit(c);
}
fn iscntrl(c: u8) bool {
    return c < 32 or c == 127;
}
fn isgraph(c: u8) bool {
    return c > 32 and c < 127;
}
fn islower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
fn isupper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}
fn ispunct(c: u8) bool {
    return isgraph(c) and !isalnum(c);
}
fn isspace(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d); // \t \n \v \f \r
}
fn isxdigit(c: u8) bool {
    return isdigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn tolower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

const MatchState = struct {
    src: []const u8, // source string; src_init == index 0, src_end == src.len
    pat: []const u8, // pattern; p_end == pat.len
    matchdepth: i32 = MAX_MATCH_DEPTH,
    level: usize = 0, // number of captures (finished or unfinished)
    capture: [MAX_CAPTURES]struct {
        init: usize, // start index into src
        len: isize, // length, or one of CAP_*
    } = undefined,

    fn checkCapture(ms: *MatchState, l: u8) Error!usize {
        const idx = @as(i32, l) - '1';
        if (idx < 0 or idx >= @as(i32, @intCast(ms.level)) or
            ms.capture[@intCast(idx)].len == CAP_UNFINISHED)
            return error.InvalidCaptureIndex;
        return @intCast(idx);
    }

    fn captureToClose(ms: *MatchState) Error!usize {
        var level = ms.level;
        while (level > 0) {
            level -= 1;
            if (ms.capture[level].len == CAP_UNFINISHED) return level;
        }
        return error.InvalidPatternCapture;
    }

    fn classend(ms: *MatchState, p: usize) Error!usize {
        var pp = p;
        const c = ms.pat[pp];
        pp += 1;
        switch (c) {
            PATTERN_ESC => {
                if (pp == ms.pat.len) return error.MalformedPattern; // ends with '%'
                return pp + 1;
            },
            '[' => {
                if (pp < ms.pat.len and ms.pat[pp] == '^') pp += 1;
                while (true) { // look for a ']'
                    if (pp == ms.pat.len) return error.MalformedPattern; // missing ']'
                    const ch = ms.pat[pp];
                    pp += 1;
                    if (ch == PATTERN_ESC and pp < ms.pat.len) pp += 1; // skip escapes
                    if (pp >= ms.pat.len or ms.pat[pp] != ']') continue;
                    break;
                }
                return pp + 1;
            },
            else => return pp,
        }
    }

    fn singlematch(ms: *MatchState, s: usize, p: usize, ep: usize) bool {
        if (s >= ms.src.len) return false;
        const c = ms.src[s];
        return switch (ms.pat[p]) {
            '.' => true, // matches any char
            PATTERN_ESC => matchClass(c, ms.pat[p + 1]),
            '[' => matchBracketClass(ms.pat, c, p, ep - 1),
            else => ms.pat[p] == c,
        };
    }

    fn matchbalance(ms: *MatchState, s: usize, p: usize) Error!?usize {
        if (p + 1 >= ms.pat.len) return error.MalformedPattern; // missing arguments to '%b'
        const b = ms.pat[p];
        const e = ms.pat[p + 1];
        if (s >= ms.src.len or ms.src[s] != b) return null;
        var ss = s;
        var cont: i32 = 1;
        while (true) {
            ss += 1;
            if (ss >= ms.src.len) break;
            if (ms.src[ss] == e) {
                cont -= 1;
                if (cont == 0) return ss + 1;
            } else if (ms.src[ss] == b) {
                cont += 1;
            }
        }
        return null; // string ends out of balance
    }

    fn maxExpand(ms: *MatchState, s: usize, p: usize, ep: usize) Error!?usize {
        var i: usize = 0;
        while (ms.singlematch(s + i, p, ep)) i += 1; // count maximum expansion
        // keep trying to match with the maximum repetitions, backing off by one
        while (true) {
            if (try ms.match(s + i, ep + 1)) |res| return res;
            if (i == 0) break;
            i -= 1;
        }
        return null;
    }

    fn minExpand(ms: *MatchState, s: usize, p: usize, ep: usize) Error!?usize {
        var ss = s;
        while (true) {
            if (try ms.match(ss, ep + 1)) |res| return res;
            if (ms.singlematch(ss, p, ep)) {
                ss += 1; // try with one more repetition
            } else return null;
        }
    }

    fn startCapture(ms: *MatchState, s: usize, p: usize, what: isize) Error!?usize {
        const level = ms.level;
        if (level >= MAX_CAPTURES) return error.TooManyCaptures;
        ms.capture[level] = .{ .init = s, .len = what };
        ms.level = level + 1;
        const res = try ms.match(s, p);
        if (res == null) ms.level -= 1; // undo capture
        return res;
    }

    fn endCapture(ms: *MatchState, s: usize, p: usize) Error!?usize {
        const l = try ms.captureToClose();
        ms.capture[l].len = @intCast(s - ms.capture[l].init); // close capture
        const res = try ms.match(s, p);
        if (res == null) ms.capture[l].len = CAP_UNFINISHED; // undo
        return res;
    }

    fn matchCapture(ms: *MatchState, s: usize, l: u8) Error!?usize {
        const idx = try ms.checkCapture(l);
        const len: usize = @intCast(ms.capture[idx].len);
        const cinit = ms.capture[idx].init;
        if (ms.src.len - s >= len and
            std.mem.eql(u8, ms.src[cinit .. cinit + len], ms.src[s .. s + len]))
            return s + len;
        return null;
    }

    fn match(ms: *MatchState, s0: usize, p0: usize) Error!?usize {
        if (ms.matchdepth == 0) return error.PatternTooComplex;
        ms.matchdepth -= 1;

        var s = s0;
        var p = p0;
        const result: ?usize = res_blk: {
            init: while (true) {
                if (p == ms.pat.len) break :res_blk s; // end of pattern: success
                dflt: {
                    switch (ms.pat[p]) {
                        '(' => { // start capture
                            if (p + 1 < ms.pat.len and ms.pat[p + 1] == ')')
                                break :res_blk try ms.startCapture(s, p + 2, CAP_POSITION) // position capture
                            else
                                break :res_blk try ms.startCapture(s, p + 1, CAP_UNFINISHED);
                        },
                        ')' => break :res_blk try ms.endCapture(s, p + 1), // end capture
                        '$' => {
                            if (p + 1 != ms.pat.len) break :dflt; // not the last char: default
                            break :res_blk if (s == ms.src.len) s else null; // check end of string
                        },
                        PATTERN_ESC => {
                            const ec: u8 = if (p + 1 < ms.pat.len) ms.pat[p + 1] else 0;
                            switch (ec) {
                                'b' => { // balanced string
                                    if (try ms.matchbalance(s, p + 2)) |res| {
                                        s = res;
                                        p += 4;
                                        continue :init;
                                    }
                                    break :res_blk null; // fail
                                },
                                'f' => { // frontier
                                    p += 2;
                                    if (p >= ms.pat.len or ms.pat[p] != '[')
                                        return error.MalformedPattern; // missing '[' after '%f'
                                    const ep = try ms.classend(p);
                                    const previous: u8 = if (s == 0) 0 else ms.src[s - 1];
                                    const current: u8 = if (s < ms.src.len) ms.src[s] else 0;
                                    if (!matchBracketClass(ms.pat, previous, p, ep - 1) and
                                        matchBracketClass(ms.pat, current, p, ep - 1))
                                    {
                                        p = ep;
                                        continue :init;
                                    }
                                    break :res_blk null; // match failed
                                },
                                '0'...'9' => { // back-reference (%0-%9)
                                    if (try ms.matchCapture(s, ec)) |res| {
                                        s = res;
                                        p += 2;
                                        continue :init;
                                    }
                                    break :res_blk null;
                                },
                                else => break :dflt,
                            }
                        },
                        else => break :dflt,
                    }
                }

                // default: a pattern class plus an optional suffix
                const ep = try ms.classend(p);
                const suffix: u8 = if (ep < ms.pat.len) ms.pat[ep] else 0;
                if (!ms.singlematch(s, p, ep)) {
                    if (suffix == '*' or suffix == '?' or suffix == '-') { // accept empty?
                        p = ep + 1;
                        continue :init;
                    }
                    break :res_blk null; // '+' or no suffix: fail
                }
                // matched once; handle the optional suffix
                switch (suffix) {
                    '?' => { // optional
                        if (try ms.match(s + 1, ep + 1)) |res| break :res_blk res;
                        p = ep + 1;
                        continue :init;
                    },
                    '+' => break :res_blk try ms.maxExpand(s + 1, p, ep), // 1 or more
                    '*' => break :res_blk try ms.maxExpand(s, p, ep), // 0 or more
                    '-' => break :res_blk try ms.minExpand(s, p, ep), // 0 or more (minimum)
                    else => { // no suffix
                        s += 1;
                        p = ep;
                        continue :init;
                    },
                }
            }
        };

        ms.matchdepth += 1;
        return result;
    }

    fn oneCapture(ms: *MatchState, i: usize, s: ?usize, e: ?usize) Error!Capture {
        if (i >= ms.level) {
            if (i != 0) return error.InvalidCaptureIndex;
            return .{ .str = ms.src[s.?..e.?] };
        }
        const capl = ms.capture[i].len;
        const cinit = ms.capture[i].init;
        if (capl == CAP_UNFINISHED) return error.UnfinishedCapture;
        if (capl == CAP_POSITION) return .{ .position = cinit };
        return .{ .str = ms.src[cinit .. cinit + @as(usize, @intCast(capl))] };
    }

    fn collectCaptures(ms: *MatchState, whole: ?usize, e: ?usize) Error!Captures {
        const nlevels = if (ms.level == 0 and whole != null) 1 else ms.level;
        var caps: Captures = .{};
        caps.items = caps.buf[0..nlevels];
        var i: usize = 0;
        while (i < nlevels) : (i += 1)
            caps.buf[i] = try ms.oneCapture(i, whole, e);
        return caps;
    }
};

fn matchClass(c: u8, cl: u8) bool {
    const res = switch (tolower(cl)) {
        'a' => isalpha(c),
        'c' => iscntrl(c),
        'd' => isdigit(c),
        'g' => isgraph(c),
        'l' => islower(c),
        'p' => ispunct(c),
        's' => isspace(c),
        'u' => isupper(c),
        'w' => isalnum(c),
        'x' => isxdigit(c),
        'z' => c == 0,
        else => return cl == c,
    };
    return if (islower(cl)) res else !res;
}

fn matchBracketClass(pat: []const u8, c: u8, p: usize, ec: usize) bool {
    var sig = true;
    var pp = p;
    if (pat[pp + 1] == '^') {
        sig = false;
        pp += 1;
    }
    while (true) {
        pp += 1;
        if (pp >= ec) break;
        if (pat[pp] == PATTERN_ESC) {
            pp += 1;
            if (matchClass(c, pat[pp])) return sig;
        } else if (pat[pp + 1] == '-' and pp + 2 < ec) {
            pp += 2;
            if (pat[pp - 2] <= c and c <= pat[pp]) return sig;
        } else if (pat[pp] == c) {
            return sig;
        }
    }
    return !sig;
}

fn startIndex(pos: i64, len: usize) usize {
    const ilen: i64 = @intCast(len);
    if (pos >= 0) return @intCast(pos);
    if (-pos > ilen) return 0;
    return @intCast(ilen + pos);
}

fn nospecials(p: []const u8) bool {
    for (p) |c| if (std.mem.indexOfScalar(u8, SPECIALS, c) != null)
        return false;
    return true;
}

/// Find a Lua pattern
///
/// `init` may be negative to count from the end
pub fn find(s: []const u8, pattern: []const u8, init: i64) Error!?FindResult {
    const start = startIndex(init, s.len);
    if (start > s.len) return null;

    if (nospecials(pattern)) {
        if (std.mem.indexOf(u8, s[start..], pattern)) |off| {
            const begin = start + off;
            return .{ .start = begin, .end = begin + pattern.len, .captures = .{} };
        }
        return null;
    }

    var ms = MatchState{ .src = s, .pat = pattern };
    var s1 = start;
    const anchor = pattern.len > 0 and pattern[0] == '^';
    if (anchor) ms.pat = pattern[1..]; // skip anchor character
    while (true) {
        ms.level = 0;
        ms.matchdepth = MAX_MATCH_DEPTH;
        if (try ms.match(s1, 0)) |res| {
            return .{
                .start = s1,
                .end = res, // res is the index just past the match (exclusive)
                .captures = try ms.collectCaptures(null, null),
            };
        }
        if (anchor or s1 >= ms.src.len) break;
        s1 += 1;
    }
    return null;
}

/// Match a Lua pattern
///
/// `init` may be negative to count from the end
/// Returns the captures of the match, or the whole match as a single
/// capture when the pattern has none.
pub fn match(s: []const u8, pattern: []const u8, init: i64) Error!?Captures {
    const start = startIndex(init, s.len);
    if (start > s.len) return null;

    var ms = MatchState{ .src = s, .pat = pattern };
    var s1 = start;
    const anchor = pattern.len > 0 and pattern[0] == '^';
    if (anchor) ms.pat = pattern[1..];
    while (true) {
        ms.level = 0;
        ms.matchdepth = MAX_MATCH_DEPTH;
        if (try ms.match(s1, 0)) |res| {
            return try ms.collectCaptures(s1, res);
        }
        if (anchor or s1 >= ms.src.len) break;
        s1 += 1;
    }
    return null;
}

const testing = std.testing;

fn f(s: []const u8, p: []const u8) Error!?[]const u8 {
    return if (try find(s, p, 0)) |r| s[r.start..r.end] else null;
}

fn m1(s: []const u8, p: []const u8) anyerror!?[]const u8 {
    const caps = (try match(s, p, 0)) orelse return null;
    try testing.expectEqual(@as(usize, 1), caps.items.len);
    return caps.items[0].str;
}

test "find: empty patterns are tricky" {
    {
        const r = (try find("", "", 0)).?;
        try testing.expectEqual(@as(usize, 0), r.start);
        try testing.expectEqual(@as(usize, 0), r.end);
    }
    {
        const r = (try find("alo", "", 0)).?;
        try testing.expectEqual(@as(usize, 0), r.start);
        try testing.expectEqual(@as(usize, 0), r.end);
    }
}

test "find: with embedded zeros and init" {
    const s = "a\x00o a\x00o a\x00o";
    {
        const r = (try find(s, "a", 0)).?; // first byte
        try testing.expectEqual(@as(usize, 0), r.start);
        try testing.expectEqual(@as(usize, 1), r.end);
    }
    {
        const r = (try find(s, "a\x00o", 1)).?; // starts in the middle
        try testing.expectEqual(@as(usize, 4), r.start);
        try testing.expectEqual(@as(usize, 7), r.end);
    }
    {
        const r = (try find(s, "a\x00o", 8)).?;
        try testing.expectEqual(@as(usize, 8), r.start);
        try testing.expectEqual(@as(usize, 11), r.end);
    }
}

test "find: finds at the end / last position" {
    const s = "a\x00a\x00a\x00a\x00\x00ab";
    {
        const r = (try find(s, "\x00ab", 1)).?;
        try testing.expectEqual(@as(usize, 8), r.start);
        try testing.expectEqual(@as(usize, 11), r.end);
    }
    {
        const r = (try find(s, "b", 0)).?;
        try testing.expectEqual(@as(usize, 10), r.start);
        try testing.expectEqual(@as(usize, 11), r.end);
    }
    try testing.expect((try find(s, "b\x00", 0)) == null); // check ending
}

test "find: misc plain and anchored" {
    try testing.expect((try find("", "\x00", 0)) == null);
    try testing.expectEqual(@as(usize, 3), (try find("alo123alo", "12", 0)).?.start);
    try testing.expect((try find("alo123alo", "^12", 0)) == null);
}

test "match: .* .+ .? greediness" {
    try testing.expectEqualStrings("aaab", (try m1("aaab", ".*b")).?);
    try testing.expectEqualStrings("aaa", (try m1("aaa", ".*a")).?);
    try testing.expectEqualStrings("b", (try m1("b", ".*b")).?);

    try testing.expectEqualStrings("aaab", (try m1("aaab", ".+b")).?);
    try testing.expectEqualStrings("aaa", (try m1("aaa", ".+a")).?);
    try testing.expect((try match("b", ".+b", 1)) == null);

    try testing.expectEqualStrings("ab", (try m1("aaab", ".?b")).?);
    try testing.expectEqualStrings("aa", (try m1("aaa", ".?a")).?);
    try testing.expectEqualStrings("b", (try m1("b", ".?b")).?);
}

test "find via f: classes, anchors, repetition suffixes" {
    try testing.expectEqualStrings("aaa", (try f("aaab", "a*")).?);
    try testing.expectEqualStrings("aaa", (try f("aaa", "^.*$")).?);
    try testing.expectEqualStrings("", (try f("aaa", "b*")).?);
    try testing.expectEqualStrings("aa", (try f("aaa", "ab*a")).?);
    try testing.expectEqualStrings("aba", (try f("aba", "ab*a")).?);
    try testing.expectEqualStrings("aaa", (try f("aaab", "a+")).?);
    try testing.expectEqualStrings("aaa", (try f("aaa", "^.+$")).?);
    try testing.expect((try f("aaa", "b+")) == null);
    try testing.expect((try f("aaa", "ab+a")) == null);
    try testing.expectEqualStrings("aba", (try f("aba", "ab+a")).?);
    try testing.expectEqualStrings("a", (try f("a$a", ".$")).?);
    try testing.expectEqualStrings("a$", (try f("a$a", ".%$")).?);
    try testing.expectEqualStrings("a$a", (try f("a$a", ".$.")).?);
    try testing.expect((try f("a$a", "$$")) == null);
    try testing.expect((try f("a$b", "a$")) == null);
    try testing.expectEqualStrings("", (try f("a$a", "$")).?);
    try testing.expectEqualStrings("", (try f("", "b*")).?);
    try testing.expect((try f("aaa", "bb*")) == null);
    try testing.expectEqualStrings("", (try f("aaab", "a-")).?);
    try testing.expectEqualStrings("aaa", (try f("aaa", "^.-$")).?);
    try testing.expectEqualStrings("baaabaaabaaab", (try f("aabaaabaaabaaaba", "b.*b")).?);
    try testing.expectEqualStrings("baaab", (try f("aabaaabaaabaaaba", "b.-b")).?);
    try testing.expectEqualStrings("xo", (try f("alo xo", ".o$")).?);
    try testing.expectEqualStrings("?", (try f("um caracter ? extra", "[^%sa-z]")).?);
    try testing.expectEqualStrings("", (try f("", "a?")).?);
    try testing.expectEqualStrings("aa", (try f("aa", "^aa?a?a")).?);
    try testing.expectEqualStrings("\xc3\xa1bl", (try f("\xc3\xa1bl", "[^]]+")).?); // [^]]+ on "ábl"
    try testing.expectEqualStrings("0a", (try f("0alo alo", "%x*")).?);
    try testing.expectEqualStrings("alo alo", (try f("alo alo", "%C+")).?);
}

test "find via f: character classes %S %g %l %a" {
    try testing.expectEqualStrings("isto", (try f(" \n isto \xc3\xa9 assim", "%S%S*")).?);
    try testing.expectEqualStrings("assim", (try f(" \n isto \xc3\xa9 assim", "%S*$")).?);
    try testing.expectEqualStrings("assim", (try f(" \n isto \xc3\xa9 assim", "[a-z]*$")).?);
    try testing.expectEqualStrings("alo", (try f("aloALO", "%l*")).?);
    try testing.expectEqualStrings("aLo", (try f("aLo_ALO", "%a*")).?);
    try testing.expectEqualStrings("xuxu", (try f("  \n\r*&\n\r   xuxu  \n\n", "%g%g%g+")).?);
}

test "match: bracket sets, ranges and captures" {
    try testing.expectEqualStrings("xyz", (try m1("alo xyzK", "(%w+)K")).?);
    try testing.expectEqualStrings("", (try m1("254 K", "(%d*)K")).?);
    try testing.expectEqualStrings("", (try m1("alo ", "(%w*)$")).?);
    try testing.expect((try match("alo ", "(%w+)$", 0)) == null);
    try testing.expectEqual(@as(usize, 0), (try find("(\xc3\xa1lo)", "%(\xc3\xa1", 0)).?.start);
}

test "match: multiple captures (date)" {
    const caps = (try match("Today is 17/7/1990", "(%d+)/(%d+)/(%d+)", 0)).?;
    try testing.expectEqual(@as(usize, 3), caps.items.len);
    try testing.expectEqualStrings("17", caps.items[0].str);
    try testing.expectEqualStrings("7", caps.items[1].str);
    try testing.expectEqualStrings("1990", caps.items[2].str);
}

test "match: nested captures with position capture" {
    const caps = (try match("0123456789", "(.+(.?)())", 0)).?;
    try testing.expectEqual(@as(usize, 3), caps.items.len);
    try testing.expectEqualStrings("0123456789", caps.items[0].str);
    try testing.expectEqualStrings("", caps.items[1].str);
    try testing.expectEqual(@as(usize, 10), caps.items[2].position);
}

test "match: position captures" {
    const caps = (try match("hello", "()ll()", 0)).?;
    try testing.expectEqual(@as(usize, 2), caps.items.len);
    try testing.expectEqual(@as(usize, 2), caps.items[0].position);
    try testing.expectEqual(@as(usize, 4), caps.items[1].position);
}

test "match: back-references" {
    const caps = (try match("alo alx 123 b\x00o b\x00o", "(..*) %1", 0)).?;
    try testing.expectEqualStrings("b\x00o", caps.items[0].str);
    try testing.expect((try match("=======", "^(=*)=%1$", 0)) != null);
    try testing.expect((try match("==========", "^([=]*)=%1$", 0)) == null);
}

test "match: balanced %b" {
    try testing.expectEqualStrings("'oi'", (try m1("alo 'oi' alo", "%b''")).?);
    try testing.expectEqualStrings("(9 ((8))(0) 7)", (try m1("(9 ((8))(0) 7)", "%b()")).?);
}

test "find: frontier pattern %f" {
    try testing.expectEqual(@as(usize, 0), (try find("a", "%f[a]", 0)).?.start);
    try testing.expectEqual(@as(usize, 0), (try find("a", "%f[^%z]", 0)).?.start);
    try testing.expectEqual(@as(usize, 1), (try find("a", "%f[^%l]", 0)).?.start);
    try testing.expectEqual(@as(usize, 2), (try find("aba", "%f[a%z]", 0)).?.start);
    try testing.expectEqual(@as(usize, 3), (try find("aba", "%f[%z]", 0)).?.start);
    try testing.expect((try find("aba", "%f[%l%z]", 0)) == null);
    try testing.expect((try find("aba", "%f[^%l%z]", 0)) == null);
}

test "find: frontier spanning words" {
    const r = (try find(" alo aalo allo", "%f[%S].-%f[%s].-%f[%S]", 0)).?;
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expectEqual(@as(usize, 5), r.end);
    try testing.expectEqualStrings("alo ", (try m1(" alo aalo allo", "%f[%S](.-%f[%s].-%f[%S])")).?);
}

test "patterns with embedded zeros" {
    try testing.expectEqualStrings("\x00\x01\x02", (try m1("ab\x00\x01\x02c", "[\x00-\x02]+")).?);
    try testing.expectEqualStrings("\x00", (try m1("ab\x00\x01\x02c", "[\x00-\x00]+")).?);
    try testing.expectEqual(@as(usize, 1), (try find("b$a", "$\x00?", 0)).?.start);
    try testing.expectEqual(@as(usize, 3), (try find("abc\x00efg", "%\x00", 0)).?.start);
    try testing.expectEqualStrings("\x00efg\x00\x01e\x01", (try m1("abc\x00efg\x00\x01e\x01g", "%b\x00\x01")).?);
    try testing.expectEqualStrings("\x00\x00\x00", (try m1("abc\x00\x00\x00", "%\x00+")).?);
    try testing.expectEqualStrings("\x00\x00", (try m1("abc\x00\x00\x00", "%\x00%\x00?")).?);
    try testing.expectEqual(@as(usize, 3), (try find("abc\x00\x00", "\x00.", 0)).?.start);
    try testing.expectEqual(@as(usize, 3), (try find("abcx\x00\x00abc\x00abc", "x\x00\x00abc\x00a.", 0)).?.start);
}

test "bracket ranges and byte values" {
    var count: usize = 0;
    var b: u8 = 200;
    while (b <= 210) : (b += 1) {
        const s = [_]u8{b};
        if ((try match(&s, "[\xc8-\xd2]", 0)) != null) count += 1;
        if (b == 210) break;
    }
    try testing.expectEqual(@as(usize, 11), count);

    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz", (try m1("abcdefghijklmnopqrstuvwxyz", "[a-z]+")).?);
    // [a-] matches '-' and 'a' (literal trailing '-').
    try testing.expectEqualStrings("-a", (try m1("-a", "[a-]+")).?);
    // []%%] is the set { ']', '%' }.
    try testing.expectEqualStrings("%]", (try m1("%]", "[]%%]+")).?);
}

test "init position: negative and out of range" {
    try testing.expectEqual(@as(usize, 2), (try find("hello", "l", -3)).?.start);
    try testing.expect((try find("abc", "a", 5)) == null);
    try testing.expectEqual(@as(usize, 0), (try find("abc", "a", -100)).?.start);
}

test "malformed patterns produce errors" {
    try testing.expectError(error.UnfinishedCapture, find("a", "(.", 0));
    try testing.expectError(error.InvalidPatternCapture, find("a", ".)", 0));
    try testing.expectError(error.MalformedPattern, find("a", "[a", 0));
    try testing.expectError(error.MalformedPattern, find("a", "[]", 0));
    try testing.expectError(error.MalformedPattern, find("a", "[^]", 0));
    try testing.expectError(error.MalformedPattern, find("a", "[a%]", 0));
    try testing.expectError(error.MalformedPattern, find("a", "[a%", 0));
    try testing.expectError(error.MalformedPattern, find("a", "%b", 0));
    try testing.expectError(error.MalformedPattern, find("a", "%ba", 0));
    try testing.expectError(error.MalformedPattern, find("a", "%", 0));
    try testing.expectError(error.MalformedPattern, find("a", "%f", 0));
    try testing.expectError(error.InvalidCaptureIndex, find("a", "(%1)", 0));
}
