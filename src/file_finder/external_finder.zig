//! A project file finder backed by an external executable.
//!
//! The finder keeps only the project's recently used files itself. Non-empty
//! queries invoke the configured executable in the project directory as:
//!
//!   <executable> --json --limit <maximum-results> --client flow -- <query>
//!
//! It must write one JSON object to stdout with this shape:
//!
//!   {"root":"/absolute/repository/root","results":[
//!     {"path":"relative/file","matchIndexes":[0,1]}
//!   ]}
//!
//! `matchIndexes` are byte offsets into `path`. Results are translated to the
//! same messages as the built-in file finder. See file_finder.zig.

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const bin_path = @import("bin_path");
const file_type_config = @import("file_type_config");
const root = @import("soft_root").root;

const file_finder = @import("file_finder.zig");
const FileList = @import("FileList.zig");

const module_name = @typeName(@This());
const finder_module_name = module_name ++ ".Finder";
const query_timeout_ms = 15_000;
const max_output_bytes = 8 * 1024 * 1024;

pub const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };
pub const ResolveError = error{ OutOfMemory, FileNotFound };

/// Resolve a configured executable once when the project manager starts.
pub fn resolve_executable(allocator: std.mem.Allocator, executable: []const u8) ResolveError![:0]const u8 {
    if (executable.len == 0) return error.FileNotFound;
    for (executable) |char| if (std.fs.path.isSep(char)) {
        if (!bin_path.can_execute(allocator, executable)) return error.FileNotFound;
        return allocator.dupeSentinel(u8, executable, 0);
    };
    return (try bin_path.find_binary_in_path(allocator, executable)) orelse error.FileNotFound;
}

/// Spawn an external finder for `project_directory`. The calling actor becomes
/// its owner. The executable is copied and can be released after this returns.
pub fn spawn(
    allocator: std.mem.Allocator,
    project_directory: []const u8,
    executable: [:0]const u8,
) SpawnError!tp.pid {
    return FinderProcess.create(allocator, project_directory, executable);
}

const FinderProcess = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    receiver: Receiver,
    logger: log.Logger,
    executable: [:0]const u8,
    project: []const u8,
    files: FileList,
    ready: bool = false,

    const Receiver = tp.Receiver(*FinderProcess);

    fn create(
        allocator: std.mem.Allocator,
        project_directory: []const u8,
        executable: [:0]const u8,
    ) SpawnError!tp.pid {
        const self = try allocator.create(FinderProcess);
        errdefer allocator.destroy(self);
        const project = try allocator.dupe(u8, project_directory);
        errdefer allocator.free(project);
        const executable_copy = try allocator.dupeSentinel(u8, executable, 0);
        errdefer allocator.free(executable_copy);
        self.* = .{
            .allocator = allocator,
            .parent = tp.self_pid().clone(),
            .receiver = .init(receive, dtor, self),
            .logger = log.logger(finder_module_name),
            .executable = executable_copy,
            .project = project,
            .files = .init(allocator, project),
        };
        return tp.spawn_link(allocator, self, start, finder_module_name);
    }

    fn dtor(self: *FinderProcess) void {
        self.files.deinit();
        self.allocator.free(self.project);
        self.allocator.free(self.executable);
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *FinderProcess) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *FinderProcess, from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            else => self.logger.err("receive", tp.exit_error(e, @errorReturnTrace())),
        };
    }

    fn receive_safe(self: *FinderProcess, from: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        var reply_to: tp.piid = undefined;
        var max: usize = 0;
        var n: usize = 0;
        var query: []const u8 = undefined;
        var path: []const u8 = undefined;
        var mtime: i128 = 0;

        if (try cbor.match(m.buf, .{ "update_mru", tp.extract(&path), tp.extract(&mtime) })) {
            self.files.update_mru(path, mtime) catch |e| self.logger.err("update_mru", e);
        } else if (try cbor.match(m.buf, .{ "request_recent_files", tp.extract(&reply_to), tp.extract(&max) })) {
            const to = tp.pid.from_id(reply_to) orelse return;
            defer to.deinit();
            self.files.send_recent(to.ref(), max);
        } else if (try cbor.match(m.buf, .{ "query_recent_files", tp.extract(&reply_to), tp.extract(&max), tp.extract(&query) })) {
            const to = tp.pid.from_id(reply_to) orelse return;
            defer to.deinit();
            if (query.len == 0) return self.files.send_recent(to.ref(), max);
            query_files(self.allocator, to.ref(), self.executable, self.project, max, query) catch |e| {
                self.logger.print_err(self.executable, "query \"{s}\" failed: {t}", .{ query, e });
                file_finder.send_recent_done(to.ref(), 0, query, 0);
            };
        } else if (try cbor.match(m.buf, .{ "request_n_most_recent_file", tp.extract(&reply_to), tp.extract(&n) })) {
            const to = tp.pid.from_id(reply_to) orelse return;
            defer to.deinit();
            to.send(.{self.files.nth_most_recent(n)}) catch {};
        } else if (try cbor.match(m.buf, .{"sync"})) {
            if (!self.ready) {
                self.ready = true;
                self.parent.send(.{ "FF", "ready", self.files.longest, self.files.count() }) catch {};
            }
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            if (from.instance_id() == self.parent.instance_id()) return error.ExitNormal;
            // Query workers are linked and report their normal exit here.
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }
};

