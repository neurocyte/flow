//! The built-in file finder. Indexes the project, from its VCS when it has one
//! and with a gitignore aware walk of the project tree otherwise, keeps the
//! index current from file system events and matches file names against it.
//! See file_finder.zig for the message protocol.

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("soft_root").root;
const git = @import("git");
const file_watcher = @import("file_watcher");
const gitignore = @import("gitignore");

const file_finder = @import("file_finder.zig");
const FileList = @import("FileList.zig");
const walk_tree = @import("walk_tree.zig");

const module_name = @typeName(@This());

/// How a finder lists the files of a project in a repository. The functions
/// run on the finder's actor and reply to it the way git commands do:
///
///   {tag, context, "workspace_path", root: string or null}
///   {tag, context, "workspace_files", lines: string}       zero or more
///   {tag, context, "workspace_files", null, exit_code: i64}
///   {tag, context, "workspace_deleted_files", lines: string}       zero or more
///   {tag, context, "workspace_deleted_files", null, exit_code: i64}
///
/// The finder matches the replies by the lister's own `tag`, so that the two
/// cannot disagree on it.
pub const VcsLister = struct {
    tag: []const u8,
    workspace_path: *const fn (context: usize, cwd: []const u8) git.Error!void,
    workspace_files: *const fn (context: usize, cwd: []const u8) git.Error!void,
    workspace_deleted_files: *const fn (context: usize, cwd: []const u8) git.Error!void,
    needs_full_stat: *const fn (cwd: []const u8) bool,

    pub const git_lister: VcsLister = .{
        .tag = git.module_name,
        .workspace_path = git.workspace_path,
        .workspace_files = git.workspace_files,
        .workspace_deleted_files = git.workspace_deleted_files,
        .needs_full_stat = git.workspace_files_need_full_stat,
    };

    /// No VCS: the finder walks the project tree.
    pub const none: VcsLister = .{
        .tag = "",
        .workspace_path = not_found,
        .workspace_files = not_found,
        .workspace_deleted_files = not_found,
        .needs_full_stat = no_full_stat,
    };

    fn not_found(_: usize, _: []const u8) git.Error!void {
        return error.GitNotFound;
    }

    fn no_full_stat(_: []const u8) bool {
        return false;
    }
};

pub const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

pub const Options = struct {
    /// Do not walk the project tree (`non_indexed_projects`). A VCS listing
    /// is still used.
    no_index: bool = false,
    /// Watch the project tree even when it is not indexed.
    watch_non_indexed: bool = false,
    /// FileStore actor to read the modification times of files from.
    file_store: ?tp.pid_ref = null,
    /// Environment to read global ignore rules from. Borrowed for the
    /// finder's lifetime. The process environment if null.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Lists the files of a project in a repository. Test builds cannot
    /// compile git, which finds its binary through the process environment
    /// that they lack, so tests pass a lister of their own or get none.
    vcs: VcsLister = if (builtin.is_test) .none else .git_lister,
};

/// Spawn a finder for the project in `project_dir`. The calling actor
/// becomes its owner.
pub fn spawn(allocator: std.mem.Allocator, project_dir: []const u8, options: Options) SpawnError!tp.pid {
    return Process.create(allocator, project_dir, options);
}

