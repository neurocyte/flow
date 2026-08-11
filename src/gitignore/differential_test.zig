//! Differential test against real git.

const std = @import("std");
const gitignore = @import("gitignore.zig");
const Matcher = gitignore.Matcher;

const testing = std.testing;

const max_output = 1 << 24;

fn env_is_set(name: []const u8) bool {
    var map = std.testing.io_instance.environ.process_environ.createMap(testing.allocator) catch return false;
    defer map.deinit();
    return map.get(name) != null;
}

fn git_available() bool {
    const r = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "git", "--version" },
    }) catch return false;
    defer testing.allocator.free(r.stdout);
    defer testing.allocator.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

const Repo = struct {
    tmp: testing.TmpDir,
    dir: std.Io.Dir,
    abs: []u8,
    /// git reports core.excludesFile matches by the absolute path it opened, so
    /// that source has to be registered under the same name.
    root_abs: []u8,
    env: std.process.Environ.Map,

    fn init() !Repo {
        const io = testing.io;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();

        try tmp.dir.createDirPath(io, "repo");
        try tmp.dir.createDirPath(io, "home");
        try tmp.dir.createDirPath(io, "xdg/git");
        try tmp.dir.writeFile(io, .{ .sub_path = "empty.gitconfig", .data = "" });

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_abs = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];

        // nothing ambient leaks in; argv[0] still resolves against the
        // parent's PATH, so git is found regardless
        var env = std.process.Environ.Map.init(testing.allocator);
        errdefer env.deinit();
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        try env.put("GIT_TERMINAL_PROMPT", "0");
        try env.put("GIT_OPTIONAL_LOCKS", "0");
        try env.put("LC_ALL", "C");
        try env.put("TZ", "UTC");

        var buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
        try env.put("HOME", try std.fmt.bufPrint(&buf, "{s}/home", .{root_abs}));
        try env.put("XDG_CONFIG_HOME", try std.fmt.bufPrint(&buf, "{s}/xdg", .{root_abs}));
        try env.put("GIT_CONFIG_GLOBAL", try std.fmt.bufPrint(&buf, "{s}/empty.gitconfig", .{root_abs}));
        try env.put("GIT_CONFIG_SYSTEM", try std.fmt.bufPrint(&buf, "{s}/empty.gitconfig", .{root_abs}));
        try env.put("GIT_CEILING_DIRECTORIES", root_abs);

        const abs = try std.fmt.allocPrint(testing.allocator, "{s}/repo", .{root_abs});
        errdefer testing.allocator.free(abs);
        const root_owned = try testing.allocator.dupe(u8, root_abs);
        errdefer testing.allocator.free(root_owned);

        var dir = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
        errdefer dir.close(io);

        var self: Repo = .{ .tmp = tmp, .dir = dir, .abs = abs, .root_abs = root_owned, .env = env };
        // an empty template suppresses the default .git/info/exclude, and git
        // then does not create info/ at all
        try self.git(&.{ "init", "-q", "--template=", "." });
        try self.dir.createDirPath(io, ".git/info");
        return self;
    }

    fn deinit(self: *Repo) void {
        self.dir.close(testing.io);
        testing.allocator.free(self.abs);
        testing.allocator.free(self.root_abs);
        self.env.deinit();
        self.tmp.cleanup();
    }

    fn git(self: *Repo, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.append(testing.allocator, "git");
        try argv.appendSlice(testing.allocator, args);

        const r = try std.process.run(testing.allocator, testing.io, .{
            .argv = argv.items,
            .cwd = .{ .dir = self.dir },
            .environ_map = &self.env,
        });
        defer testing.allocator.free(r.stdout);
        defer testing.allocator.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], r.stderr });
            return error.GitFailed;
        }
    }

    fn write(self: *Repo, path: []const u8, data: []const u8) !void {
        const io = testing.io;
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i|
            try self.dir.createDirPath(io, path[0..i]);
        try self.dir.writeFile(io, .{ .sub_path = path, .data = data });
    }

    fn mkdir(self: *Repo, path: []const u8) !void {
        try self.dir.createDirPath(testing.io, path);
    }

    /// A record is emitted whenever some pattern matched, negations included,
    /// so a non-empty `source` does not mean ignored. git marks a negation by
    /// printing the leading `!`.
    const Verdict = struct {
        matched: bool,
        ignored: bool,
        source: []const u8,
        line_no: u32,
        pattern: []const u8,
    };

    /// Returned slices borrow `out`.
    fn check_ignore(
        self: *Repo,
        gpa: std.mem.Allocator,
        paths: []const []const u8,
        out: *std.ArrayList(u8),
    ) !std.StringHashMapUnmanaged(Verdict) {
        const io = testing.io;

        var stdin_buf: std.ArrayList(u8) = .empty;
        defer stdin_buf.deinit(gpa);
        for (paths) |p| {
            try stdin_buf.appendSlice(gpa, p);
            try stdin_buf.append(gpa, 0);
        }

        var child = try std.process.spawn(io, .{
            .argv = &.{ "git", "check-ignore", "-v", "--non-matching", "--no-index", "--stdin", "-z" },
            .cwd = .{ .dir = self.dir },
            .environ_map = &self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(io);

        // batches fit in the pipe buffer, so write-then-read cannot deadlock
        try child.stdin.?.writeStreamingAll(io, stdin_buf.items);
        child.stdin.?.close(io);
        child.stdin = null;

        var read_buf: [4096]u8 = undefined;
        var reader = child.stdout.?.reader(io, &read_buf);
        out.clearRetainingCapacity();
        try reader.interface.appendRemaining(gpa, out, .limited(max_output));

        var err_buf: [1024]u8 = undefined;
        var err_reader = child.stderr.?.reader(io, &err_buf);
        const stderr = try err_reader.interface.allocRemaining(gpa, .limited(1 << 16));
        defer gpa.free(stderr);

        const term = try child.wait(io);
        if (term != .exited or term.exited >= 2) {
            std.debug.print("git check-ignore failed ({any}): {s}\n", .{ term, stderr });
            return error.GitFailed;
        }

        var map: std.StringHashMapUnmanaged(Verdict) = .empty;
        errdefer map.deinit(gpa);
        var it = std.mem.splitScalar(u8, out.items, 0);
        while (true) {
            const source = it.next() orelse break;
            if (source.len == 0 and it.rest().len == 0) break;
            const line = it.next() orelse break;
            const pattern = it.next() orelse break;
            const path = it.next() orelse break;
            const matched = source.len != 0;
            try map.put(gpa, path, .{
                .matched = matched,
                .ignored = matched and !(pattern.len > 0 and pattern[0] == '!'),
                .source = source,
                .line_no = if (line.len == 0) 0 else try std.fmt.parseInt(u32, line, 10),
                .pattern = pattern,
            });
        }
        return map;
    }
};

/// Paths to query, each tagged with whether it is a directory.
const Corpus = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { path: []const u8, is_dir: bool };

    fn deinit(self: *Corpus) void {
        self.entries.deinit(testing.allocator);
    }

    fn add(self: *Corpus, path: []const u8, is_dir: bool) !void {
        try self.entries.append(testing.allocator, .{ .path = path, .is_dir = is_dir });
    }

    fn join(self: *Corpus, parent: []const u8, name: []const u8) ![]const u8 {
        return if (parent.len == 0)
            self.arena.dupe(u8, name)
        else
            std.fmt.allocPrint(self.arena, "{s}/{s}", .{ parent, name });
    }
};

