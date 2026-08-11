const std = @import("std");
const builtin = @import("builtin");

const wildmatch = @import("wildmatch.zig");
const Pattern = @import("Pattern.zig");
const PatternList = @import("PatternList.zig");

const Matcher = @This();

pub const DType = PatternList.DType;

pub const Precedence = enum(u2) {
    global = 0, // core.excludesFile, and the builtin fallback list
    repository = 1, // $GIT_DIR/info/exclude
    per_directory = 2, // the .gitignore chain
    command_line = 3, // git --exclude= equivalents
};

pub const Decision = enum { ignored, not_ignored, undecided };

pub const MatchInfo = struct {
    decision: Decision = .undecided,
    source: []const u8 = "", // Matcher-owned
    line_no: u32 = 0,
    pattern: []const u8 = "", // the line as written, Matcher-owned
    negative: bool = false,
};

pub const Options = struct {
    per_directory_file: []const u8 = ".gitignore",
    case_insensitive: bool = builtin.os.tag == .windows or builtin.os.tag.isDarwin(),
    accept_backslash_separator: bool = builtin.os.tag == .windows,
    retain_empty_dirs: bool = true,
    max_file_size: usize = 1 << 20,
    max_total_pattern_bytes: usize = 8 << 20,
    max_dirs: usize = 50_000,
    warn: ?*const fn (ctx: ?*anyopaque, msg: []const u8, path: []const u8) void = null,
    warn_ctx: ?*anyopaque = null,
};

const Attribution = struct {
    source: []const u8,
    line_no: u32,
    pattern: []const u8,
    negative: bool,

    fn of(list: *const PatternList, p: *const Pattern) Attribution {
        return .{
            .source = list.name,
            .line_no = p.line_no,
            .pattern = p.raw,
            .negative = p.flags.negative,
        };
    }
};

const Dir = struct {
    path: []const u8, // Interned, arena owned, project relative, no trailing separator.
    parent: ?*Dir,
    children: std.ArrayList(*Dir) = .empty,
    list: ?PatternList = null, // null once `loaded` means there is no ignore file here
    loaded: bool = false,
    excluded: bool = false, // terminal: nothing below can be re-included
    excluded_by: ?Attribution = null,

    fn is_empty(self: *const Dir) bool {
        return self.list == null and !self.excluded and self.children.items.len == 0;
    }
};

gpa: std.mem.Allocator,
root: std.Io.Dir,
options: Options,
paths_arena: std.heap.ArenaAllocator,
dirs: std.StringHashMapUnmanaged(*Dir) = .empty,
root_dir: *Dir = undefined,
sources: [4]std.ArrayList(PatternList) = .{ .empty, .empty, .empty, .empty }, // indexed by precedence
gen: u64 = 0,
sweep_at: usize = 0, // raised past an ineffective sweep so we do not re-sweep on every new node
total_pattern_bytes: usize = 0,
degraded: bool = false, // set once a memory bound is hit then degrade toward not ignored
scratch: std.ArrayList(u8) = .empty,

pub fn init(gpa: std.mem.Allocator, root: std.Io.Dir, options: Options) error{OutOfMemory}!Matcher {
    var self: Matcher = .{
        .gpa = gpa,
        .root = root,
        .options = options,
        .paths_arena = .init(gpa),
    };
    errdefer self.paths_arena.deinit();
    errdefer self.dirs.deinit(gpa);
    const rd = try gpa.create(Dir);
    errdefer gpa.destroy(rd);
    rd.* = .{ .path = "", .parent = null };
    try self.dirs.put(gpa, "", rd);
    self.root_dir = rd;
    self.sweep_at = options.max_dirs;
    return self;
}

pub fn deinit(self: *Matcher) void {
    var it = self.dirs.valueIterator();
    while (it.next()) |d| {
        if (d.*.list) |*l| l.deinit(self.gpa);
        d.*.children.deinit(self.gpa);
        self.gpa.destroy(d.*);
    }
    self.dirs.deinit(self.gpa);
    for (&self.sources) |*group| {
        for (group.items) |*l| l.deinit(self.gpa);
        group.deinit(self.gpa);
    }
    self.scratch.deinit(self.gpa);
    self.paths_arena.deinit();
    self.* = undefined;
}