const Process = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    receiver: Receiver,
    logger: log.Logger,
    root_path: []const u8,
    no_index: bool,
    watch_non_indexed: bool,
    file_store: ?tp.pid,
    environ_map: ?*const std.process.Environ.Map,
    vcs: VcsLister,
    files: FileList,
    /// Paths of the enumeration in progress, merged into `files` when done.
    pending: std.ArrayList([]const u8) = .empty,
    pending_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Deletes received while an enumeration runs. They filter entries that
    /// the enumeration reports after the watcher event.
    deleted_files: std.StringHashMapUnmanaged(void) = .empty,
    deleted_subtrees: std.ArrayList([]const u8) = .empty,
    enumeration: Enumeration = .idle,
    enumeration_failed: bool = false,
    /// A sync was asked for, or the tree changed, while an enumeration ran.
    /// The running one may have missed changes, so another runs after it.
    resync_requested: bool = false,
    ready: bool = false,
    /// The first successful enumeration asked for all modification times.
    all_mtimes_queued: bool = false,
    stat_generation: usize = 0,
    walker: ?tp.pid = null,
    watcher: ?file_watcher.Owned = null,
    watcher_ready: bool = false,
    watcher_restart_attempted: bool = false,
    ignore: ?*gitignore.Matcher = null,
    ignore_failed: bool = false,

    const Receiver = tp.Receiver(*Process);
    const Enumeration = enum { idle, workspace_path, workspace_files, workspace_deleted_files, walk_tree };
    const Source = enum { none, tracked, walked };

    fn create(allocator: std.mem.Allocator, project_dir: []const u8, options: Options) SpawnError!tp.pid {
        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        const root_path = try allocator.dupe(u8, project_dir);
        errdefer allocator.free(root_path);
        self.* = .{
            .allocator = allocator,
            .parent = tp.self_pid().clone(),
            .receiver = .init(receive, dtor, self),
            .logger = log.logger("file_finder"),
            .root_path = root_path,
            .no_index = options.no_index,
            .watch_non_indexed = options.watch_non_indexed,
            .file_store = if (options.file_store) |pid| pid.clone() else null,
            .environ_map = options.environ_map,
            .vcs = options.vcs,
            .files = .init(allocator, root_path),
        };
        return tp.spawn_link(allocator, self, Process.start, module_name);
    }

    fn dtor(self: *Process) void {
        if (self.watcher) |*watcher| watcher.deinit();
        if (self.walker) |pid| {
            pid.send(.{"stop"}) catch {};
            pid.deinit();
        }

        if (self.ignore) |m| gitignore.Sources.close(root.get_io(), self.allocator, m);

        self.pending_index.deinit(self.allocator);
        for (self.pending.items) |path| self.allocator.free(path);
        self.pending.deinit(self.allocator);

        var deleted = self.deleted_files.keyIterator();
        while (deleted.next()) |path| self.allocator.free(path.*);

        self.deleted_files.deinit(self.allocator);
        for (self.deleted_subtrees.items) |path| self.allocator.free(path);
        self.deleted_subtrees.deinit(self.allocator);

        self.files.deinit();
        if (self.file_store) |pid| pid.deinit();

        self.parent.deinit();
        self.logger.deinit();

        self.allocator.free(self.root_path);
        self.allocator.destroy(self);
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        // started here so that its events are sent to this actor
        self.watcher = self.start_watcher();
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            else => {
                const err = tp.exit_error(e, @errorReturnTrace());
                self.logger.err("receive", err);
            },
        };
    }

    fn receive_safe(self: *Process, from: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        var reply_to: tp.piid = undefined;
        var max: usize = 0;
        var n: usize = 0;
        var query: []const u8 = undefined;
        var path: []const u8 = undefined;
        var from_path: []const u8 = undefined;
        var output: []const u8 = undefined;
        var mtime: i128 = 0;
        var stat_generation: usize = 0;
        var mtime_high: i64 = 0;
        var mtime_low: i64 = 0;
        var event_type: file_watcher.EventType = undefined;
        var object_type: file_watcher.ObjectType = undefined;
        var exit_code: i64 = 0;
        var watcher_error: []const u8 = undefined;

        if (try cbor.match(m.buf, .{ "walk_tree_entry", tp.any, tp.extract(&path) })) {
            self.add_pending(path) catch |e| {
                self.enumeration_failed = true;
                self.logger.err("walk_tree_entry", e);
            };
        } else if (try cbor.match(m.buf, .{ "walk_tree_done", tp.any })) {
            self.walk_tree_done(true);
        } else if (try cbor.match(m.buf, .{ "FS", "stat", tp.extract(&stat_generation), tp.extract(&path), tp.extract(&mtime_high), tp.extract(&mtime_low) })) {
            self.handle_file_store_mtime(path, stat_generation, mtime_high, mtime_low);
        } else if (try cbor.match(m.buf, .{ "FS", "missing", tp.extract(&stat_generation), tp.extract(&path) })) {
            self.handle_file_store_missing(path, stat_generation);
        } else if (try cbor.match(m.buf, .{ "FS", "stat_error", tp.extract(&stat_generation), tp.extract(&path), tp.string })) {
            self.handle_file_store_stat_error(path, stat_generation);
        } else if (try cbor.match(m.buf, .{ self.vcs.tag, tp.any, "workspace_files", tp.extract(&output) })) {
            self.add_workspace_files(output) catch |e| {
                self.enumeration_failed = true;
                self.logger.err("workspace_files", e);
            };
        } else if (try cbor.match(m.buf, .{ self.vcs.tag, tp.any, "workspace_files", tp.null_, tp.extract(&exit_code) })) {
            if (exit_code == 0 and !self.enumeration_failed)
                self.start_workspace_deleted_files()
            else
                self.enumeration_done(.none, false);
        } else if (try cbor.match(m.buf, .{ self.vcs.tag, tp.any, "workspace_deleted_files", tp.extract(&output) })) {
            self.add_workspace_deleted_files(output) catch |e| {
                self.enumeration_failed = true;
                self.logger.err("workspace_deleted_files", e);
            };
        } else if (try cbor.match(m.buf, .{ self.vcs.tag, tp.any, "workspace_deleted_files", tp.null_, tp.extract(&exit_code) })) {
            self.enumeration_done(.tracked, exit_code == 0 and !self.enumeration_failed);
        } else if (try cbor.match(m.buf, .{ self.vcs.tag, tp.any, "workspace_path", tp.null_ })) {
            self.start_walker();
        } else if (try cbor.match(m.buf, .{ self.vcs.tag, tp.any, "workspace_path", tp.string })) {
            self.start_workspace_files();
        } else if (try cbor.match(m.buf, .{ "FW", "watching" })) {
            if (self.is_watcher(from)) self.watcher_ready = true;
        } else if (try cbor.match(m.buf, .{ "FW", "watch_error", tp.extract(&watcher_error) })) {
            if (self.is_watcher(from)) self.handle_watcher_error(watcher_error);
        } else if (try cbor.match(m.buf, .{ "FW", "change", tp.extract(&path), tp.extract(&event_type), tp.extract(&object_type) })) {
            self.handle_file_watch_event(path, event_type, object_type);
        } else if (try cbor.match(m.buf, .{ "FW", "rename", tp.extract(&from_path), tp.extract(&path), tp.extract(&object_type) })) {
            self.handle_file_watch_rename(from_path, path, object_type);
        } else if (try cbor.match(m.buf, .{ "update_mru", tp.extract(&path), tp.extract(&mtime) })) {
            self.files.update_mru(path, mtime) catch |e| self.logger.err("update_mru", e);
        } else if (try cbor.match(m.buf, .{ "query_recent_files", tp.extract(&reply_to), tp.extract(&max), tp.extract(&query) })) {
            self.query_recent_files(reply_to, max, query);
        } else if (try cbor.match(m.buf, .{ "request_recent_files", tp.extract(&reply_to), tp.extract(&max) })) {
            self.request_recent_files(reply_to, max);
        } else if (try cbor.match(m.buf, .{ "request_n_most_recent_file", tp.extract(&reply_to), tp.extract(&n) })) {
            self.request_n_most_recent_file(reply_to, n);
        } else if (try cbor.match(m.buf, .{"sync"})) {
            self.sync();
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            return self.handle_exit(from, m);
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn handle_exit(self: *Process, from: tp.pid_ref, m: tp.message) error{ExitNormal}!void {
        const piid = from.instance_id();
        if (self.parent.instance_id() == piid) return error.ExitNormal;
        const normal = m.match(.{ "exit", "normal" }) catch false;
        if (self.walker) |pid| if (pid.instance_id() == piid) {
            // An exit without the done message is a failed, partial walk.
            if (!normal) self.logger.print_err("walk_tree", "{s}: {f}", .{ self.root_path, m });
            return self.walk_tree_done(false);
        };
        if (self.watcher) |watcher| if (watcher.pid.instance_id() == piid) {
            if (!normal) self.logger.print_err("file_watcher", "exited: {f}", .{m});
            watcher.pid.deinit();
            self.watcher = null;
            self.watcher_failed();
            return;
        };
        // A VCS command sends its terminal reply before a normal exit. An
        // abnormal exit has no reply, so finish the enumeration here.
        if (!normal) {
            self.logger.print_err("vcs", "{s}: {f}", .{ self.root_path, m });
            switch (self.enumeration) {
                .workspace_path => self.start_walker(),
                .workspace_files, .workspace_deleted_files => self.enumeration_done(.none, false),
                else => {},
            }
        }
    }

    fn request_recent_files(self: *Process, reply_to: tp.piid, max: usize) void {
        const to = tp.pid.from_id(reply_to) orelse return;
        defer to.deinit();
        self.files.send_recent(to.ref(), max);
    }

    fn query_recent_files(self: *Process, reply_to: tp.piid, max: usize, query: []const u8) void {
        const to = tp.pid.from_id(reply_to) orelse return;
        defer to.deinit();
        const start_time = root.get_now().toMilliseconds();
        const matched = self.files.send_query(to.ref(), max, query) catch |e|
            return self.logger.err("query_recent_files", e);
        const query_time = root.get_now().toMilliseconds() - start_time;
        if (query_time > 250)
            self.logger.print("query \"{s}\" matched {d}/{d} in {d} ms", .{ query, matched, self.files.count(), query_time });
    }

    fn request_n_most_recent_file(self: *Process, reply_to: tp.piid, n: usize) void {
        const to = tp.pid.from_id(reply_to) orelse return;
        defer to.deinit();
        to.send(.{self.files.nth_most_recent(n)}) catch {};
    }

    fn sync(self: *Process) void {
        if (self.enumeration != .idle) {
            self.resync_requested = true;
            return;
        }
        self.enumeration = .workspace_path;
        self.enumeration_failed = false;
        self.vcs.workspace_path(@intFromPtr(self), self.root_path) catch self.start_walker();
    }

    fn start_workspace_files(self: *Process) void {
        self.enumeration = .workspace_files;
        self.vcs.workspace_files(@intFromPtr(self), self.root_path) catch self.enumeration_done(.none, false);
    }

    fn add_workspace_files(self: *Process, output: []const u8) error{OutOfMemory}!void {
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try self.add_pending_owned(convert_path(try self.allocator.dupe(u8, line)));
        }
    }

    fn start_workspace_deleted_files(self: *Process) void {
        self.enumeration = .workspace_deleted_files;
        self.vcs.workspace_deleted_files(@intFromPtr(self), self.root_path) catch self.enumeration_done(.none, false);
    }

    fn add_workspace_deleted_files(self: *Process, output: []const u8) error{OutOfMemory}!void {
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const owned = try self.allocator.dupe(u8, line);
            defer self.allocator.free(owned);
            const path = convert_path(owned);
            const removed = self.files.remove(path);
            self.remember_deletion(path, false);
            if (removed) self.notify_deleted(path);
        }
    }

    fn start_walker(self: *Process) void {
        if (self.no_index) {
            self.logger.print("not indexing {s}", .{self.root_path});
            return self.enumeration_done(.none, false);
        }
        self.enumeration = .walk_tree;
        const io = root.get_io();

        var sources: gitignore.Sources = .init(self.allocator);
        defer sources.deinit();
        sources.collect(io, self.environ(), self.root_path);

        self.walker = walk_tree.start(self.allocator, self.root_path, walk_tree_entry_callback, walk_tree_done_callback, .{
            .follow_directory_symlinks = tp.env.get().is("follow_directory_symlinks"),
            .maximum_symlink_depth = @intCast(tp.env.get().num("maximum_symlink_depth")),
            .log_ignored_links = tp.env.get().is("log_ignored_links"),
            .use_gitignore = !tp.env.get().is("disable_gitignore"),
            .extra_sources = sources.list.items,
            .use_builtin_fallback = sources.use_builtin,
        }) catch |e| {
            self.logger.err("walk_tree", e);
            return self.enumeration_done(.none, false);
        };
    }

    fn walk_tree_entry_callback(parent: tp.pid_ref, root_path: []const u8, file_path: []const u8) error{Exit}!void {
        try parent.send(.{ "walk_tree_entry", root_path, file_path });
    }

    fn walk_tree_done_callback(parent: tp.pid_ref, root_path: []const u8) error{Exit}!void {
        try parent.send(.{ "walk_tree_done", root_path });
    }

    fn add_pending(self: *Process, path: []const u8) error{OutOfMemory}!void {
        return self.add_pending_owned(try self.allocator.dupe(u8, path));
    }

    /// Takes ownership of `path`.
    fn add_pending_owned(self: *Process, path: []u8) error{OutOfMemory}!void {
        errdefer self.allocator.free(path);
        if (self.was_deleted(path)) {
            self.allocator.free(path);
            return;
        }
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_index.ensureUnusedCapacity(self.allocator, 1);
        const entry = self.pending_index.getOrPutAssumeCapacity(path);
        if (entry.found_existing) {
            self.allocator.free(path);
            return;
        }
        entry.value_ptr.* = @intCast(self.pending.items.len);
        self.pending.appendAssumeCapacity(path);
    }

    fn is_pending(self: *const Process, path: []const u8) bool {
        return self.pending_index.contains(path);
    }

    fn was_deleted(self: *const Process, path: []const u8) bool {
        if (self.deleted_files.contains(path)) return true;
        for (self.deleted_subtrees.items) |subtree|
            if (FileList.is_in_subtree(path, subtree)) return true;
        return false;
    }

    fn remember_deletion(self: *Process, path: []const u8, subtree: bool) void {
        if (self.enumeration == .idle) return;
        if (!subtree and self.was_deleted(path)) return;
        if (subtree) {
            var i: usize = 0;
            while (i < self.deleted_subtrees.items.len) {
                const existing = self.deleted_subtrees.items[i];
                if (std.mem.eql(u8, path, existing) or FileList.is_in_subtree(path, existing)) return;
                if (FileList.is_in_subtree(existing, path)) {
                    self.allocator.free(self.deleted_subtrees.swapRemove(i));
                } else {
                    i += 1;
                }
            }
        }
        const owned = self.allocator.dupe(u8, path) catch {
            self.enumeration_failed = true;
            return;
        };
        if (subtree) {
            self.deleted_subtrees.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                self.enumeration_failed = true;
            };
        } else {
            self.deleted_files.put(self.allocator, owned, {}) catch {
                self.allocator.free(owned);
                self.enumeration_failed = true;
            };
        }
    }

    fn filter_deleted(self: *Process) void {
        if (self.deleted_files.count() == 0 and self.deleted_subtrees.items.len == 0) return;
        var kept: usize = 0;
        for (self.pending.items) |path| {
            if (self.was_deleted(path)) {
                _ = self.pending_index.remove(path);
                self.allocator.free(path);
            } else {
                self.pending.items[kept] = path;
                self.pending_index.getPtr(path).?.* = @intCast(kept);
                kept += 1;
            }
        }
        self.pending.shrinkRetainingCapacity(kept);
    }

    fn clear_deletions(self: *Process) void {
        var deleted = self.deleted_files.keyIterator();
        while (deleted.next()) |path| self.allocator.free(path.*);
        self.deleted_files.clearAndFree(self.allocator);
        for (self.deleted_subtrees.items) |path| self.allocator.free(path);
        self.deleted_subtrees.clearAndFree(self.allocator);
    }

    fn walk_tree_done(self: *Process, success: bool) void {
        if (self.walker) |pid| pid.deinit();
        self.walker = null;
        self.enumeration_done(.walked, success and !self.enumeration_failed);
    }

    fn enumeration_done(self: *Process, source: Source, success: bool) void {
        self.enumeration = .idle;
        self.filter_deleted();
        const first = !self.ready;
        if (first and success)
            self.logger.print("project files: {d} restored, {d} {t}", .{ self.files.count(), self.pending.items.len, source });

        // An empty successful enumeration is authoritative. A failed partial
        // enumeration is discarded so it cannot truncate the existing list.
        if (success) merged: {
            self.files.merge(&self.pending, &self.pending_index, if (first) .keep_all else .keep_used) catch |e| {
                self.logger.err("merge", e);
                break :merged;
            };
            const full_stat = !self.all_mtimes_queued or !self.watcher_ready or
                (source == .tracked and self.vcs.needs_full_stat(self.root_path));
            if (self.queue_mtimes(if (full_stat) .all else .unknown_or_retained))
                self.all_mtimes_queued = true;
        }
        // the next listing is a while away, so free its room until then
        self.pending_index.clearAndFree(self.allocator);
        for (self.pending.items) |path| self.allocator.free(path);
        self.pending.clearAndFree(self.allocator);
        self.clear_deletions();

        self.enumeration_failed = false;
        if (first) {
            self.ready = true;
            self.parent.send(.{ "FF", "ready", self.files.longest, self.files.count() }) catch {};
        }
        if (self.resync_requested) {
            self.resync_requested = false;
            self.sync();
        }
    }

    /// Ask the file store for modification times. With a live watcher, later
    /// listings only need new and retained files; without one, validate all.
    fn queue_mtimes(self: *Process, scope: enum { all, unknown_or_retained }) bool {
        const file_store = self.file_store orelse return false;
        self.stat_generation +%= 1;
        if (self.stat_generation == 0) self.stat_generation = 1;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var complete = true;
        for (self.files.files.items) |*file| {
            if (scope == .unknown_or_retained and file.mtime_known and !file.needs_stat) continue;
            buf.clearRetainingCapacity();
            if (!std.fs.path.isAbsolute(file.path)) {
                buf.appendSlice(self.allocator, self.root_path) catch return false;
                buf.append(self.allocator, std.fs.path.sep) catch return false;
            }
            buf.appendSlice(self.allocator, file.path) catch return false;
            file.stat_generation = self.stat_generation;
            file_store.send(.{ "stat", self.stat_generation, buf.items }) catch {
                file.stat_generation = 0;
                complete = false;
                continue;
            };
            file.needs_stat = false;
        }
        return complete;
    }

    fn handle_file_store_mtime(self: *Process, abs_path: []const u8, stat_generation: usize, mtime_high: i64, mtime_low: i64) void {
        const path = self.stat_path(abs_path) orelse return;
        const mtime = (@as(i128, @intCast(mtime_high)) << 64) | @as(i128, @intCast(mtime_low));
        self.files.stat_succeeded(path, stat_generation, mtime);
    }

    fn handle_file_store_missing(self: *Process, abs_path: []const u8, stat_generation: usize) void {
        const path = self.stat_path(abs_path) orelse return;
        if (self.files.stat_failed(path, stat_generation)) self.notify_deleted(path);
    }

    fn handle_file_store_stat_error(self: *Process, abs_path: []const u8, stat_generation: usize) void {
        const path = self.stat_path(abs_path) orelse return;
        self.files.stat_errored(path, stat_generation);
    }

    fn stat_path(self: *const Process, abs_path: []const u8) ?[]const u8 {
        if (self.project_path(abs_path)) |relative|
            if (self.files.contains(relative)) return relative;
        return if (self.files.contains(abs_path)) abs_path else null;
    }

    /// `abs_path` relative to the project, or null if it is outside of it.
    fn project_path(self: *const Process, abs_path: []const u8) ?[]const u8 {
        const dir = self.root_path;
        if (!std.mem.startsWith(u8, abs_path, dir)) return null;
        if (abs_path.len <= dir.len or abs_path[dir.len] != std.fs.path.sep) return null;
        return abs_path[dir.len + 1 ..];
    }

    fn is_watcher(self: *const Process, from: tp.pid_ref) bool {
        return if (self.watcher) |watcher| watcher.pid.instance_id() == from.instance_id() else false;
    }

    fn handle_watcher_error(self: *Process, err: []const u8) void {
        self.logger.print_err("file_watcher", "failed: {s}", .{err});
        if (self.watcher) |*watcher| watcher.deinit();
        self.watcher = null;
        self.watcher_failed();
    }

    fn watcher_failed(self: *Process) void {
        self.watcher_ready = false;
        self.all_mtimes_queued = false;
        if (!self.watcher_restart_attempted) {
            self.watcher_restart_attempted = true;
            self.watcher = self.start_watcher();
        }
        self.sync();
    }

    fn start_watcher(self: *Process) ?file_watcher.Owned {
        if (!tp.env.get().is("enable_file_watcher")) return null;
        if (self.no_index and !self.watch_non_indexed) {
            std.log.debug("not watching {s}", .{self.root_path});
            return null;
        }
        var watcher = file_watcher.Owned.init(.project_tree) catch |e| {
            std.log.err("file_watcher.init: {s} -> {}", .{ self.root_path, e });
            return null;
        };
        watcher.watch(self.root_path) catch |e| {
            std.log.err("file_watcher.watch: {s} -> {}", .{ self.root_path, e });
            watcher.deinit();
            return null;
        };
        return watcher;
    }

    /// A file or directory was added, removed or renamed. A running listing
    /// may have missed it, so list again when that one is done.
    fn structure_changed(self: *Process) void {
        if (self.enumeration != .idle) self.resync_requested = true;
    }

    /// Ignore deletion events for paths that were never indexed. Watchers can
    /// report ignored files in watched directories, such as editor swap files.
    fn file_deleted(self: *Process, path: []const u8) void {
        const known = self.files.remove(path) or self.is_pending(path);
        if (!known and (self.enumeration == .idle or self.is_ignored_unlisted(path, .file))) return;
        self.remember_deletion(path, false);
        self.structure_changed();
        self.notify_deleted(path);
    }

    fn subtree_deleted(self: *Process, path: []const u8) void {
        const known = self.files.remove_subtree(path) != 0;
        if (!known and (self.enumeration == .idle or gitignore.in_vcs_metadata_dir(path))) return;
        self.remember_deletion(path, true);
        self.structure_changed();
        self.notify_deleted(path);
    }

    fn handle_file_watch_rename(self: *Process, abs_from: []const u8, abs_to: []const u8, object_type: file_watcher.ObjectType) void {
        const src = self.project_path(abs_from);
        const dst = self.project_path(abs_to);
        const changed_at = now();

        if (object_type == .dir) {
            if (src) |s| self.ignore_subtree_removed(s);
            if (dst) |d| self.ignore_subtree_removed(d);
            const s = src orelse return;
            if (dst) |d| {
                _ = self.files.rename_subtree(s, d) catch |e|
                    return self.logger.err("file_watcher.subtree_renamed", e);
                self.structure_changed();
                self.notify_renamed(s, d);
            } else {
                self.subtree_deleted(s); // moved out of the project
            }
            return;
        }

        // before any ignore test: an ignore file may itself be ignored
        if (src) |s| if (self.is_ignore_file(s)) self.ignore_changed(s);
        if (dst) |d| if (self.is_ignore_file(d)) self.ignore_changed(d);

        const s = src orelse {
            // moved into the project
            if (dst) |d| if (!self.is_ignored(d, .file)) {
                self.structure_changed();
                self.files.add(d, changed_at) catch |e| self.logger.err("file_watcher.file_added", e);
            };
            return;
        };
        const d = dst orelse {
            self.file_deleted(s); // moved out of the project
            return;
        };
        // a file moved to an ignored path leaves the index, unless it is used
        if (self.is_ignored(d, .file) and !self.files.is_used(s)) {
            self.file_deleted(s);
            return;
        }
        _ = self.files.rename(s, d, changed_at) catch |e|
            return self.logger.err("file_watcher.file_renamed", e);
        self.structure_changed();
        self.notify_renamed(s, d);
    }

    fn handle_file_watch_event(self: *Process, abs_path: []const u8, event_type: file_watcher.EventType, object_type: file_watcher.ObjectType) void {
        const path = self.project_path(abs_path) orelse return;
        const changed_at = now();

        if (object_type == .dir) {
            if (event_type == .deleted) {
                self.ignore_subtree_removed(path);
                self.subtree_deleted(path);
            }
            return;
        }

        // an ignore file still invalidates the ruleset even when it is itself
        // excluded, as .git/info/exclude always is
        if (self.is_ignore_file(path)) self.ignore_changed(path);
        if (event_type == .created and self.is_ignored(path, .file)) return;

        switch (event_type) {
            .created => {
                self.structure_changed();
                self.files.add(path, changed_at) catch |e| self.logger.err("file_watcher.file_added", e);
            },
            .modified => self.files.modified(path, changed_at),
            .deleted => self.file_deleted(path),
            .closed => {}, // filtered by the file_watcher actor
        }
    }

    fn notify_renamed(self: *Process, from_path: []const u8, to_path: []const u8) void {
        self.parent.send(.{ "FF", "renamed", from_path, to_path }) catch {};
    }

    fn notify_deleted(self: *Process, path: []const u8) void {
        self.parent.send(.{ "FF", "deleted", path }) catch {};
    }

    fn environ(self: *const Process) *const std.process.Environ.Map {
        return self.environ_map orelse root.get_init().environ_map;
    }

    fn get_ignore(self: *Process) ?*gitignore.Matcher {
        if (self.ignore) |m| return m;
        if (self.ignore_failed) return null;
        const m = gitignore.Sources.open(
            root.get_io(),
            self.allocator,
            self.environ(),
            self.root_path,
            .{},
        ) catch {
            // one failure is enough; do not retry on every event
            self.ignore_failed = true;
            return null;
        };
        self.ignore = m;
        return m;
    }

    /// Test before `is_ignored`: an ignore file may itself be ignored, and its
    /// change events are still needed.
    fn is_ignore_file(self: *Process, path: []const u8) bool {
        const m = self.get_ignore() orelse return false;
        return m.is_ignore_file(path);
    }

    /// Whether a new path should be dropped rather than indexed. An already
    /// indexed path is never ignored.
    fn is_ignored(self: *Process, path: []const u8, dtype: gitignore.DType) bool {
        if (self.files.contains(path) or self.is_pending(path)) return false;
        return self.is_ignored_unlisted(path, dtype);
    }

    fn is_ignored_unlisted(self: *Process, path: []const u8, dtype: gitignore.DType) bool {
        if (gitignore.in_vcs_metadata_dir(path)) return true;
        const m = self.get_ignore() orelse return false;
        return m.is_ignored(root.get_io(), path, dtype) catch false;
    }

    fn ignore_changed(self: *Process, path: []const u8) void {
        const dir = std.fs.path.dirname(path) orelse "";
        if (self.ignore) |m| m.invalidate_dir(dir);
        if (self.watcher) |watcher| watcher.ignore_changed(self.root_path, dir) catch {};
    }

    fn ignore_subtree_removed(self: *Process, path: []const u8) void {
        const m = self.ignore orelse return;
        m.invalidate_subtree(path);
    }
};