/// Search for `query` and stream the matches to `to`. Once started, the query
/// always terminates with a "PRJ recent_done" message, including on failure.
fn query_files(
    allocator: std.mem.Allocator,
    to: tp.pid_ref,
    executable: [:0]const u8,
    project_directory: []const u8,
    max: usize,
    query: []const u8,
) SpawnError!void {
    return QueryProcess.create(allocator, to, executable, project_directory, max, query);
}

const Response = struct {
    root: []const u8 = "",
    results: []const Result = &.{},

    const Result = struct {
        path: []const u8 = "",
        matchIndexes: []const usize = &.{},
    };
};

const ResolvedResult = struct {
    path: []const u8,
    matches: []const usize,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.matches);
        allocator.free(self.path);
    }
};

const QueryProcess = struct {
    allocator: std.mem.Allocator,
    receiver: Receiver,
    to: tp.pid,
    executable: [:0]const u8,
    project: []const u8,
    query: []const u8,
    max: usize,
    sp: ?tp.subprocess = null,
    timer: ?tp.timeout = null,
    output: std.Io.Writer.Allocating,
    logger: log.Logger,
    longest: usize = 0,
    count: usize = 0,
    finished: bool = false,

    const Receiver = tp.Receiver(*QueryProcess);

    fn create(
        allocator: std.mem.Allocator,
        to: tp.pid_ref,
        executable: [:0]const u8,
        project_directory: []const u8,
        max: usize,
        query: []const u8,
    ) SpawnError!void {
        const self = try allocator.create(QueryProcess);
        errdefer allocator.destroy(self);
        const executable_copy = try allocator.dupeSentinel(u8, executable, 0);
        errdefer allocator.free(executable_copy);
        const project = try allocator.dupe(u8, project_directory);
        errdefer allocator.free(project);
        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);
        const to_copy = to.clone();
        errdefer to_copy.deinit();
        self.* = .{
            .allocator = allocator,
            .receiver = .init(receive, dtor, self),
            .to = to_copy,
            .executable = executable_copy,
            .project = project,
            .query = query_copy,
            .max = max,
            .output = .init(allocator),
            .logger = log.logger(module_name),
        };
        const pid = try tp.spawn_link(allocator, self, QueryProcess.start, module_name);
        pid.deinit();
    }

    fn dtor(self: *QueryProcess) void {
        if (self.timer) |*timer| {
            timer.cancel() catch {};
            timer.deinit();
        }
        if (self.sp) |*sp| sp.deinit();
        self.to.deinit();
        self.output.deinit();
        self.logger.deinit();
        self.allocator.free(self.query);
        self.allocator.free(self.project);
        self.allocator.free(self.executable);
        self.allocator.destroy(self);
    }

    fn start(self: *QueryProcess) tp.result {
        _ = tp.set_trap(true);
        var limit_buf: [32]u8 = undefined;
        const limit = std.fmt.bufPrint(&limit_buf, "{d}", .{self.max}) catch "100";

        // Encode the argument vector into our own buffer. tp.message.fmt uses a
        // thread-local buffer that a later message from this thread can clobber.
        var args: std.Io.Writer.Allocating = .init(self.allocator);
        defer args.deinit();
        cbor.writeValue(&args.writer, .{
            self.executable,
            "--json",
            "--limit",
            limit,
            "--client",
            "flow",
            "--",
            self.query,
        }) catch |e| {
            self.logger.print_err(self.executable, "failed to encode arguments: {t}", .{e});
            return self.finish(false);
        };

        const io = if (builtin.is_test) std.testing.io else root.get_io();
        self.sp = tp.subprocess.init(io, self.allocator, .{ .buf = args.written() }, module_name, .close) catch |e| {
            self.logger.print_err(self.executable, "failed to start: {t}", .{e});
            return self.finish(false);
        };
        self.timer = tp.timeout.init_ms(query_timeout_ms, tp.message.fmt(.{"timeout"})) catch |e| {
            self.logger.print_err(self.executable, "failed to start query timeout: {t}", .{e});
            return self.fail(error.QueryTimerFailed);
        };
        tp.receive(&self.receiver);
    }

    fn receive(self: *QueryProcess, _: tp.pid_ref, m: tp.message) tp.result {
        var bytes: []const u8 = "";
        if (try m.match(.{ module_name, "stdout", tp.extract(&bytes) })) {
            if (bytes.len > max_output_bytes -| self.output.written().len) {
                self.logger.print_err(self.executable, "output exceeded {d} bytes", .{max_output_bytes});
                return self.fail(error.OutputTooLarge);
            }
            self.output.writer.writeAll(bytes) catch |e| {
                self.logger.print_err(self.executable, "failed to buffer output: {t}", .{e});
                return self.fail(e);
            };
        } else if (try m.match(.{ module_name, "stderr", tp.extract(&bytes) })) {
            // The interface reserves stderr for progress and diagnostics. A
            // non-zero exit status is reported below without logging every
            // progress chunk.
        } else if (try m.match(.{ module_name, "term", tp.more })) {
            return self.finish(self.log_exit(m));
        } else if (try m.match(.{"timeout"})) {
            self.logger.print_err(self.executable, "query timed out after {d} ms", .{query_timeout_ms});
            return self.fail(error.QueryTimeout);
        } else if (try m.match(.{ "exit", tp.more })) {
            return self.fail(error.QueryCancelled);
        } else {
            self.logger.err("receive", tp.unexpected(m));
            return self.fail(error.UnexpectedMessage);
        }
    }

    fn log_exit(self: *QueryProcess, m: tp.message) bool {
        var err_msg: []const u8 = undefined;
        var exit_code: i64 = undefined;
        if (m.match(.{ tp.any, "term", "exited", 0 }) catch false) return true;
        if (m.match(.{ tp.any, "term", "error.FileNotFound", 1 }) catch false) {
            self.logger.print_err(self.executable, "executable not found", .{});
            return false;
        }
        if (m.match(.{ tp.any, "term", tp.extract(&err_msg), tp.extract(&exit_code) }) catch false)
            self.logger.print_err(self.executable, "terminated {s} exitcode: {d}", .{ err_msg, exit_code });
        return false;
    }

    fn complete(self: *QueryProcess, parse_output: bool) void {
        if (self.finished) return;
        self.finished = true;
        if (parse_output) self.send_results();
        self.to.send(.{ "PRJ", "recent_done", self.longest, self.query, self.count }) catch {};
    }

    fn finish(self: *QueryProcess, parse_output: bool) tp.result {
        self.complete(parse_output);
        return tp.exit_normal();
    }

    fn fail(self: *QueryProcess, _: anyerror) tp.result {
        self.complete(false);
        if (self.sp) |*sp| {
            sp.term() catch {};
            self.sp = null;
        }
        return tp.exit_normal();
    }

    fn send_results(self: *QueryProcess) void {
        const output = self.output.written();
        if (output.len == 0) return;

        const parsed = std.json.parseFromSlice(Response, self.allocator, output, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |e| {
            self.logger.print_err(self.executable, "failed to parse response: {t}", .{e});
            return;
        };
        defer parsed.deinit();

        const Entry = struct {
            path: []const u8,
            type: []const u8,
            icon: []const u8,
            color: u24,
            matches: []const usize,
        };
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |entry| {
                self.allocator.free(entry.path);
                self.allocator.free(entry.matches);
            }
            entries.deinit(self.allocator);
        }

        // Collect all entries so every result carries the final maximum width.
        for (parsed.value.results) |result| {
            if (entries.items.len >= self.max) break;
            if (result.path.len == 0) continue;
            const resolved = resolve_result(self.allocator, self.project, parsed.value.root, result) catch |e| {
                self.logger.print_err(self.executable, "failed to add '{s}': {t}", .{ result.path, e });
                continue;
            } orelse continue;
            const file_type, const icon, const color = guess_file_type(resolved.path);
            entries.append(self.allocator, .{
                .path = resolved.path,
                .type = file_type,
                .icon = icon,
                .color = color,
                .matches = resolved.matches,
            }) catch |e| {
                resolved.deinit(self.allocator);
                self.logger.print_err(self.executable, "failed to collect results: {t}", .{e});
                break;
            };
            self.longest = @max(self.longest, resolved.path.len);
        }

        for (entries.items) |entry| {
            self.to.send(.{
                "PRJ",
                "recent",
                self.longest,
                entry.path,
                entry.type,
                entry.icon,
                entry.color,
                entry.matches,
            }) catch |e| {
                self.logger.print_err(self.executable, "failed to send results: {t}", .{e});
                return;
            };
            self.count += 1;
        }
    }
};