fn warn(self: *const Matcher, msg: []const u8, path: []const u8) void {
    if (self.options.warn) |f| f(self.options.warn_ctx, msg, path);
}

fn wm_options(self: *const Matcher) wildmatch.Options {
    return .{ .case_insensitive = self.options.case_insensitive };
}

pub fn generation(self: *const Matcher) u64 {
    return self.gen;
}

pub fn add_source(
    self: *Matcher,
    precedence: Precedence,
    base: []const u8,
    source_name: []const u8,
    contents: []const u8,
) error{OutOfMemory}!void {
    std.debug.assert(precedence != .per_directory);
    const list = try PatternList.parse(self.gpa, base, source_name, contents);
    errdefer {
        var l = list;
        l.deinit(self.gpa);
    }
    try self.sources[@intFromEnum(precedence)].append(self.gpa, list);
    self.total_pattern_bytes += contents.len;
    self.invalidate_all();
}

pub fn add_source_file(
    self: *Matcher,
    io: std.Io,
    precedence: Precedence,
    base: []const u8,
    source_name: []const u8,
    path: []const u8,
) error{OutOfMemory}!void {
    const contents = self.root.readFileAlloc(io, path, self.gpa, .limited(self.options.max_file_size)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    defer self.gpa.free(contents);
    try self.add_source(precedence, base, source_name, contents);
}

pub fn update_source(
    self: *Matcher,
    precedence: Precedence,
    base: []const u8,
    source_name: []const u8,
    contents: ?[]const u8,
) error{OutOfMemory}!void {
    std.debug.assert(precedence != .per_directory);
    const group = &self.sources[@intFromEnum(precedence)];
    var i: usize = 0;
    while (i < group.items.len) {
        if (std.mem.eql(u8, group.items[i].name, source_name)) {
            self.total_pattern_bytes -|= group.items[i].buf.len;
            group.items[i].deinit(self.gpa);
            _ = group.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    if (contents) |c| {
        try self.add_source(precedence, base, source_name, c);
    } else {
        self.invalidate_all();
    }
}

fn normalize(self: *Matcher, path: []const u8) error{OutOfMemory}!?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return null;
    // a drive-qualified Windows path is not project-relative
    if (self.options.accept_backslash_separator and path.len >= 2 and path[1] == ':') return null;
    if (self.options.accept_backslash_separator and path[0] == '\\') return null;

    self.scratch.clearRetainingCapacity();
    try self.scratch.ensureTotalCapacity(self.gpa, path.len);

    var i: usize = 0;
    while (i + 1 < path.len and path[i] == '.' and is_sep(self, path[i + 1])) i += 2;

    var last_was_sep = true;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (is_sep(self, c)) {
            if (!last_was_sep) {
                self.scratch.appendAssumeCapacity('/');
                last_was_sep = true;
            }
            continue;
        }
        last_was_sep = false;
        self.scratch.appendAssumeCapacity(c);
    }
    var out: []const u8 = self.scratch.items;
    while (out.len > 0 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    if (out.len == 0) return null;

    // reject traversal rather than guessing at its meaning
    var it = std.mem.splitScalar(u8, out, '/');
    while (it.next()) |comp| if (std.mem.eql(u8, comp, "..")) return null;
    return out;
}

fn is_sep(self: *const Matcher, c: u8) bool {
    return c == '/' or (self.options.accept_backslash_separator and c == '\\');
}

fn dirname_of(rel: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[0..i] else "";
}

fn basename_of(rel: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
}

fn ensure_loaded(self: *Matcher, io: std.Io, dir: *Dir) error{OutOfMemory}!void {
    if (dir.loaded) return;
    dir.loaded = true;
    if (self.total_pattern_bytes >= self.options.max_total_pattern_bytes) {
        if (!self.degraded) {
            self.degraded = true;
            self.warn("ignore ruleset too large; no further ignore files will be loaded", dir.path);
        }
        return;
    }

    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(self.gpa);
    if (dir.path.len > 0) {
        try name_buf.appendSlice(self.gpa, dir.path);
        try name_buf.append(self.gpa, '/');
    }
    try name_buf.appendSlice(self.gpa, self.options.per_directory_file);

    const contents = self.root.readFileAlloc(
        io,
        name_buf.items,
        self.gpa,
        .limited(self.options.max_file_size),
    ) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
            self.warn("ignore file too large; skipped", name_buf.items);
            return;
        },
        else => return,
    };
    defer self.gpa.free(contents);

    dir.list = try PatternList.parse(self.gpa, dir.path, name_buf.items, contents);
    self.total_pattern_bytes += contents.len;
}