fn now() i128 {
    return @as(i128, std.Io.Clock.real.now(root.get_io()).toNanoseconds());
}

fn convert_path(file_path_: []u8) []u8 {
    var file_path = file_path_;
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    return file_path;
}

const test_allocator = std.heap.c_allocator;

test "builtin finder accepts a current per-file stat from an earlier batch" {
    var process: Process = undefined;
    process.root_path = ".";
    process.files = .init(std.testing.allocator, process.root_path);
    defer process.files.deinit();
    try process.files.add("a", 1);
    process.files.files.items[0].stat_generation = 1;
    process.stat_generation = 2;

    process.handle_file_store_mtime("a", 1, 0, 10);
    try std.testing.expectEqual(@as(i128, 10), process.files.files.items[0].mtime);
    try std.testing.expectEqual(@as(usize, 0), process.files.files.items[0].stat_generation);
}

/// The actor that drives a finder through a test. `Steps` is the state of
/// the test, with `start(driver)`, which spawns the finder, and
/// `receive(steps, driver, from, message)`, which checks what arrives and
/// exits with "success" once the test is done.
fn Driver(comptime Steps: type) type {
    return struct {
        receiver: tp.Receiver(*Self),
        dir: []const u8,
        finder: tp.pid = undefined,
        environ_map: std.process.Environ.Map,
        arena: std.heap.ArenaAllocator,
        timeout: tp.timeout,
        steps: Steps = .{},

        const Self = @This();
        const Args = struct { dir: []const u8 };

        fn start(args: Args) tp.result {
            return init(args) catch |e| tp.exit_error(e, @errorReturnTrace());
        }

        fn init(args: Args) !void {
            _ = tp.set_trap(true);
            const self = try test_allocator.create(Self);
            self.* = .{
                .receiver = .init(receive_fn, dtor, self),
                .dir = args.dir,
                .environ_map = .init(test_allocator),
                .arena = .init(test_allocator),
                .timeout = try tp.timeout.init_ms(10_000, tp.message.fmt(.{"timeout"})),
            };
            try Steps.start(self);
            tp.receive(&self.receiver);
        }

        fn dtor(self: *Self) void {
            self.timeout.deinit();
            self.finder.deinit();
            self.arena.deinit();
            self.environ_map.deinit();
            test_allocator.destroy(self);
        }

        fn spawn_finder(self: *Self, options: Options) !void {
            var with_environ = options;
            with_environ.environ_map = &self.environ_map;
            self.finder = try spawn(test_allocator, self.dir, with_environ);
        }

        fn abs(self: *Self, rel_path: []const u8) ![]const u8 {
            return std.fs.path.join(self.arena.allocator(), &.{ self.dir, rel_path });
        }

        fn request_recent_files(self: *Self) !void {
            try self.finder.send(.{ "request_recent_files", tp.self_pid().instance_id(), @as(usize, 10) });
        }

        fn receive_fn(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
            return self.receive(from, m) catch |e| tp.exit_error(e, @errorReturnTrace());
        }

        fn receive(self: *Self, from: tp.pid_ref, m: tp.message) !void {
            const step = if (@hasField(Steps, "step")) @tagName(self.steps.step) else "-";
            if (try m.match(.{"timeout"})) return tp.exit_fmt("timed out at step {s}", .{step});
            if (try m.match(.{ "exit", tp.more })) return tp.exit_fmt("finder exited at step {s}: {f}", .{ step, m });
            return self.steps.receive(self, from, m);
        }
    };
}