fn compare_all(repo: *Repo, m: *Matcher, corpus: *const Corpus) !void {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var batch: std.ArrayList([]const u8) = .empty;
    defer batch.deinit(gpa);

    var i: usize = 0;
    while (i < corpus.entries.items.len) {
        const end = @min(i + 256, corpus.entries.items.len);
        batch.clearRetainingCapacity();
        for (corpus.entries.items[i..end]) |e| try batch.append(gpa, e.path);

        var verdicts = try repo.check_ignore(gpa, batch.items, &out);
        defer verdicts.deinit(gpa);

        for (corpus.entries.items[i..end]) |e| {
            const path = e.path;
            const is_dir = e.is_dir;
            const want = verdicts.get(path) orelse {
                std.debug.print("git returned no record for '{s}'\n", .{path});
                return error.MissingRecord;
            };
            const got = try m.check(testing.io, path, if (is_dir) .dir else .file);
            const got_ignored = got.decision == .ignored;

            if (got_ignored != want.ignored) {
                try dump_failure(repo, path, is_dir, want, got);
                return error.DecisionMismatch;
            }
            if (want.matched != (got.source.len != 0)) {
                try dump_failure(repo, path, is_dir, want, got);
                return error.AttributionMismatch;
            }
            if (!want.matched) continue;
            if (!std.mem.eql(u8, got.source, want.source) or
                got.line_no != want.line_no or
                !std.mem.eql(u8, got.pattern, want.pattern))
            {
                try dump_failure(repo, path, is_dir, want, got);
                return error.AttributionMismatch;
            }
        }
        i = end;
    }
}