const ResolveCtx = struct {
    m: *Matcher,
    io: std.Io,

    // git resolves an unknown dtype with lstat, so a symlink to a directory
    // is not a directory
    fn resolve(ctx: ?*anyopaque, rel: []const u8) DType {
        const self: *ResolveCtx = @ptrCast(@alignCast(ctx.?));
        const st = self.m.root.statFile(self.io, rel, .{ .follow_symlinks = false }) catch return .unknown;
        return switch (st.kind) {
            .directory => .dir,
            else => .file,
        };
    }
};

const ChainResult = struct {
    decision: Decision = .undecided,
    attribution: ?Attribution = null,
};

fn decide(list: *const PatternList, p: *const Pattern) ChainResult {
    return .{
        .decision = if (p.flags.negative) .not_ignored else .ignored,
        .attribution = Attribution.of(list, p),
    };
}

/// Highest precedence group first, first hit wins. Within the per-directory
/// group the deepest .gitignore wins, so that chain is walked upwards.
fn match_chain(
    self: *Matcher,
    io: std.Io,
    dir: *Dir,
    rel: []const u8,
    basename: []const u8,
    dtype_in: DType,
) error{OutOfMemory}!ChainResult {
    var q: Query = .{
        .rel = rel,
        .basename = basename,
        .dtype = dtype_in,
        .ctx = .{ .m = self, .io = io },
        .opts = self.wm_options(),
    };

    if (self.scan_group(.command_line, &q)) |r| return r;

    var node: ?*Dir = dir;
    while (node) |n| {
        try self.ensure_loaded(io, n);
        if (n.list) |*l| if (q.run(l)) |r| return r;
        node = n.parent;
    }

    if (self.scan_group(.repository, &q)) |r| return r;
    if (self.scan_group(.global, &q)) |r| return r;
    return .{};
}

/// One path being evaluated. `dtype` is threaded across every list consulted so
/// it is resolved at most once.
const Query = struct {
    rel: []const u8,
    basename: []const u8,
    dtype: DType,
    ctx: ResolveCtx,
    opts: wildmatch.Options,

    fn run(q: *Query, list: *const PatternList) ?ChainResult {
        const p = list.last_match(q.rel, q.basename, &q.dtype, ResolveCtx.resolve, &q.ctx, q.opts) orelse return null;
        return decide(list, p);
    }
};

/// Later registrations win within a level, hence the reverse scan.
fn scan_group(self: *Matcher, precedence: Precedence, q: *Query) ?ChainResult {
    const group = self.sources[@intFromEnum(precedence)].items;
    var i = group.len;
    while (i > 0) {
        i -= 1;
        if (q.run(&group[i])) |r| return r;
    }
    return null;
}

fn child_dir(
    self: *Matcher,
    io: std.Io,
    parent: *Dir,
    child_rel: []const u8,
    comp: []const u8,
) error{OutOfMemory}!*Dir {
    if (self.dirs.get(child_rel)) |d| return d;

    var excluded = false;
    var attribution: ?Attribution = null;
    if (parent.excluded) {
        // terminal: the ignore file inside is never read
        excluded = true;
        attribution = parent.excluded_by;
    } else {
        try self.ensure_loaded(io, parent);
        const r = try self.match_chain(io, parent, child_rel, comp, .dir);
        if (r.decision == .ignored) {
            excluded = true;
            attribution = r.attribution;
        }
    }

    const path = try self.paths_arena.allocator().dupe(u8, child_rel);
    const d = try self.gpa.create(Dir);
    errdefer self.gpa.destroy(d);
    d.* = .{
        .path = path,
        .parent = parent,
        .excluded = excluded,
        .excluded_by = attribution,
        .loaded = excluded,
    };
    try self.dirs.put(self.gpa, path, d);
    errdefer _ = self.dirs.remove(path);
    try parent.children.append(self.gpa, d);

    if (self.dirs.count() > self.sweep_at) self.sweep();
    return d;
}