/// Run a driver of `Steps` for a finder of `dir` until it exits, and fail
/// unless it succeeded.
fn run_test_driver(comptime Steps: type, dir: []const u8) !void {
    const D = Driver(Steps);
    var ctx = try tp.context.init(std.testing.allocator, .{});
    defer ctx.deinit();
    var status: []const u8 = "not run";
    var exit_handler = tp.make_exit_handler(&status, struct {
        fn handle(result: *[]const u8, msg: []const u8) void {
            result.* = test_allocator.dupe(u8, msg) catch "OOM";
        }
    }.handle);
    _ = try ctx.spawn_link(D.Args{ .dir = dir }, D.start, @typeName(Steps), &exit_handler, null);
    ctx.run();
    if (!std.mem.eql(u8, status, "success")) {
        std.log.err("{s}: {s}", .{ @typeName(Steps), status });
        return error.TestFailed;
    }
}

/// A directory for a test, with `files` in it. Returns its real path in `buf`.
fn fixture(tmp: *std.testing.TmpDir, files: []const []const u8, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const io = std.testing.io;
    for (files) |name| {
        if (std.fs.path.dirname(name)) |dir| try tmp.dir.createDirPath(io, dir);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "fixture\n" });
    }
    return buf[0..try tmp.dir.realPath(io, buf)];
}