fn dump_failure(repo: *Repo, path: []const u8, is_dir: bool, want: Repo.Verdict, got: Matcher.MatchInfo) !void {
    std.debug.print(
        \\
        \\--- gitignore differential mismatch ---
        \\path      : {s} ({s})
        \\git       : ignored={} {s}:{d}:{s}
        \\this      : ignored={} {s}:{d}:{s}
        \\
    , .{
        path,
        if (is_dir) "dir" else "file",
        want.ignored,
        want.source,
        want.line_no,
        want.pattern,
        got.decision == .ignored,
        got.source,
        got.line_no,
        got.pattern,
    });
    // dump every ignore file in play
    const io = testing.io;
    var walker = try repo.dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.indexOf(u8, e.path, ".git/") != null and
            std.mem.indexOf(u8, e.path, ".git/info/exclude") == null) continue;
        const base = std.fs.path.basename(e.path);
        if (!std.mem.eql(u8, base, ".gitignore") and !std.mem.eql(u8, base, "exclude")) continue;
        const data = repo.dir.readFileAlloc(io, e.path, testing.allocator, .limited(1 << 16)) catch continue;
        defer testing.allocator.free(data);
        std.debug.print("--- {s} ---\n{s}\n", .{ e.path, data });
    }
}

fn matcher_for(repo: *Repo, case_insensitive: bool) !Matcher {
    var m = try Matcher.init(testing.allocator, repo.dir, .{ .case_insensitive = case_insensitive });
    errdefer m.deinit();
    try m.add_source_file(testing.io, .repository, "", ".git/info/exclude", ".git/info/exclude");
    return m;
}

test "differential: hand-written cases" {
    if (!git_available() or env_is_set("FLOW_TEST_NO_GIT")) return error.SkipZigTest;
    const gpa = testing.allocator;

    var repo = try Repo.init();
    defer repo.deinit();

    try repo.write(".gitignore",
        \\*.log
        \\!keep.log
        \\/rootonly
        \\anywhere/
        \\build/**
        \\a/**/b
        \\**/deep
        \\[a-c]hoice
        \\[!x]neg
        \\[[:digit:]]digit
        \\\#hash
        \\\!bang
        \\sp\ ace
        \\trail
        \\*.tmp
        \\!important.tmp
    );
    try repo.write("sub/.gitignore",
        \\!*.log
        \\/local
        \\nested
    );
    try repo.write(".git/info/exclude",
        \\excluded-by-info
        \\!*.log
    );

    // materialize the corpus; directory-only patterns resolve dtype via lstat
    const files = [_][]const u8{
        "x.log",               "keep.log",         "rootonly",  "sub/rootonly",
        "anywhere/f",          "deep/anywhere/f",  "build/out", "build/x/y",
        "a/b",                 "a/m/b",            "a/m/n/b",   "deep/f",
        "x/deep/f",            "ahoice",           "dhoice",    "yneg",
        "xneg",                "5digit",           "adigit",    "#hash",
        "!bang",               "sp ace",           "trail",     "q.tmp",
        "important.tmp",       "sub/y.log",        "sub/local", "sub/nested/f",
        "sub/deeper/nested/f", "excluded-by-info", "plain.txt", "sub/plain.txt",
    };
    for (files) |f| try repo.write(f, "");
    try repo.mkdir("anywhere");
    try repo.mkdir("deep/anywhere");
    try repo.mkdir("build");

    var corpus: Corpus = .{ .arena = gpa };
    defer corpus.deinit();
    for (files) |f| try corpus.add(f, false);
    for ([_][]const u8{ "anywhere", "deep/anywhere", "build", "sub", "a", "sub/nested" }) |d|
        try corpus.add(d, true);

    var m = try matcher_for(&repo, false);
    defer m.deinit();
    try compare_all(&repo, &m, &corpus);
}