fn resolve_dir(self: *Matcher, io: std.Io, dir_rel: []const u8) error{OutOfMemory}!*Dir {
    var node = self.root_dir;
    if (dir_rel.len == 0) return node;
    var it = std.mem.splitScalar(u8, dir_rel, '/');
    var off: usize = 0;
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        off += comp.len;
        node = try self.child_dir(io, node, dir_rel[0..off], comp);
        off += 1;
        if (node.excluded) return node;
    }
    return node;
}

/// Decision with attribution
pub fn check(
    self: *Matcher,
    io: std.Io,
    rel_path: []const u8,
    dtype: DType,
) error{OutOfMemory}!MatchInfo {
    const rel = (try self.normalize(rel_path)) orelse return .{};
    // normalize returns a view of self.scratch, which match_chain may reuse
    const owned = try self.gpa.dupe(u8, rel);
    defer self.gpa.free(owned);

    const d = try self.resolve_dir(io, dirname_of(owned));
    if (d.excluded) {
        const a = d.excluded_by orelse return .{ .decision = .ignored };
        return .{
            .decision = .ignored,
            .source = a.source,
            .line_no = a.line_no,
            .pattern = a.pattern,
            .negative = a.negative,
        };
    }
    const r = try self.match_chain(io, d, owned, basename_of(owned), dtype);
    if (r.attribution) |a| return .{
        .decision = r.decision,
        .source = a.source,
        .line_no = a.line_no,
        .pattern = a.pattern,
        .negative = a.negative,
    };
    return .{ .decision = r.decision };
}

pub fn is_ignored(
    self: *Matcher,
    io: std.Io,
    rel_path: []const u8,
    dtype: DType,
) error{OutOfMemory}!bool {
    return (try self.check(io, rel_path, dtype)).decision == .ignored;
}

/// Test this before `is_ignored`: a .gitignore may itself be ignored by a
/// parent rule, and its change events are still needed.
pub fn is_ignore_file(self: *const Matcher, rel_path: []const u8) bool {
    // no normalize here, which would need a mutable self
    const base = if (std.mem.lastIndexOfAny(u8, rel_path, if (self.options.accept_backslash_separator) "/\\" else "/")) |i|
        rel_path[i + 1 ..]
    else
        rel_path;
    if (std.mem.eql(u8, base, self.options.per_directory_file)) return true;
    for (self.sources) |group| {
        for (group.items) |l| if (std.mem.eql(u8, l.name, rel_path)) return true;
    }
    return false;
}

fn drop_node(self: *Matcher, d: *Dir) void {
    for (d.children.items) |c| self.drop_node(c);
    d.children.deinit(self.gpa);
    if (d.list) |*l| {
        self.total_pattern_bytes -|= l.buf.len;
        l.deinit(self.gpa);
    }
    _ = self.dirs.remove(d.path);
    self.gpa.destroy(d);
}

fn drop_children(self: *Matcher, d: *Dir) void {
    for (d.children.items) |c| self.drop_node(c);
    d.children.clearRetainingCapacity();
}

pub fn invalidate_dir(self: *Matcher, dir_rel: []const u8) void {
    const key = self.normalize(dir_rel) catch return orelse "";
    const d = self.dirs.get(key) orelse return;
    self.drop_children(d);
    if (d.list) |*l| {
        self.total_pattern_bytes -|= l.buf.len;
        l.deinit(self.gpa);
        d.list = null;
    }
    d.loaded = false;
    self.gen += 1;
}

pub fn invalidate_subtree(self: *Matcher, dir_rel: []const u8) void {
    const key = self.normalize(dir_rel) catch return orelse {
        self.invalidate_all();
        return;
    };
    const d = self.dirs.get(key) orelse return;
    if (d.parent) |p| {
        for (p.children.items, 0..) |c, i| {
            if (c == d) {
                _ = p.children.orderedRemove(i);
                break;
            }
        }
    }
    self.drop_node(d);
    self.gen += 1;
}

pub fn invalidate_all(self: *Matcher) void {
    self.drop_children(self.root_dir);
    if (self.root_dir.list) |*l| {
        self.total_pattern_bytes -|= l.buf.len;
        l.deinit(self.gpa);
        self.root_dir.list = null;
    }
    self.root_dir.loaded = false;
    self.root_dir.excluded = false;
    self.root_dir.excluded_by = null;
    self.gen += 1;
}