fn resolve_result(
    allocator: std.mem.Allocator,
    project: []const u8,
    response_root: []const u8,
    result: Response.Result,
) error{OutOfMemory}!?ResolvedResult {
    const result_is_absolute = std.fs.path.isAbsolute(result.path);
    const result_root = if (response_root.len > 0) response_root else project;
    if (!result_is_absolute and result_root.len == 0) return null;

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_has_separator = result_root.len > 0 and std.fs.path.isSep(result_root[result_root.len - 1]);
    const abs = if (result_is_absolute)
        result.path
    else if (root_has_separator)
        std.fmt.bufPrint(&abs_buf, "{s}{s}", .{ result_root, result.path }) catch return null
    else
        std.fmt.bufPrint(&abs_buf, "{s}{c}{s}", .{ result_root, std.fs.path.sep, result.path }) catch return null;
    const path_offset = if (result_is_absolute) 0 else result_root.len + @intFromBool(!root_has_separator);

    const project_has_separator = project.len > 0 and std.fs.path.isSep(project[project.len - 1]);
    const display = if (project.len > 0 and std.mem.startsWith(u8, abs, project)) blk: {
        if (project_has_separator) break :blk abs[project.len..];
        if (abs.len > project.len and std.fs.path.isSep(abs[project.len]))
            break :blk abs[project.len + 1 ..];
        break :blk abs;
    } else abs;

    const display_offset = abs.len - display.len;
    var matches: std.ArrayList(usize) = .empty;
    errdefer matches.deinit(allocator);
    for (result.matchIndexes) |index| {
        if (index >= result.path.len) continue;
        const in_abs = path_offset + index;
        if (in_abs < display_offset) continue;
        (try matches.addOne(allocator)).* = in_abs - display_offset;
    }

    const path = try allocator.dupe(u8, display);
    errdefer allocator.free(path);
    return .{
        .path = path,
        .matches = try matches.toOwnedSlice(allocator),
    };
}