test "recursive submodule listings require full stat validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try fixture(&tmp, &.{}, &buf);
    try std.testing.expect(!git.workspace_files_need_full_stat(dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".gitmodules", .data = "" });
    try std.testing.expect(git.workspace_files_need_full_stat(dir));
}

/// Indexes a tree, answers a request and a query, and reports the renames and
/// deletes that the test sends as file system events. Tests have no VCS, so
/// the finder walks the tree, and no watcher, so the events are sent.
const IndexSteps = struct {
    step: enum { ready, recent, query, renamed, deleted_dir, deleted_file, most_recent } = .ready,
    results: usize = 0,

    fn start(d: anytype) !void {
        try d.spawn_finder(.{});
        try d.finder.send(.{ "update_mru", "notes.txt", @as(i128, 1000) });
        // A new buffer is a valid recent file before its first save.
        try d.finder.send(.{ "update_mru", "draft.txt", @as(i128, 900) });
        try d.finder.send(.{"sync"});
    }

    fn receive(self: *IndexSteps, d: anytype, _: tp.pid_ref, m: tp.message) !void {
        var path: []const u8 = undefined;
        var to_path: []const u8 = undefined;
        var longest: usize = 0;
        var count: usize = 0;
        switch (self.step) {
            .ready => if (try m.match(.{ "FF", "ready", tp.extract(&longest), tp.extract(&count) })) {
                try std.testing.expectEqual(@as(usize, 5), count);
                try std.testing.expectEqual("docs/readme.md".len, longest);
                self.step = .recent;
                try d.request_recent_files();
            },
            .recent => if (try m.match(.{ "PRJ", "recent", tp.any, tp.extract(&path), tp.more })) {
                // the used file comes first
                if (self.results == 0) try std.testing.expectEqualStrings("notes.txt", path);
                self.results += 1;
            } else if (try m.match(.{ "PRJ", "recent_done", tp.any, "", tp.extract(&count) })) {
                try std.testing.expectEqual(@as(usize, 5), self.results);
                try std.testing.expectEqual(@as(usize, 5), count);
                self.step = .query;
                self.results = 0;
                try d.finder.send(.{ "query_recent_files", tp.self_pid().instance_id(), @as(usize, 10), "util" });
            },
            .query => if (try m.match(.{ "PRJ", "recent", tp.any, tp.extract(&path), tp.any, tp.any, tp.any, tp.any })) {
                try std.testing.expectEqualStrings("src/util.zig", path);
                self.results += 1;
            } else if (try m.match(.{ "PRJ", "recent_done", tp.any, "util", tp.any })) {
                try std.testing.expectEqual(@as(usize, 1), self.results);
                self.step = .renamed;
                const from_abs = try d.abs("notes.txt");
                const to_abs = try d.abs("moved.txt");
                try std.Io.Dir.renameAbsolute(from_abs, to_abs, root.get_io());
                try d.finder.send(.{ "FW", "rename", from_abs, to_abs, file_watcher.ObjectType.file });
            },
            .renamed => if (try m.match(.{ "FF", "renamed", tp.extract(&path), tp.extract(&to_path) })) {
                try std.testing.expectEqualStrings("notes.txt", path);
                try std.testing.expectEqualStrings("moved.txt", to_path);
                self.step = .deleted_dir;
                try d.finder.send(.{ "FW", "change", try d.abs("docs"), file_watcher.EventType.deleted, file_watcher.ObjectType.dir });
            },
            .deleted_dir => if (try m.match(.{ "FF", "deleted", tp.extract(&path) })) {
                try std.testing.expectEqualStrings("docs", path);
                self.step = .deleted_file;
                try d.finder.send(.{ "FW", "change", try d.abs("src/main.zig"), file_watcher.EventType.deleted, file_watcher.ObjectType.file });
            },
            .deleted_file => if (try m.match(.{ "FF", "deleted", tp.extract(&path) })) {
                try std.testing.expectEqualStrings("src/main.zig", path);
                self.step = .most_recent;
                try d.finder.send(.{ "request_n_most_recent_file", tp.self_pid().instance_id(), @as(usize, 0) });
            },
            .most_recent => if (try m.match(.{tp.extract(&path)})) {
                // the rename was the latest change
                try std.testing.expectEqualStrings("moved.txt", path);
                return tp.exit("success");
            },
        }
    }
};