fn sweep(self: *Matcher) void {
    self.sweep_node(self.root_dir);
    self.sweep_at = @max(self.options.max_dirs, self.dirs.count() * 2);
}

fn sweep_node(self: *Matcher, d: *Dir) void {
    var i: usize = 0;
    while (i < d.children.items.len) {
        const c = d.children.items[i];
        self.sweep_node(c);
        if (c.is_empty() and c.loaded) {
            _ = d.children.orderedRemove(i);
            self.drop_node(c);
            continue;
        }
        i += 1;
    }
}

/// Walk-order view over the same store, keeping the resolved chain on a stack
/// so each entry costs O(1) instead of re-resolving its ancestors.
pub const Cursor = struct {
    m: *Matcher,
    stack: std.ArrayList(*Dir) = .empty,
    /// Must not share `Matcher.scratch`, which normalization also reuses.
    buf: std.ArrayList(u8) = .empty,
    /// a cursor cannot survive a ruleset change
    gen: u64,

    pub fn deinit(self: *Cursor) void {
        self.stack.deinit(self.m.gpa);
        self.buf.deinit(self.m.gpa);
        self.* = undefined;
    }

    fn top(self: *const Cursor) *Dir {
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn path(self: *const Cursor) []const u8 {
        return self.top().path;
    }

    /// Does no I/O, so an ignored subtree can be rejected before `openDir`.
    pub fn would_ignore_dir(self: *Cursor, io: std.Io, name: []const u8) bool {
        const child_rel = self.joined(name) catch return false;
        if (self.m.dirs.get(child_rel)) |d| return d.excluded;
        return self.is_ignored_entry(io, name, .dir) catch false;
    }

    pub fn push_dir(self: *Cursor, io: std.Io, name: []const u8) error{OutOfMemory}!void {
        std.debug.assert(self.gen == self.m.gen);
        const parent = self.top();
        const child_rel = try self.joined(name);
        const d = try self.m.child_dir(io, parent, child_rel, name);
        try self.stack.append(self.m.gpa, d);
    }

    pub fn pop_dir(self: *Cursor) void {
        std.debug.assert(self.gen == self.m.gen);
        std.debug.assert(self.stack.items.len > 1);
        const d = self.stack.pop().?;
        if (!self.m.options.retain_empty_dirs and d.is_empty()) {
            if (d.parent) |p| {
                for (p.children.items, 0..) |c, i| {
                    if (c == d) {
                        _ = p.children.orderedRemove(i);
                        break;
                    }
                }
            }
            self.m.drop_node(d);
        }
    }

    pub fn is_ignored_entry(self: *Cursor, io: std.Io, name: []const u8, dtype: DType) error{OutOfMemory}!bool {
        std.debug.assert(self.gen == self.m.gen);
        const parent = self.top();
        if (parent.excluded) return true;
        const child_rel = try self.joined(name);
        try self.m.ensure_loaded(io, parent);
        const r = try self.m.match_chain(io, parent, child_rel, name, dtype);
        return r.decision == .ignored;
    }

    fn joined(self: *Cursor, name: []const u8) error{OutOfMemory}![]const u8 {
        const parent = self.top();
        const buf = &self.buf;
        buf.clearRetainingCapacity();
        try buf.ensureTotalCapacity(self.m.gpa, parent.path.len + 1 + name.len);
        buf.appendSliceAssumeCapacity(parent.path);
        if (parent.path.len > 0) buf.appendAssumeCapacity('/');
        buf.appendSliceAssumeCapacity(name);
        return buf.items;
    }
};

pub fn cursor(self: *Matcher) error{OutOfMemory}!Cursor {
    var c: Cursor = .{ .m = self, .gen = self.gen };
    try c.stack.append(self.gpa, self.root_dir);
    return c;
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    m: Matcher,

    fn init(spec: []const []const u8, options: Options) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const io = testing.io;
        for (spec) |entry| {
            if (entry[entry.len - 1] == '/') {
                try tmp.dir.createDirPath(io, entry[0 .. entry.len - 1]);
                continue;
            }
            const sep = std.mem.indexOfScalar(u8, entry, 0);
            const path = if (sep) |s| entry[0..s] else entry;
            const data = if (sep) |s| entry[s + 1 ..] else "";
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |i|
                try tmp.dir.createDirPath(io, path[0..i]);
            try tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
        }
        return .{ .tmp = tmp, .m = try Matcher.init(testing.allocator, tmp.dir, options) };
    }

    fn deinit(self: *Fixture) void {
        self.m.deinit();
        self.tmp.cleanup();
    }

    fn sweep_for_test(self: *Fixture) void {
        self.m.sweep();
    }

    fn ignored(self: *Fixture, path: []const u8, dtype: DType) !bool {
        return self.m.is_ignored(testing.io, path, dtype);
    }

    fn expect(self: *Fixture, path: []const u8, dtype: DType, want: bool) !void {
        const got = try self.ignored(path, dtype);
        if (got != want) {
            std.debug.print("path '{s}' ({s}): expected ignored={}, got {}\n", .{ path, @tagName(dtype), want, got });
            return error.TestExpectedEqual;
        }
    }
};