const names = [_][]const u8{
    "a",   "b",      "c",     "foo",   "bar", ".hidden",
    "x.y", "sp ace", "#hash", "!bang", "[br", "a-b",
    "A",   "B",      "log",   "n1",
};

const pattern_atoms = [_][]const u8{
    "a",       "b",        "foo",     "bar",  "*.y",         "*",
    "?oo",     "[a-c]",    "[!a]",    "[^a]", "[[:digit:]]", "**/foo",
    "foo/**",  "a/**/b",   "/a",      "/foo", "a/b",         "\\#hash",
    "\\!bang", "sp\\ ace", ".hidden", "log",  "*.y ",        "A",
    "n?",      "[br",
};

fn random_tree(repo: *Repo, rand: std.Random, gpa: std.mem.Allocator, corpus: *Corpus) !void {
    var dir_list: std.ArrayList([]const u8) = .empty;
    defer dir_list.deinit(gpa);
    try dir_list.append(gpa, "");

    var depth: usize = 0;
    while (depth < 3) : (depth += 1) {
        const snapshot = try gpa.dupe([]const u8, dir_list.items);
        defer gpa.free(snapshot);
        for (snapshot) |parent| {
            const n = rand.intRangeAtMost(usize, 0, 2);
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const name = names[rand.intRangeLessThan(usize, 0, names.len)];
                const path = try corpus.join(parent, name);
                if (std.mem.eql(u8, path, ".git")) continue;
                try repo.mkdir(path);
                try dir_list.append(gpa, path);
                try corpus.add(path, true);
            }
        }
    }

    for (dir_list.items) |d| {
        const n = rand.intRangeAtMost(usize, 1, 3);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const name = names[rand.intRangeLessThan(usize, 0, names.len)];
            const path = try corpus.join(d, name);
            repo.write(path, "") catch continue;
            try corpus.add(path, false);
        }
        if (rand.intRangeLessThan(usize, 0, 100) < 60) {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(gpa);
            const lines = rand.intRangeAtMost(usize, 1, 5);
            var j: usize = 0;
            while (j < lines) : (j += 1) {
                if (rand.intRangeLessThan(usize, 0, 10) == 0) {
                    try body.appendSlice(gpa, "# a comment\n");
                    continue;
                }
                if (rand.intRangeLessThan(usize, 0, 10) == 0) {
                    try body.append(gpa, '\n');
                    continue;
                }
                if (rand.boolean()) try body.append(gpa, '!');
                try body.appendSlice(gpa, pattern_atoms[rand.intRangeLessThan(usize, 0, pattern_atoms.len)]);
                if (rand.intRangeLessThan(usize, 0, 4) == 0) try body.append(gpa, '/');
                if (rand.intRangeLessThan(usize, 0, 8) == 0) try body.append(gpa, '\r');
                try body.append(gpa, '\n');
            }
            try repo.write(try corpus.join(d, ".gitignore"), body.items);
        }
    }
}

test "differential: generated corpora" {
    if (!git_available() or env_is_set("FLOW_TEST_NO_GIT")) return error.SkipZigTest;
    const gpa = testing.allocator;

    var round: u64 = 0;
    while (round < 12) : (round += 1) {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var repo = try Repo.init();
        defer repo.deinit();

        var prng: std.Random.DefaultPrng = .init(0xA5A5_0000 +% round);
        const rand = prng.random();

        var corpus: Corpus = .{ .arena = arena };
        defer corpus.deinit();

        try random_tree(&repo, rand, gpa, &corpus);

        try repo.write(".git/info/exclude", "bar\n!foo\n");
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "xdg/git/ignore", .data = "log\n" });
        const xdg_name = try std.fmt.allocPrint(gpa, "{s}/xdg/git/ignore", .{repo.root_abs});
        defer gpa.free(xdg_name);

        var m = try Matcher.init(gpa, repo.dir, .{});
        defer m.deinit();
        try m.add_source_file(testing.io, .repository, "", ".git/info/exclude", ".git/info/exclude");
        try m.add_source(.global, "", xdg_name, "log\n");

        if (corpus.entries.items.len == 0) continue;
        compare_all(&repo, &m, &corpus) catch |e| {
            std.debug.print("round {d} failed\n", .{round});
            return e;
        };
    }
}