test "builtin finder indexes a tree, answers queries and reports outside renames and deletes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(IndexSteps, try fixture(&tmp, &.{ "notes.txt", "src/main.zig", "src/util.zig", "docs/readme.md" }, &buf));
}

/// While a listing runs, asks for a sync or reports a change of the tree.
/// Either makes the finder list again when that listing is done: it lists a
/// path that the tree does not have, which only a second one drops.
fn RelistSteps(comptime cause: enum { sync, creation, file_deletion, directory_deletion, early_file_deletion, early_directory_deletion }) type {
    return struct {
        fn start(d: anytype) !void {
            try d.spawn_finder(.{});
            // queued before the walk of the first sync can report, so the
            // rest arrives while that listing runs
            try d.finder.send(.{"sync"});
            const directory = cause == .directory_deletion or cause == .early_directory_deletion;
            const listed_path = if (directory) "dir/only-in-first.txt" else "only-in-first.txt";
            switch (cause) {
                .sync => try d.finder.send(.{"sync"}),
                .creation => try d.finder.send(.{ "FW", "change", try d.abs(listed_path), file_watcher.EventType.created, file_watcher.ObjectType.file }),
                .file_deletion, .directory_deletion => try d.finder.send(.{ "walk_tree_entry", d.dir, listed_path }),
                .early_file_deletion => try d.finder.send(.{ "FW", "change", try d.abs(listed_path), file_watcher.EventType.deleted, file_watcher.ObjectType.file }),
                .early_directory_deletion => try d.finder.send(.{ "FW", "change", try d.abs("dir"), file_watcher.EventType.deleted, file_watcher.ObjectType.dir }),
            }
            switch (cause) {
                .file_deletion => try d.finder.send(.{ "FW", "change", try d.abs(listed_path), file_watcher.EventType.deleted, file_watcher.ObjectType.file }),
                .directory_deletion => try d.finder.send(.{ "FW", "change", try d.abs("dir"), file_watcher.EventType.deleted, file_watcher.ObjectType.dir }),
                else => try d.finder.send(.{ "walk_tree_entry", d.dir, listed_path }),
            }
        }

        fn receive(_: *@This(), d: anytype, _: tp.pid_ref, m: tp.message) !void {
            var count: usize = 0;
            if (try m.match(.{ "FF", "ready", tp.any, tp.extract(&count) })) {
                const listed = cause == .sync or cause == .creation;
                try std.testing.expectEqual(@as(usize, @intFromBool(listed)), count);
                return d.request_recent_files();
            }
            if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.any, tp.extract(&count) })) {
                // the second listing walked the empty tree and dropped the path
                if (count == 0) return tp.exit("success");
                return d.request_recent_files();
            }
        }
    };
}

test "builtin finder lists again for a sync asked for during a listing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(RelistSteps(.sync), try fixture(&tmp, &.{}, &buf));
}

test "builtin finder lists again for a change of the tree during a listing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(RelistSteps(.creation), try fixture(&tmp, &.{}, &buf));
}

test "builtin finder drops a pending file when it is deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(RelistSteps(.file_deletion), try fixture(&tmp, &.{}, &buf));
}

test "builtin finder drops a pending directory when it is deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(RelistSteps(.directory_deletion), try fixture(&tmp, &.{}, &buf));
}

test "builtin finder rejects files reported after their deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(RelistSteps(.early_file_deletion), try fixture(&tmp, &.{}, &buf));
    try run_test_driver(RelistSteps(.early_directory_deletion), try fixture(&tmp, &.{}, &buf));
}