test "basic ignore and negation" {
    var f = try Fixture.init(&.{
        ".gitignore\x00*.log\n!keep.log\n",
        "x.log",
        "keep.log",
        "src/y.log",
    }, .{});
    defer f.deinit();
    try f.expect("x.log", .file, true);
    try f.expect("keep.log", .file, false);
    try f.expect("src/y.log", .file, true);
}

test "deeper gitignore wins over shallower" {
    var f = try Fixture.init(&.{
        ".gitignore\x00*.log\n",
        "sub/.gitignore\x00!*.log\n",
        "a.log",
        "sub/b.log",
    }, .{});
    defer f.deinit();
    try f.expect("a.log", .file, true);
    try f.expect("sub/b.log", .file, false);
}

test "an ignored directory is terminal" {
    // A negation inside an ignored directory must have no effect, and that
    // directory's .gitignore must never even be read.
    var f = try Fixture.init(&.{
        ".gitignore\x00a/\n",
        "a/.gitignore\x00!*\n!c\n",
        "a/b/c",
        "a/keep",
    }, .{});
    defer f.deinit();
    try f.expect("a", .dir, true);
    try f.expect("a/keep", .file, true);
    try f.expect("a/b/c", .file, true);

    // attribution comes from the parent's pattern, as git reports it
    const info = try f.m.check(testing.io, "a/b/c", .file);
    try testing.expectEqual(Decision.ignored, info.decision);
    try testing.expectEqualStrings(".gitignore", info.source);
    try testing.expectEqual(@as(u32, 1), info.line_no);
    try testing.expectEqualStrings("a/", info.pattern);
}

test "a negation cannot rescue a child of an excluded directory" {
    var f = try Fixture.init(&.{
        ".gitignore\x00a/\n!a/b/c\n",
        "a/b/c",
    }, .{});
    defer f.deinit();
    try f.expect("a/b/c", .file, true);
}

test "a negative directory match does not stop the descent" {
    var f = try Fixture.init(&.{
        ".gitignore\x00!a/\n*.log\n",
        "a/x.log",
        "a/y",
    }, .{});
    defer f.deinit();
    try f.expect("a/x.log", .file, true);
    try f.expect("a/y", .file, false);
}

test "directory-only patterns need the right dtype" {
    var f = try Fixture.init(&.{
        ".gitignore\x00foo/\n",
        "asfile/foo",
        "asdir/foo/y",
        "asdir/foo/inner/x",
    }, .{});
    defer f.deinit();
    try f.expect("asfile/foo", .file, false);
    try f.expect("asdir/foo", .dir, true);
    try f.expect("asdir/foo/y", .file, true);
    try f.expect("asdir/foo/inner/x", .file, true);
    // an unknown dtype is resolved by stat, so a real directory still matches
    try f.expect("asdir/foo", .unknown, true);
    try f.expect("asfile/foo", .unknown, false);
}

test "plain patterns match files and directories alike" {
    var f = try Fixture.init(&.{
        ".gitignore\x00foo\n",
        "asfile/foo",
        "asdir/foo/y",
    }, .{});
    defer f.deinit();
    try f.expect("asfile/foo", .file, true);
    try f.expect("asdir/foo", .dir, true);
    try f.expect("asdir/foo/y", .file, true);
}