fn guess_file_type(file_path: []const u8) struct { []const u8, []const u8, u24 } {
    const default = file_type_config.default;
    // Test roots do not provide a configuration directory.
    if (builtin.is_test) return .{ default.name, default.icon, default.color };
    // Path-only detection: result files are not opened to inspect content.
    return if (file_type_config.guess_file_type(file_path, "")) |ft| .{
        ft.name,
        ft.icon orelse default.icon,
        ft.color orelse default.color,
    } else .{ default.name, default.icon, default.color };
}

test "external file finder translates paths and match indexes" {
    const allocator = std.testing.allocator;
    const resolved = (try resolve_result(allocator, "/repo/fbcode", "/repo", .{
        .path = "fbcode/src/a.zig",
        .matchIndexes = &.{ 0, 7, 11, std.math.maxInt(usize) },
    })).?;
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("src/a.zig", resolved.path);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, resolved.matches);
}

test "external file finder accepts an omitted root and absolute paths" {
    const allocator = std.testing.allocator;
    const relative = (try resolve_result(allocator, "/repo", "", .{
        .path = "src/a.zig",
        .matchIndexes = &.{0},
    })).?;
    defer relative.deinit(allocator);
    try std.testing.expectEqualStrings("src/a.zig", relative.path);
    try std.testing.expectEqualSlices(usize, &.{0}, relative.matches);

    const absolute_path = "/repo/src/a.zig";
    const absolute = (try resolve_result(allocator, "/repo/", "/ignored/", .{
        .path = absolute_path,
        .matchIndexes = &.{6},
    })).?;
    defer absolute.deinit(allocator);
    try std.testing.expectEqualStrings("src/a.zig", absolute.path);
    try std.testing.expectEqualSlices(usize, &.{0}, absolute.matches);
}