/// Plays the file store of a finder and checks that a refresh validates all
/// files when no watcher can report modifications.
const MtimeSteps = struct {
    resynced: bool = false,
    requests: usize = 0,
    deleted: bool = false,

    fn start(d: anytype) !void {
        try d.spawn_finder(.{ .file_store = tp.self_pid() });
        try d.finder.send(.{"sync"});
    }

    fn receive(self: *MtimeSteps, d: anytype, _: tp.pid_ref, m: tp.message) !void {
        var path: []const u8 = undefined;
        var stat_generation: usize = 0;
        var count: usize = 0;
        if (try m.match(.{ "stat", tp.extract(&stat_generation), tp.extract(&path) })) {
            self.requests += 1;
            // answered before anything that is sent later, like the re-sync
            const basename = std.fs.path.basename(path);
            const missing = !self.resynced and std.mem.eql(u8, basename, "b.txt");
            if (missing)
                try d.finder.send(.{ "FS", "missing", stat_generation, path })
            else
                try d.finder.send(.{ "FS", "stat", stat_generation, path, @as(i64, 0), @as(i64, 1000) });
            if (!self.resynced) return;
            try std.testing.expect(std.mem.eql(u8, basename, "a.txt") or std.mem.eql(u8, basename, "c.txt"));
            // A merge asks for all the times it needs at once, so the reply
            // to the last one comes after every request of the re-sync.
            if (self.requests == 2) return d.request_recent_files();
        }
        if (try m.match(.{ "FF", "deleted", tp.extract(&path) })) {
            try std.testing.expectEqualStrings("b.txt", path);
            self.deleted = true;
            return;
        }
        if (try m.match(.{ "FF", "ready", tp.more })) {
            try std.testing.expectEqual(@as(usize, 2), self.requests);
            self.requests = 0;
            return d.request_recent_files();
        }
        if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.any, tp.extract(&count) })) {
            if (!self.resynced) {
                try std.testing.expectEqual(@as(usize, 1), count); // failed stat removed b.txt
                try std.testing.expect(self.deleted);
                self.resynced = true;
                const io = root.get_io();
                var dir = try std.Io.Dir.openDirAbsolute(io, d.dir, .{});
                defer dir.close(io);
                try dir.deleteFile(io, "b.txt");
                try dir.writeFile(io, .{ .sub_path = "c.txt", .data = "new\n" });
                return d.finder.send(.{"sync"});
            }
            try std.testing.expectEqual(@as(usize, 2), self.requests);
            try std.testing.expectEqual(@as(usize, 2), count);
            return tp.exit("success");
        }
    }
};

test "builtin finder refreshes modification times without a watcher" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(MtimeSteps, try fixture(&tmp, &.{ "a.txt", "b.txt" }, &buf));
}

const StatErrorSteps = struct {
    fn start(d: anytype) !void {
        try d.spawn_finder(.{ .file_store = tp.self_pid() });
        try d.finder.send(.{"sync"});
    }

    fn receive(_: *StatErrorSteps, d: anytype, _: tp.pid_ref, m: tp.message) !void {
        var path: []const u8 = undefined;
        var generation: usize = 0;
        var count: usize = 0;
        if (try m.match(.{ "stat", tp.extract(&generation), tp.extract(&path) }))
            return d.finder.send(.{ "FS", "stat_error", generation, path, "AccessDenied" });
        if (try m.match(.{ "FF", "deleted", tp.more })) return error.UnexpectedDeletion;
        if (try m.match(.{ "FF", "ready", tp.more })) return d.request_recent_files();
        if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.any, tp.extract(&count) })) {
            try std.testing.expectEqual(@as(usize, 1), count);
            return tp.exit("success");
        }
    }
};

test "builtin finder keeps files after transient stat errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(StatErrorSteps, try fixture(&tmp, &.{"a.txt"}, &buf));
}

const ZeroMtimeSteps = struct {
    fn start(d: anytype) !void {
        try d.spawn_finder(.{ .file_store = tp.self_pid() });
        try d.finder.send(.{"sync"});
    }

    fn receive(_: *ZeroMtimeSteps, d: anytype, _: tp.pid_ref, m: tp.message) !void {
        var path: []const u8 = undefined;
        var generation: usize = 0;
        var count: usize = 0;
        if (try m.match(.{ "stat", tp.extract(&generation), tp.extract(&path) }))
            return d.finder.send(.{ "FS", "stat", generation, path, @as(i64, 0), @as(i64, 0) });
        if (try m.match(.{ "FF", "deleted", tp.more })) return error.UnexpectedDeletion;
        if (try m.match(.{ "FF", "ready", tp.more })) return d.request_recent_files();
        if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.any, tp.extract(&count) })) {
            try std.testing.expectEqual(@as(usize, 1), count);
            return tp.exit("success");
        }
    }
};

test "builtin finder keeps files whose modification time is zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(ZeroMtimeSteps, try fixture(&tmp, &.{"epoch.txt"}, &buf));
}

const VcsMtimeSteps = struct {
    listings: usize = 0,
    requests: usize = 0,
    resynced: bool = false,
    deleted: usize = 0,

    fn start(d: anytype) !void {
        tp.env.get().proc_set("test_vcs", tp.self_pid());
        try d.spawn_finder(.{ .vcs = test_vcs, .file_store = tp.self_pid() });
        try d.finder.send(.{"sync"});
    }

    fn receive(self: *VcsMtimeSteps, d: anytype, from: tp.pid_ref, m: tp.message) !void {
        var context: usize = 0;
        var cwd: []const u8 = undefined;
        var path: []const u8 = undefined;
        var generation: usize = 0;
        var count: usize = 0;
        if (try m.match(.{ "workspace_path", tp.extract(&context), tp.extract(&cwd) }))
            return from.send(.{ test_vcs.tag, context, "workspace_path", cwd });
        if (try m.match(.{ "workspace_files", tp.extract(&context), tp.any })) {
            self.listings += 1;
            const files = if (self.resynced) "a.txt\nb.txt\nc.txt\n" else "a.txt\nb.txt\nused.txt\n";
            try from.send(.{ test_vcs.tag, context, "workspace_files", files });
            return from.send(.{ test_vcs.tag, context, "workspace_files", null, @as(i64, 0) });
        }
        if (try m.match(.{ "workspace_deleted_files", tp.extract(&context), tp.any })) {
            if (self.resynced)
                try from.send(.{ test_vcs.tag, context, "workspace_deleted_files", "b.txt\n" });
            return from.send(.{ test_vcs.tag, context, "workspace_deleted_files", null, @as(i64, 0) });
        }
        if (try m.match(.{ "stat", tp.extract(&generation), tp.extract(&path) })) {
            self.requests += 1;
            const basename = std.fs.path.basename(path);
            const missing = self.resynced and std.mem.eql(u8, basename, "used.txt");
            if (self.resynced)
                try std.testing.expect(missing or std.mem.eql(u8, basename, "a.txt") or std.mem.eql(u8, basename, "c.txt"));
            if (missing)
                try d.finder.send(.{ "FS", "missing", generation, path })
            else
                try d.finder.send(.{ "FS", "stat", generation, path, @as(i64, 0), @as(i64, 1000) });
            const expected: usize = 3;
            if (self.requests == expected) return d.request_recent_files();
            return;
        }
        if (try m.match(.{ "FF", "deleted", tp.extract(&path) })) {
            try std.testing.expect(self.resynced);
            try std.testing.expect(std.mem.eql(u8, path, "b.txt") or std.mem.eql(u8, path, "used.txt"));
            self.deleted += 1;
            return;
        }
        if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.any, tp.extract(&count) })) {
            if (!self.resynced) {
                try std.testing.expectEqual(@as(usize, 3), count);
                self.resynced = true;
                self.requests = 0;
                try d.finder.send(.{ "update_mru", "a.txt", @as(i128, 2000) });
                try d.finder.send(.{ "update_mru", "used.txt", @as(i128, 2000) });
                return d.finder.send(.{"sync"});
            }
            try std.testing.expectEqual(@as(usize, 2), count);
            try std.testing.expectEqual(@as(usize, 2), self.listings);
            try std.testing.expectEqual(@as(usize, 3), self.requests);
            try std.testing.expectEqual(@as(usize, 2), self.deleted);
            return tp.exit("success");
        }
        if (try m.match(.{ "FF", "ready", tp.more })) return;
    }
};