test "anchoring" {
    var f = try Fixture.init(&.{
        ".gitignore\x00/foo/\n",
        "foo/f",
        "sub/foo/f",
        "deep/er/foo/f",
        "foo_file",
    }, .{});
    defer f.deinit();
    try f.expect("foo", .dir, true);
    try f.expect("foo/f", .file, true);
    try f.expect("sub/foo", .dir, false);
    try f.expect("deep/er/foo", .dir, false);
    try f.expect("foo_file", .file, false);
}

test "unanchored directory patterns match at any depth" {
    var f = try Fixture.init(&.{
        ".gitignore\x00foo/\n",
        "foo/f",
        "sub/foo/f",
        "deep/er/foo/f",
        "foo_file",
    }, .{});
    defer f.deinit();
    try f.expect("foo", .dir, true);
    try f.expect("sub/foo", .dir, true);
    try f.expect("deep/er/foo", .dir, true);
    try f.expect("foo_file", .file, false);
}

test "a nested gitignore anchors to its own directory" {
    var f = try Fixture.init(&.{
        "sub/.gitignore\x00/foo/\n",
        "foo/f",
        "sub/foo/f",
        "sub/deep/foo/f",
    }, .{});
    defer f.deinit();
    try f.expect("foo", .dir, false);
    try f.expect("sub/foo", .dir, true);
    try f.expect("sub/deep/foo", .dir, false);
}

test "precedence between registered sources and the gitignore chain" {
    var f = try Fixture.init(&.{"zz"}, .{});
    defer f.deinit();

    // global says ignore, repository re-includes: repository wins
    try f.m.add_source(.global, "", "git/ignore", "zz\n");
    try f.m.add_source(.repository, "", "info/exclude", "!zz\n");
    try f.expect("zz", .file, false);

    // the other way round
    try f.m.update_source(.global, "", "git/ignore", "!zz\n");
    try f.m.update_source(.repository, "", "info/exclude", "zz\n");
    try f.expect("zz", .file, true);

    // a .gitignore outranks both
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "!zz\n" });
    f.m.invalidate_all();
    try f.expect("zz", .file, false);

    // and the command line outranks everything
    try f.m.add_source(.command_line, "", "--exclude", "zz\n");
    try f.expect("zz", .file, true);
}

test "a registered source can be anchored to a subdirectory" {
    var f = try Fixture.init(&.{ "x", "sub/x" }, .{});
    defer f.deinit();
    try f.m.add_source(.repository, "sub", "info/exclude", "/x\n");
    try f.expect("sub/x", .file, true);
    try f.expect("x", .file, false);
}

test "the builtin fallback list prunes the historical directories" {
    var f = try Fixture.init(&.{
        "node_modules/pkg/index.js",
        "deep/node_modules/pkg/index.js",
        ".zig-cache/o/x",
        "src/main.zig",
    }, .{});
    defer f.deinit();
    try f.m.add_source(.global, "", "builtin", @import("gitignore.zig").builtin_patterns);
    try f.expect("node_modules", .dir, true);
    try f.expect("deep/node_modules", .dir, true);
    try f.expect("node_modules/pkg/index.js", .file, true);
    try f.expect(".zig-cache", .dir, true);
    try f.expect("src/main.zig", .file, false);
}

test "case insensitivity" {
    var f = try Fixture.init(&.{ ".gitignore\x00FOO\n", "foo", "FOO" }, .{});
    defer f.deinit();
    try f.expect("FOO", .file, true);
    try f.expect("foo", .file, false);

    var g = try Fixture.init(&.{ ".gitignore\x00FOO\n", "foo" }, .{ .case_insensitive = true });
    defer g.deinit();
    try g.expect("foo", .file, true);
}

test "path normalization" {
    var f = try Fixture.init(&.{ ".gitignore\x00*.log\n", "a/x.log" }, .{});
    defer f.deinit();
    try f.expect("./a/x.log", .file, true);
    try f.expect("a//x.log", .file, true);
    try f.expect("a/x.log/", .file, true);
    // paths that cannot be resolved against the root are never ignored
    try f.expect("/a/x.log", .file, false);
    try f.expect("../a/x.log", .file, false);
}