const test_allocator = std.heap.c_allocator;

const TestDriver = struct {
    receiver: tp.Receiver(*TestDriver),
    finder: tp.pid,
    timeout: tp.timeout,
    step: Step = .ready,

    const Step = enum { ready, recent, query };
    const Args = struct {
        project: []const u8,
        executable: [:0]const u8,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        const self = try test_allocator.create(TestDriver);
        self.* = .{
            .receiver = .init(receive_fn, dtor, self),
            .finder = undefined,
            .timeout = try tp.timeout.init_ms(10_000, tp.message.fmt(.{"timeout"})),
        };
        self.finder = try spawn(test_allocator, args.project, args.executable);
        try self.finder.send(.{ "update_mru", "recent.txt", @as(i128, 1000) });
        try self.finder.send(.{"sync"});
        tp.receive(&self.receiver);
    }

    fn dtor(self: *TestDriver) void {
        self.timeout.deinit();
        self.finder.deinit();
        test_allocator.destroy(self);
    }

    fn receive_fn(self: *TestDriver, _: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(m) catch |e| tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *TestDriver, m: tp.message) !void {
        const self_id = tp.self_pid().instance_id();
        var path: []const u8 = undefined;
        var longest: usize = 0;
        var count: usize = 0;
        if (try m.match(.{"timeout"})) return tp.exit_fmt("timed out at step {t}", .{self.step});
        if (try m.match(.{ "exit", tp.more })) return tp.exit_fmt("finder exited at step {t}: {f}", .{ self.step, m });
        switch (self.step) {
            .ready => if (try m.match(.{ "FF", "ready", tp.extract(&longest), tp.extract(&count) })) {
                try std.testing.expectEqual("recent.txt".len, longest);
                try std.testing.expectEqual(@as(usize, 1), count);
                self.step = .recent;
                try self.finder.send(.{ "request_recent_files", self_id, @as(usize, 10) });
            },
            .recent => if (try m.match(.{ "PRJ", "recent", tp.any, tp.extract(&path), tp.more })) {
                try std.testing.expectEqualStrings("recent.txt", path);
            } else if (try m.match(.{ "PRJ", "recent_done", tp.any, "", tp.extract(&count) })) {
                try std.testing.expectEqual(@as(usize, 1), count);
                self.step = .query;
                try self.finder.send(.{ "query_recent_files", self_id, @as(usize, 10), "main" });
            },
            .query => if (try m.match(.{ "PRJ", "recent", tp.extract(&longest), tp.extract(&path), tp.more })) {
                try std.testing.expectEqual("src/main.zig".len, longest);
                try std.testing.expectEqualStrings("src/main.zig", path);
            } else if (try m.match(.{ "PRJ", "recent_done", tp.any, "main", tp.extract(&count) })) {
                try std.testing.expectEqual(@as(usize, 1), count);
                try self.finder.send(.{"shutdown"});
                return tp.exit("success");
            },
        }
    }
};

test "external file finder actor runs configured executable and preserves recent files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\printf '%s\n' '{"results":[{"path":"src/main.zig","matchIndexes":[4,5]}]}'
    ;
    const file = try tmp.dir.createFile(io, "finder.sh", .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, script);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const executable = try std.fs.path.joinZ(std.testing.allocator, &.{ project, "finder.sh" });
    defer std.testing.allocator.free(executable);

    var ctx = try tp.context.init(std.testing.allocator, .{});
    defer ctx.deinit();
    var status: []const u8 = "not run";
    var exit_handler = tp.make_exit_handler(&status, struct {
        fn handle(result: *[]const u8, msg: []const u8) void {
            result.* = test_allocator.dupe(u8, msg) catch "OOM";
        }
    }.handle);
    _ = try ctx.spawn_link(TestDriver.Args{ .project = project, .executable = executable }, TestDriver.start, "external_finder_test", &exit_handler, null);
    ctx.run();
    if (!std.mem.eql(u8, status, "success")) {
        std.log.err("external finder test: {s}", .{status});
        return error.TestFailed;
    }
}
