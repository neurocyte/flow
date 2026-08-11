const std = @import("std");
const wildmatch = @import("wildmatch.zig");
const Pattern = @import("Pattern.zig");

const PatternList = @This();

pub const DType = enum { file, dir, unknown };

pub const ResolveFn = *const fn (ctx: ?*anyopaque, rel: []const u8) DType;

buf: []const u8, // owned
base: []const u8, // "" for achoring on the project root.
name: []const u8,
patterns: []Pattern,

pub fn parse(
    gpa: std.mem.Allocator,
    base: []const u8,
    name: []const u8,
    contents: []const u8,
) error{OutOfMemory}!PatternList {
    const buf = try gpa.dupe(u8, contents);
    errdefer gpa.free(buf);
    const base_owned = try gpa.dupe(u8, base);
    errdefer gpa.free(base_owned);
    const name_owned = try gpa.dupe(u8, name);
    errdefer gpa.free(name_owned);

    var patterns: std.ArrayList(Pattern) = .empty;
    errdefer {
        for (patterns.items) |*p| p.deinit(gpa);
        patterns.deinit(gpa);
    }

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (try Pattern.parse(gpa, line, line_no)) |p|
            try patterns.append(gpa, p);
    }

    return .{
        .buf = buf,
        .base = base_owned,
        .name = name_owned,
        .patterns = try patterns.toOwnedSlice(gpa),
    };
}

pub fn deinit(self: *PatternList, gpa: std.mem.Allocator) void {
    for (self.patterns) |*p| p.deinit(gpa);
    gpa.free(self.patterns);
    gpa.free(self.buf);
    gpa.free(self.base);
    gpa.free(self.name);
    self.* = undefined;
}

/// The last matching pattern in a file wins, so this scans backwards.
pub fn last_match(
    self: *const PatternList,
    rel: []const u8,
    basename: []const u8,
    dtype: *DType,
    resolve: ?ResolveFn,
    ctx: ?*anyopaque,
    opts: wildmatch.Options,
) ?*const Pattern {
    var i = self.patterns.len;
    while (i > 0) {
        i -= 1;
        const p = &self.patterns[i];
        if (p.flags.must_be_dir) {
            if (dtype.* == .unknown) {
                if (resolve) |f| dtype.* = f(ctx, rel);
            }
            // an unresolvable dtype stays .unknown and fails
            if (dtype.* != .dir) continue;
        }
        if (p.flags.no_dir) {
            if (p.match_basename(basename, opts)) return p;
            continue;
        }
        if (p.match_pathname(rel, self.base, opts)) return p;
    }
    return null;
}

const testing = std.testing;

fn last_match_of(pl: *const PatternList, rel: []const u8, dtype_in: DType) ?*const Pattern {
    var dtype = dtype_in;
    const basename = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    return pl.last_match(rel, basename, &dtype, null, null, .{});
}

test "last matching pattern wins" {
    var pl = try parse(testing.allocator, "", ".gitignore", "*.log\n!keep.log\n");
    defer pl.deinit(testing.allocator);

    const a = last_match_of(&pl, "x.log", .file).?;
    try testing.expect(!a.flags.negative);
    const b = last_match_of(&pl, "keep.log", .file).?;
    try testing.expect(b.flags.negative);
    try testing.expectEqual(@as(u32, 2), b.line_no);
}

test "line numbers count skipped lines" {
    var pl = try parse(testing.allocator, "", ".gitignore", "# comment\n\nfoo\n");
    defer pl.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pl.patterns.len);
    try testing.expectEqual(@as(u32, 3), pl.patterns[0].line_no);
}

test "final line without a trailing newline" {
    var pl = try parse(testing.allocator, "", ".gitignore", "foo\nbar");
    defer pl.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), pl.patterns.len);
    try testing.expect(last_match_of(&pl, "bar", .file) != null);
}

test "directory-only patterns need a dtype" {
    var pl = try parse(testing.allocator, "", ".gitignore", "foo/\n");
    defer pl.deinit(testing.allocator);
    try testing.expect(last_match_of(&pl, "foo", .dir) != null);
    try testing.expect(last_match_of(&pl, "foo", .file) == null);
    // an unresolvable dtype fails a directory-only pattern
    try testing.expect(last_match_of(&pl, "foo", .unknown) == null);
}

test "dtype is resolved lazily and only once" {
    const Ctx = struct {
        calls: usize = 0,
        fn resolve(ctx: ?*anyopaque, _: []const u8) DType {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return .dir;
        }
    };

    // Two directory-only patterns; the resolve callback must fire once.
    var pl = try parse(testing.allocator, "", ".gitignore", "bar/\nfoo/\n");
    defer pl.deinit(testing.allocator);

    var ctx: Ctx = .{};
    var dtype: DType = .unknown;
    const hit = pl.last_match("foo", "foo", &dtype, Ctx.resolve, &ctx, .{});
    try testing.expect(hit != null);
    try testing.expectEqual(@as(usize, 1), ctx.calls);

    // A file-only query never reaches the callback.
    var plain = try parse(testing.allocator, "", ".gitignore", "foo\n");
    defer plain.deinit(testing.allocator);
    var ctx2: Ctx = .{};
    var dtype2: DType = .unknown;
    _ = plain.last_match("foo", "foo", &dtype2, Ctx.resolve, &ctx2, .{});
    try testing.expectEqual(@as(usize, 0), ctx2.calls);
}

test "base anchoring" {
    var pl = try parse(testing.allocator, "sub", "sub/.gitignore", "/foo\n");
    defer pl.deinit(testing.allocator);
    try testing.expect(last_match_of(&pl, "sub/foo", .file) != null);
    try testing.expect(last_match_of(&pl, "foo", .file) == null);
    try testing.expect(last_match_of(&pl, "sub/deep/foo", .file) == null);
}

test "unanchored pattern in a nested list still matches at any depth below it" {
    var pl = try parse(testing.allocator, "sub", "sub/.gitignore", "foo\n");
    defer pl.deinit(testing.allocator);
    // no_dir patterns match on basename, so the caller's directory walk is what
    // confines them to the subtree
    try testing.expect(last_match_of(&pl, "sub/deep/foo", .file) != null);
}