test "builtin finder validates listed and retained files without a watcher" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(VcsMtimeSteps, try fixture(&tmp, &.{}, &buf));
}

const FailedVcsSteps = struct {
    fn start(d: anytype) !void {
        try d.spawn_finder(.{ .vcs = failing_vcs });
        try d.finder.send(.{"sync"});
    }

    fn receive(_: *FailedVcsSteps, _: anytype, _: tp.pid_ref, m: tp.message) !void {
        var count: usize = 0;
        if (try m.match(.{ "FF", "ready", tp.any, tp.extract(&count) })) {
            try std.testing.expectEqual(@as(usize, 1), count);
            return tp.exit("success");
        }
    }
};

const failing_vcs: VcsLister = .{
    .tag = "failing_vcs",
    .workspace_path = struct {
        fn call(_: usize, _: []const u8) git.Error!void {
            const child = tp.spawn_link(test_allocator, {}, struct {
                fn start(_: void) tp.result {
                    return tp.exit_error(error.VcsCommandFailed, null);
                }
            }.start, "failing_vcs") catch return error.GitCallFailed;
            child.deinit();
        }
    }.call,
    .workspace_files = VcsLister.not_found,
    .workspace_deleted_files = VcsLister.not_found,
    .needs_full_stat = VcsLister.no_full_stat,
};

test "builtin finder falls back when a VCS command exits abnormally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(FailedVcsSteps, try fixture(&tmp, &.{"walked.txt"}, &buf));
}

/// A VCS for tests, played by the actor registered as "test_vcs" in the
/// environment that the finder was spawned with. It gets the calls, and
/// replies to the finder with git's tag, as git commands would.
const test_vcs: VcsLister = .{
    .tag = git.module_name,
    .workspace_path = struct {
        fn call(context: usize, cwd: []const u8) git.Error!void {
            tp.env.get().proc("test_vcs").send(.{ "workspace_path", context, cwd }) catch return error.GitCallFailed;
        }
    }.call,
    .workspace_files = struct {
        fn call(context: usize, cwd: []const u8) git.Error!void {
            tp.env.get().proc("test_vcs").send(.{ "workspace_files", context, cwd }) catch return error.GitCallFailed;
        }
    }.call,
    .workspace_deleted_files = struct {
        fn call(context: usize, cwd: []const u8) git.Error!void {
            tp.env.get().proc("test_vcs").send(.{ "workspace_deleted_files", context, cwd }) catch return error.GitCallFailed;
        }
    }.call,
    .needs_full_stat = VcsLister.no_full_stat,
};

/// Plays git for a finder: lists a repository, then fails part way through
/// listing it again, then finds no repository at all.
const VcsSteps = struct {
    step: enum { listed, deletion_checked, listing_failed, no_repository } = .listed,
    walked: bool = false,

    const tag = git.module_name;

    fn start(d: anytype) !void {
        // the finder gets a copy of this environment when it is spawned
        tp.env.get().proc_set("test_vcs", tp.self_pid());
        try d.spawn_finder(.{ .vcs = test_vcs });
        try d.finder.send(.{"sync"});
    }

    fn receive(self: *VcsSteps, d: anytype, from: tp.pid_ref, m: tp.message) !void {
        var context: usize = 0;
        var cwd: []const u8 = undefined;
        var path: []const u8 = undefined;
        var count: usize = 0;
        if (try m.match(.{"deletion_checked"})) {
            self.step = .listing_failed;
            return d.finder.send(.{"sync"});
        }
        if (try m.match(.{ "FF", "deleted", tp.more })) return error.DeletedUnknownPath;
        if (try m.match(.{ "workspace_path", tp.extract(&context), tp.extract(&cwd) })) {
            // An unknown ignored deletion during the first listing must not
            // have started another one before the explicit sync below.
            if (self.step == .deletion_checked) return error.UnexpectedRelist;
            // a repository rooted at the project, until the last step
            if (self.step == .no_repository)
                return from.send(.{ tag, context, "workspace_path", null });
            return from.send(.{ tag, context, "workspace_path", cwd });
        }
        if (try m.match(.{ "workspace_files", tp.extract(&context), tp.any })) switch (self.step) {
            // in chunks of whole lines, as git commands send their output
            .listed => {
                try from.send(.{ tag, context, "workspace_files", "a.zig\nsrc/b.zig\n" });
                try from.send(.{ tag, context, "workspace_files", "c.md\n" });
                try from.send(.{ "FW", "change", try d.abs(".git/ignored"), file_watcher.EventType.deleted, file_watcher.ObjectType.file });
                return from.send(.{ tag, context, "workspace_files", null, @as(i64, 0) });
            },
            .deletion_checked => return error.UnexpectedListing,
            .listing_failed => {
                try from.send(.{ tag, context, "workspace_files", "a.zig\n" });
                try from.send(.{ tag, context, "workspace_files", null, @as(i64, 128) });
                // answered after the failed listing
                return d.request_recent_files();
            },
            .no_repository => return error.ListedWithoutRepository,
        };
        if (try m.match(.{ "workspace_deleted_files", tp.extract(&context), tp.any })) {
            if (self.step != .listed) return error.UnexpectedListing;
            return from.send(.{ tag, context, "workspace_deleted_files", null, @as(i64, 0) });
        }

        if (try m.match(.{ "FF", "ready", tp.any, tp.extract(&count) })) {
            // the listing, not the walk of the tree, which has another file
            try std.testing.expectEqual(@as(usize, 3), count);
            self.step = .deletion_checked;
            // A re-list was queued after ready, so its workspace_path request
            // would already be ahead of this marker in the mailbox.
            return tp.self_pid().send(.{"deletion_checked"});
        }
        if (try m.match(.{ "PRJ", "recent", tp.any, tp.extract(&path), tp.more })) {
            if (std.mem.eql(u8, path, "walked.txt")) self.walked = true;
            return;
        }
        if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.any, tp.extract(&count) })) switch (self.step) {
            .listed, .deletion_checked => return error.UnexpectedResults,
            .listing_failed => {
                // the failed listing did not truncate the list
                try std.testing.expectEqual(@as(usize, 3), count);
                self.step = .no_repository;
                try d.finder.send(.{"sync"});
                return d.request_recent_files();
            },
            .no_repository => {
                // the walk of the tree replaces the listing once it is merged
                if (count == 1 and self.walked) return tp.exit("success");
                self.walked = false;
                return d.request_recent_files();
            },
        };
    }
};

test "builtin finder indexes a repository listing and walks the tree without one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try run_test_driver(VcsSteps, try fixture(&tmp, &.{"walked.txt"}, &buf));
}