test "backslash separators only when enabled" {
    var f = try Fixture.init(&.{ ".gitignore\x00*.log\n", "a/x.log" }, .{ .accept_backslash_separator = true });
    defer f.deinit();
    try f.expect("a\\x.log", .file, true);
}

test "invalidation picks up a changed gitignore" {
    var f = try Fixture.init(&.{ ".gitignore\x00*.log\n", "x.log" }, .{});
    defer f.deinit();
    try f.expect("x.log", .file, true);
    const before = f.m.generation();

    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "!*.log\n" });
    f.m.invalidate_dir("");
    try testing.expect(f.m.generation() != before);
    try f.expect("x.log", .file, false);
}

test "invalidation drops stale descendants" {
    var f = try Fixture.init(&.{
        ".gitignore\x00a/\n",
        "a/b/c",
    }, .{});
    defer f.deinit();
    try f.expect("a/b/c", .file, true);

    // stop ignoring a/: the cached terminal nodes below it must go
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "\n" });
    f.m.invalidate_dir("");
    try f.expect("a/b/c", .file, false);
}

test "subtree invalidation" {
    var f = try Fixture.init(&.{
        "a/.gitignore\x00*.log\n",
        "a/x.log",
    }, .{});
    defer f.deinit();
    try f.expect("a/x.log", .file, true);

    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a/.gitignore", .data = "\n" });
    f.m.invalidate_subtree("a");
    try f.expect("a/x.log", .file, false);
}

test "is_ignore_file" {
    var f = try Fixture.init(&.{"x"}, .{});
    defer f.deinit();
    try f.m.add_source(.repository, "", "info/exclude", "\n");
    try testing.expect(f.m.is_ignore_file(".gitignore"));
    try testing.expect(f.m.is_ignore_file("a/b/.gitignore"));
    try testing.expect(f.m.is_ignore_file("info/exclude"));
    try testing.expect(!f.m.is_ignore_file("a/gitignore"));
    try testing.expect(!f.m.is_ignore_file("src/main.zig"));
}

test "the sweep drops only information-free nodes" {
    var f = try Fixture.init(&.{
        ".gitignore\x00*.log\n",
        "a/b/c/d/x.log",
        "a/b/c/d/keep",
    }, .{});
    defer f.deinit();
    try f.expect("a/b/c/d/x.log", .file, true);
    try f.expect("a/b/c/d/keep", .file, false);
    f.sweep_for_test();
    try f.expect("a/b/c/d/x.log", .file, true);
    try f.expect("a/b/c/d/keep", .file, false);
}

test "an aggressive max_dirs changes no answer" {
    var f = try Fixture.init(&.{
        ".gitignore\x00*.log\nbuild/\n",
        "a/b/c/d/x.log",
        "a/b/c/d/keep",
        "build/out",
    }, .{ .max_dirs = 1 });
    defer f.deinit();
    try f.expect("a/b/c/d/x.log", .file, true);
    try f.expect("a/b/c/d/keep", .file, false);
    try f.expect("build", .dir, true);
    try f.expect("build/out", .file, true);
    try f.expect("a/b/c/d/x.log", .file, true);
}

test "cursor tracks the walk and agrees with random access" {
    var f = try Fixture.init(&.{
        ".gitignore\x00*.log\nbuild/\n",
        "src/.gitignore\x00!important.log\n",
        "src/a.log",
        "src/important.log",
        "src/main.zig",
        "build/out",
    }, .{ .retain_empty_dirs = false });
    defer f.deinit();

    var c = try f.m.cursor();
    defer c.deinit();
    const io = testing.io;

    try testing.expect(!c.would_ignore_dir(io, "src"));
    try testing.expect(c.would_ignore_dir(io, "build"));

    try c.push_dir(io, "src");
    try testing.expectEqualStrings("src", c.path());
    try testing.expect(try c.is_ignored_entry(io, "a.log", .file));
    try testing.expect(!try c.is_ignored_entry(io, "important.log", .file));
    try testing.expect(!try c.is_ignored_entry(io, "main.zig", .file));
    c.pop_dir();
    try testing.expectEqualStrings("", c.path());

    // the same verdicts through the random-access path
    try f.expect("src/a.log", .file, true);
    try f.expect("src/important.log", .file, false);
    try f.expect("build", .dir, true);
}