test "differential: generated corpora, core.ignoreCase" {
    if (!git_available() or env_is_set("FLOW_TEST_NO_GIT")) return error.SkipZigTest;
    const gpa = testing.allocator;

    var round: u64 = 0;
    while (round < 8) : (round += 1) {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var repo = try Repo.init();
        defer repo.deinit();
        try repo.git(&.{ "config", "core.ignoreCase", "true" });

        var prng: std.Random.DefaultPrng = .init(0xC0FFEE_00 +% round);
        const rand = prng.random();

        var corpus: Corpus = .{ .arena = arena };
        defer corpus.deinit();
        try random_tree(&repo, rand, gpa, &corpus);
        if (corpus.entries.items.len == 0) continue;

        var m = try Matcher.init(gpa, repo.dir, .{ .case_insensitive = true });
        defer m.deinit();

        compare_all(&repo, &m, &corpus) catch |e| {
            std.debug.print("ignoreCase round {d} failed\n", .{round});
            return e;
        };
    }
}

test "differential: walker agrees with git ls-files --others" {
    if (!git_available() or env_is_set("FLOW_TEST_NO_GIT")) return error.SkipZigTest;
    const gpa = testing.allocator;

    var repo = try Repo.init();
    defer repo.deinit();

    try repo.write(".gitignore", "*.log\nbuild/\n!keep.log\n");
    try repo.write("src/.gitignore", "!*.log\ntmp/\n");
    for ([_][]const u8{
        "a.log",     "keep.log",     "src/b.log", "src/main.zig",
        "build/out", "build/deep/x", "src/tmp/t", "README",
    }) |f| try repo.write(f, "");

    var m = try Matcher.init(gpa, repo.dir, .{ .retain_empty_dirs = false });
    defer m.deinit();
    var c = try m.cursor();
    defer c.deinit();

    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |p| gpa.free(p);
        found.deinit(gpa);
    }
    try walk(&repo.dir, &c, gpa, &found, "");

    // nothing is staged, so --others is everything not ignored
    const r = try std.process.run(gpa, testing.io, .{
        .argv = &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" },
        .cwd = .{ .dir = repo.dir },
        .environ_map = &repo.env,
    });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(gpa);
    var it = std.mem.splitScalar(u8, r.stdout, 0);
    while (it.next()) |p| {
        if (p.len == 0) continue;
        try expected.append(gpa, p);
    }

    std.mem.sort([]const u8, found.items, {}, less_than);
    std.mem.sort([]const u8, expected.items, {}, less_than);

    if (found.items.len != expected.items.len) {
        std.debug.print("walker found {d} files, git found {d}\n", .{ found.items.len, expected.items.len });
        for (found.items) |p| std.debug.print("  walker: {s}\n", .{p});
        for (expected.items) |p| std.debug.print("  git   : {s}\n", .{p});
        return error.TestExpectedEqual;
    }
    for (found.items, expected.items) |a, b| try testing.expectEqualStrings(b, a);
}

fn less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn walk(
    dir: *std.Io.Dir,
    c: *Matcher.Cursor,
    gpa: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    prefix: []const u8,
) !void {
    const io = testing.io;
    var d = try dir.openDir(io, if (prefix.len == 0) "." else prefix, .{ .iterate = true });
    defer d.close(io);
    var iter = d.iterate();
    while (try iter.next(io)) |e| {
        const child = if (prefix.len == 0)
            try std.fmt.allocPrint(gpa, "{s}", .{e.name})
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, e.name });
        var keep = false;
        defer if (!keep) gpa.free(child);

        switch (e.kind) {
            .directory => {
                // git never descends into .git whatever the rules say
                if (std.mem.eql(u8, e.name, ".git")) continue;
                if (c.would_ignore_dir(io, e.name)) continue;
                try c.push_dir(io, e.name);
                defer c.pop_dir();
                try walk(dir, c, gpa, out, child);
            },
            .file => {
                if (try c.is_ignored_entry(io, e.name, .file)) continue;
                try out.append(gpa, child);
                keep = true;
            },
            else => {},
        }
    }
}
