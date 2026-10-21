const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const soft_root = @import("soft_root").root;
const is_directory = soft_root.is_directory;
const git = @import("git");
const VcsStatus = @import("VcsStatus");
const file_watcher = @import("file_watcher");
const gitignore = @import("gitignore");

const Project = @import("Project.zig");
const LSPClient = @import("LSPClient.zig");
const convert_path = LSPClient.convert_path;

allocator: std.mem.Allocator,
root: []const u8,
git_dir: []const u8,
git_common_dir: []const u8,
superproject: ?[]const u8,
logger_git: log.Logger,

vcs_status_files: std.ArrayListUnmanaged(VcsStatusFile) = .empty,
vcs_status_files_next: std.ArrayListUnmanaged(VcsStatusFile) = .empty,

vcs_watcher: ?file_watcher.Owned = null,
worktree_watcher: ?file_watcher.Owned = null,
vcs_ref_watches: [2]?[]const u8 = .{ null, null },

state: State = .none,
status: VcsStatus = .{},
status_next: VcsStatus = .{},
status_reply: bool = false,
status_dirty: bool = false,
status_timer: ?tp.timeout = null,

/// projects, open files and vcs_status views that use the repository
holds: usize = 0,
idle_timer: ?tp.timeout = null,

const Self = @This();

const OutOfMemoryError = error{OutOfMemory};
pub const State = enum { none, running, done, failed };

pub const FileKind = enum { file, submodule, nested_repo };

const VcsStatusFile = struct {
    path: []const u8,
    orig_path: []const u8 = "",
    type: []const u8 = "",
    icon: []const u8 = "",
    color: u24 = 0,
    x: u8,
    y: u8,
    kind: FileKind,
    meta_resolved: bool = false,

    fn eql(a: []const VcsStatusFile, b: []const VcsStatusFile) bool {
        if (a.len != b.len) return false;
        for (a, b) |a_, b_| if (a_.x != b_.x or a_.y != b_.y or a_.kind != b_.kind or
            !std.mem.eql(u8, a_.path, b_.path) or
            !std.mem.eql(u8, a_.orig_path, b_.orig_path)) return false;
        return true;
    }

    fn free_all(allocator: std.mem.Allocator, files: *std.ArrayListUnmanaged(VcsStatusFile)) void {
        for (files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.orig_path);
        }
        files.clearRetainingCapacity();
    }
};

pub const Discovery = struct {
    root: []const u8,
    git_dir: []const u8,
    git_common_dir: []const u8,
    superproject: ?[]const u8,
};

pub fn init(allocator: std.mem.Allocator, discovery: Discovery) OutOfMemoryError!Self {
    const root_ = try allocator.dupe(u8, discovery.root);
    errdefer allocator.free(root_);
    const git_dir = try allocator.dupe(u8, discovery.git_dir);
    errdefer allocator.free(git_dir);
    const git_common_dir = try allocator.dupe(u8, discovery.git_common_dir);
    errdefer allocator.free(git_common_dir);
    const superproject = if (discovery.superproject) |p| try allocator.dupe(u8, p) else null;
    return .{
        .allocator = allocator,
        .root = root_,
        .git_dir = git_dir,
        .git_common_dir = git_common_dir,
        .superproject = superproject,
        .logger_git = log.logger("git"),
    };
}

pub fn deinit(self: *Self) void {
    if (self.vcs_watcher) |*watcher| watcher.deinit();
    if (self.worktree_watcher) |*watcher| watcher.deinit();
    for (self.vcs_ref_watches) |p| if (p) |p_| self.allocator.free(p_);
    if (self.status_timer) |*t| t.deinit();
    if (self.idle_timer) |*t| t.deinit();
    self.status.reset(self.allocator);
    self.status_next.reset(self.allocator);
    VcsStatusFile.free_all(self.allocator, &self.vcs_status_files);
    self.vcs_status_files.deinit(self.allocator);
    VcsStatusFile.free_all(self.allocator, &self.vcs_status_files_next);
    self.vcs_status_files_next.deinit(self.allocator);
    if (self.superproject) |p| self.allocator.free(p);
    self.allocator.free(self.git_common_dir);
    self.allocator.free(self.git_dir);
    self.allocator.free(self.root);
    self.logger_git.deinit();
}

pub fn request_vcs_status_files(self: *Self, from: tp.pid_ref) error{InvalidRequestVcsStatusFilesRequest}!void {
    defer from.send(.{ "PRJ", "vcs_status_files_done", self.root }) catch {};
    for (self.vcs_status_files.items) |*file| {
        resolve_meta(file);
        from.send(.{ "PRJ", "vcs_status_files", self.root, file.path, file.type, file.icon, file.color, &[_]u8{file.x}, &[_]u8{file.y}, file.orig_path, file.kind }) catch |e| {
            std.log.err("send vcs_status_files failed: {t}", .{e});
            return error.InvalidRequestVcsStatusFilesRequest;
        };
    }
}

fn resolve_meta(file: *VcsStatusFile) void {
    if (file.meta_resolved) return;
    file.type, file.icon, file.color = Project.guess_file_type(file.path);
    file.meta_resolved = true;
}

pub fn request_vcs_status(self: *Self, from: tp.pid_ref) void {
    switch (self.state) {
        .failed => return,
        .none => {
            self.status_reply = true;
            self.refresh_vcs_status();
        },
        .running => self.status_reply = true,
        .done => {
            from.send(.{ "vcs_status", self.root, self.status }) catch {};
            self.refresh_vcs_status();
        },
    }
}

pub fn refresh_vcs_status(self: *Self) void {
    if (self.state == .running) {
        self.status_dirty = true;
        return;
    }
    self.status_dirty = false;
    self.status_next.reset(self.allocator);
    VcsStatusFile.free_all(self.allocator, &self.vcs_status_files_next);
    self.state = .running;
    git.status(@intFromPtr(self), self.root) catch {
        self.state = .failed;
    };
}

const vcs_changed_delay_ms = 100;

pub fn vcs_changed(self: *Self) void {
    if (!tp.env.get().is("enable_vcs_watcher")) return;
    if (!self.is_active()) return self.mark_stale();
    if (self.status_timer != null) return;
    self.status_timer = tp.timeout.init_ms(vcs_changed_delay_ms, tp.message.fmt(.{ "vcs_changed_timeout", self.root })) catch return;
}

pub fn path_changed(self: *Self, path: []const u8) void {
    self.vcs_changed();
    const watcher = self.worktree_watcher orelse return;
    if (!std.mem.eql(u8, std.fs.path.basename(path), gitignore.per_directory_file_name)) return;
    if (path.len <= self.root.len) return;
    const rel_path = path[self.root.len + 1 ..];
    watcher.ignore_changed(self.root, std.fs.path.dirname(rel_path) orelse "") catch |e|
        std.log.err("worktree_watcher.ignore_changed: {s} -> {}", .{ self.root, e });
}

fn mark_stale(self: *Self) void {
    if (self.state == .done) self.state = .none;
}

fn is_active(self: *const Self) bool {
    return self.holds > 0 or self.idle_timer != null;
}

const idle_delay_ms = 30 * std.time.ms_per_s;

pub fn hold(self: *Self, watch_worktree: bool) void {
    const was_active = self.is_active();
    self.holds += 1;
    if (self.idle_timer) |*t| t.deinit();
    self.idle_timer = null;
    self.start_vcs_watcher();
    if (watch_worktree) self.start_worktree_watcher();
    if (!was_active) self.refresh_vcs_status();
}

pub fn release(self: *Self) void {
    self.holds -|= 1;
    if (self.holds > 0 or self.idle_timer != null) return;
    self.idle_timer = tp.timeout.init_ms(idle_delay_ms, tp.message.fmt(.{ "vcs_repo_idle", self.root })) catch return self.deactivate();
}

pub fn idle_timeout(self: *Self) void {
    if (self.idle_timer) |*t| t.deinit();
    self.idle_timer = null;
    if (self.holds == 0) self.deactivate();
}

fn deactivate(self: *Self) void {
    if (self.vcs_watcher) |*watcher| watcher.deinit();
    self.vcs_watcher = null;
    if (self.worktree_watcher) |*watcher| watcher.deinit();
    self.worktree_watcher = null;
    for (&self.vcs_ref_watches) |*p| if (p.*) |p_| {
        self.allocator.free(p_);
        p.* = null;
    };
    if (self.status_timer) |*t| t.deinit();
    self.status_timer = null;
    self.mark_stale();
}

/// [root, holds, active, watches .git, watches the worktree, a project watches the worktree]
pub fn write_info(self: *const Self, writer: *std.Io.Writer, watched_by_project: bool) std.Io.Writer.Error!void {
    try cbor.writeValue(writer, .{ self.root, self.holds, self.is_active(), self.vcs_watcher != null, self.worktree_watcher != null, watched_by_project });
}

pub fn vcs_changed_timeout(self: *Self) void {
    if (self.status_timer) |*t| t.deinit();
    self.status_timer = null;
    self.refresh_vcs_status();
}

pub fn owns_vcs_path(self: *const Self, path: []const u8) bool {
    return is_in_dir(path, self.git_dir) or is_in_dir(path, self.git_common_dir);
}

fn is_in_dir(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or std.fs.path.isSep(path[dir.len]);
}

fn start_vcs_watcher(self: *Self) void {
    if (!tp.env.get().is("enable_vcs_watcher")) return;
    if (self.vcs_watcher != null) return;
    self.vcs_watcher = file_watcher.Owned.init(.vcs_metadata) catch |e| {
        std.log.err("vcs_watcher.init: {s} -> {}", .{ self.root, e });
        return;
    };
    self.vcs_watch(self.git_dir);
    if (!std.mem.eql(u8, self.git_common_dir, self.git_dir)) self.vcs_watch(self.git_common_dir);
    for ([_][]const u8{ "logs/refs", "reftable" }) |rel| {
        const path = self.nearest_vcs_dir(self.git_common_dir, rel) orelse continue;
        defer self.allocator.free(path);
        self.vcs_watch(path);
    }
    self.update_vcs_ref_watches();
}

/// watches the files of the repository, for a repository that no project watcher covers
fn start_worktree_watcher(self: *Self) void {
    if (!tp.env.get().is("enable_file_watcher")) return;
    if (self.worktree_watcher != null) return;
    self.worktree_watcher = file_watcher.Owned.init(.repo_worktree) catch |e| {
        std.log.err("worktree_watcher.init: {s} -> {}", .{ self.root, e });
        return;
    };
    self.worktree_watcher.?.watch(self.root) catch |e|
        std.log.err("worktree_watcher.watch: {s} -> {}", .{ self.root, e });
}

fn vcs_watch(self: *Self, path: []const u8) void {
    const watcher = self.vcs_watcher orelse return;
    watcher.watch(path) catch |e| std.log.err("vcs_watcher.watch: {s} -> {}", .{ path, e });
}

fn vcs_unwatch(self: *Self, path: []const u8) void {
    const watcher = self.vcs_watcher orelse return;
    watcher.unwatch(path) catch |e| std.log.err("vcs_watcher.unwatch: {s} -> {}", .{ path, e });
}

fn nearest_vcs_dir(self: *Self, base: []const u8, rel: []const u8) ?[]const u8 {
    const path = std.fs.path.join(self.allocator, &.{ base, rel }) catch return null;
    defer self.allocator.free(path);
    var dir: []const u8 = path;
    while (dir.len > base.len and !is_directory(dir))
        dir = std.fs.path.dirname(dir) orelse return null;
    if (dir.len <= base.len or self.is_git_dir(dir)) return null;
    return self.allocator.dupe(u8, dir) catch null;
}

fn is_git_dir(self: *const Self, path: []const u8) bool {
    return std.mem.eql(u8, path, self.git_dir) or std.mem.eql(u8, path, self.git_common_dir);
}

fn update_vcs_ref_watches(self: *Self) void {
    if (self.vcs_watcher == null) return;
    const branch = if (self.status.branch) |b| if (std.mem.eql(u8, b, "(detached)")) null else b else null;
    self.move_vcs_ref_watch(0, self.git_common_dir, "refs/heads", branch);
    self.move_vcs_ref_watch(1, self.git_common_dir, "refs/remotes", self.status.upstream);
}

fn move_vcs_ref_watch(self: *Self, slot: usize, common_dir: []const u8, prefix: []const u8, ref_name: ?[]const u8) void {
    const new: ?[]const u8 = if (ref_name) |name| blk: {
        const dir = std.fs.path.dirname(name) orelse break :blk self.nearest_vcs_dir(common_dir, prefix);
        const rel = std.fs.path.join(self.allocator, &.{ prefix, dir }) catch return;
        defer self.allocator.free(rel);
        break :blk self.nearest_vcs_dir(common_dir, rel);
    } else null;
    const old = self.vcs_ref_watches[slot];
    const other = self.vcs_ref_watches[1 - slot];
    if (eql_opt_path(old, new)) {
        if (new) |p| self.allocator.free(p);
        return;
    }
    if (old) |p| {
        if (!eql_opt_path(other, p)) self.vcs_unwatch(p);
        self.allocator.free(p);
    }
    if (new) |p| if (!eql_opt_path(other, p)) self.vcs_watch(p);
    self.vcs_ref_watches[slot] = new;
}

fn eql_opt_path(a: ?[]const u8, b: ?[]const u8) bool {
    const a_ = a orelse return b == null;
    const b_ = b orelse return false;
    return std.mem.eql(u8, a_, b_);
}

pub fn process_status(self: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || error{Exit})!void {
    const any = cbor.any;
    const extract = cbor.extract;
    const null_ = cbor.null_;

    var value: []const u8 = undefined;
    var ahead: []const u8 = undefined;
    var behind: []const u8 = undefined;
    var xy: []const u8 = undefined;
    var sub: []const u8 = undefined;
    var path: []const u8 = undefined;
    var orig_path: []const u8 = undefined;

    const next = &self.status_next;
    if (try m.match(.{ any, any, "status", "#", "branch.oid", extract(&value) })) {
        // commit | (initial)
        if (next.commit) |p| self.allocator.free(p);
        next.commit = try self.allocator.dupe(u8, value);
    } else if (try m.match(.{ any, any, "status", "#", "branch.head", extract(&value) })) {
        if (next.branch) |p| self.allocator.free(p);
        next.branch = try self.allocator.dupe(u8, value);
    } else if (try m.match(.{ any, any, "status", "#", "branch.upstream", extract(&value) })) {
        if (next.upstream) |p| self.allocator.free(p);
        next.upstream = try self.allocator.dupe(u8, value);
    } else if (try m.match(.{ any, any, "status", "#", "branch.ab", extract(&ahead), extract(&behind) })) {
        if (next.ahead) |p| self.allocator.free(p);
        next.ahead = try self.allocator.dupe(u8, ahead);
        if (next.behind) |p| self.allocator.free(p);
        next.behind = try self.allocator.dupe(u8, behind);
    } else if (try m.match(.{ any, any, "status", "#", "stash", extract(&value) })) {
        if (next.stash) |p| self.allocator.free(p);
        next.stash = try self.allocator.dupe(u8, value);
    } else if (try m.match(.{ any, any, "status", "1", extract(&xy), extract(&sub), any, any, any, any, any, extract(&path) })) {
        // ordinary file: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        next.changed += 1;
        try self.add_vcs_status_file(xy, sub, path, "");
    } else if (try m.match(.{ any, any, "status", "2", extract(&xy), extract(&sub), any, any, any, any, any, any, extract(&path), extract(&orig_path) })) {
        // rename or copy: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><sep><origPath>
        next.changed += 1;
        try self.add_vcs_status_file(xy, sub, path, orig_path);
    } else if (try m.match(.{ any, any, "status", "u", extract(&xy), extract(&sub), any, any, any, any, any, any, any, extract(&path) })) {
        // unmerged file: <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        next.changed += 1;
        try self.add_vcs_status_file(xy, sub, path, "");
    } else if (try m.match(.{ any, any, "status", "?", extract(&path) })) {
        // untracked file: <path>
        next.untracked += 1;
        try self.add_vcs_status_file("??", "N...", path, "");
    } else if (try m.match(.{ any, any, "status", "!", tp.more })) {
        // ignored file: <path>
    } else if (try m.match(.{ any, any, "status", null_ })) {
        self.state = .done;
        const changed = !self.status.eql(next) or
            !VcsStatusFile.eql(self.vcs_status_files.items, self.vcs_status_files_next.items);
        std.mem.swap(VcsStatus, &self.status, next);
        next.reset(self.allocator);
        std.mem.swap(std.ArrayListUnmanaged(VcsStatusFile), &self.vcs_status_files, &self.vcs_status_files_next);
        VcsStatusFile.free_all(self.allocator, &self.vcs_status_files_next);
        if (changed or self.status_reply)
            parent.send(.{ "vcs_status", self.root, self.status }) catch {};
        self.status_reply = false;
        self.update_vcs_ref_watches();
        if (self.status_dirty) self.refresh_vcs_status();
    }
}

fn add_vcs_status_file(self: *Self, xy: []const u8, sub: []const u8, path: []const u8, orig_path: []const u8) OutOfMemoryError!void {
    if (xy.len != 2) return;
    const path_ = try self.abs_path(path);
    errdefer self.allocator.free(path_);
    const kind: FileKind = if (sub.len > 0 and sub[0] == 'S')
        .submodule
    else if (std.mem.eql(u8, xy, "??") and is_repo_dir(path_))
        .nested_repo
    else
        .file;
    const orig_path_ = if (orig_path.len > 0) try self.abs_path(orig_path) else "";
    errdefer self.allocator.free(orig_path_);
    (try self.vcs_status_files_next.addOne(self.allocator)).* = .{
        .path = path_,
        .orig_path = orig_path_,
        .x = xy[0],
        .y = xy[1],
        .kind = kind,
    };
}

/// git lists an untracked directory with a trailing separator
fn is_repo_dir(path: []const u8) bool {
    if (path.len == 0 or !std.fs.path.isSep(path[path.len - 1])) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = std.fmt.bufPrint(&buf, "{s}.git", .{path}) catch return false;
    return is_directory(git_path) or soft_root.is_file(git_path);
}

/// git status paths are relative to the repository root
fn abs_path(self: *const Self, path: []const u8) OutOfMemoryError![]const u8 {
    const rel = convert_path(try self.allocator.dupe(u8, path));
    defer self.allocator.free(rel);
    return std.fs.path.join(self.allocator, &.{ self.root, rel });
}

/// file_path is absolute, reply_path is the path the editor asked for
pub fn request_vcs_id(self: *Self, file_path: []const u8, reply_path: []const u8) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsIdRequest);
    request.* = .{
        .allocator = self.allocator,
        .repo = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, reply_path),
    };
    git.rev_parse(@intFromPtr(request), self.root, "HEAD", file_path) catch |e|
        self.logger_git.print_err("rev-parse", "failed: {t}", .{e});
}

pub const VcsIdRequest = struct {
    allocator: std.mem.Allocator,
    repo: usize,
    file_path: []const u8,
    found: bool = false,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub fn request_vcs_content(self: *Self, file_path: []const u8, vcs_id: []const u8) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsContentRequest);
    request.* = .{
        .allocator = self.allocator,
        .repo = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
        .vcs_id = try self.allocator.dupe(u8, vcs_id),
    };
    git.cat_file(@intFromPtr(request), self.root, vcs_id) catch |e|
        self.logger_git.print_err("cat-file", "failed: {t}", .{e});
}

pub const VcsContentRequest = struct {
    allocator: std.mem.Allocator,
    repo: usize,
    file_path: []const u8,
    vcs_id: []const u8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.vcs_id);
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub fn request_vcs_first_change(self: *Self, file_path: []const u8, staged: bool) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsFirstChangeRequest);
    request.* = .{
        .allocator = self.allocator,
        .repo = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
    };
    git.first_change(@intFromPtr(request), self.root, staged, file_path) catch |e| {
        self.logger_git.print_err("diff", "failed: {t}", .{e});
        request.deinit();
    };
}

pub const VcsFirstChangeRequest = struct {
    allocator: std.mem.Allocator,
    repo: usize,
    file_path: []const u8,
    line: ?usize = null,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub const VcsDiffMode = git.DiffMode;

pub fn request_vcs_diff(self: *Self, file_path: []const u8, orig_path: []const u8, mode: VcsDiffMode, context_lines: usize) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsDiffRequest);
    request.* = .{
        .allocator = self.allocator,
        .repo = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
        .mode = mode,
    };
    git.diff(@intFromPtr(request), self.root, mode, file_path, orig_path, context_lines) catch |e| {
        self.logger_git.print_err("diff", "failed: {t}", .{e});
        request.deinit();
    };
}

pub const VcsDiffRequest = struct {
    allocator: std.mem.Allocator,
    repo: usize,
    file_path: []const u8,
    mode: VcsDiffMode,
    output: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *@This()) void {
        self.output.deinit(self.allocator);
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub const VcsIndexUpdate = enum { stage, unstage, revert };

pub fn request_vcs_update_index(self: *Self, update: VcsIndexUpdate, file_paths: []const []const u8) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsIndexUpdateRequest);
    request.* = .{ .allocator = self.allocator, .repo = @intFromPtr(self) };
    const initial = if (self.status.commit) |commit| std.mem.eql(u8, commit, "(initial)") else false;
    const git_update: git.IndexUpdate = switch (update) {
        .stage => .stage,
        .unstage => if (initial) .unstage_initial else .unstage,
        .revert => .revert,
    };
    git.update_index(@intFromPtr(request), self.root, git_update, file_paths) catch |e| {
        self.logger_git.print_err("update-index", "failed: {t}", .{e});
        request.deinit();
    };
}

pub fn request_vcs_apply_patch(self: *Self, update: VcsIndexUpdate, patch: []const u8) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsIndexUpdateRequest);
    request.* = .{ .allocator = self.allocator, .repo = @intFromPtr(self) };
    const git_update: git.IndexUpdate = switch (update) {
        .stage => .stage,
        .unstage => .unstage,
        .revert => .revert,
    };
    git.apply_patch(@intFromPtr(request), self.root, git_update, patch) catch |e| {
        self.logger_git.print_err("apply", "failed: {t}", .{e});
        request.deinit();
    };
}

pub const VcsIndexUpdateRequest = struct {
    allocator: std.mem.Allocator,
    repo: usize,

    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }
};

pub const VcsFileState = enum { unversioned, modified, clean };

/// file_path is absolute
pub fn request_vcs_file_state(self: *Self, from: tp.pid_ref, id: usize, file_path: []const u8) OutOfMemoryError!void {
    const request = try self.allocator.create(VcsFileStateRequest);
    request.* = .{
        .allocator = self.allocator,
        .repo = @intFromPtr(self),
        .id = id,
        .file_path = try self.allocator.dupe(u8, file_path),
    };
    git.ls_tree(@intFromPtr(request), self.root, "HEAD", request.file_path) catch request.done(from);
}

pub const VcsFileStateRequest = struct {
    allocator: std.mem.Allocator,
    repo: usize,
    id: usize,
    file_path: []const u8,
    state: VcsFileState = .unversioned,

    fn done(self: *@This(), parent: tp.pid_ref) void {
        parent.send(.{ "PRJ", "vcs_file_state", self.id, self.state }) catch {};
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub fn process_git_response(self: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || error{Exit})!void {
    var context: usize = undefined;
    var vcs_id: []const u8 = undefined;
    var vcs_content: []const u8 = undefined;
    var line: usize = undefined;
    var exit_code: i64 = undefined;
    var diff_output: []const u8 = undefined;

    if (try m.match(.{ tp.any, tp.extract(&context), "rev_parse", tp.extract(&vcs_id) })) {
        const request: *VcsIdRequest = @ptrFromInt(context);
        request.found = true;
        parent.send(.{ "PRJ", "vcs_id", request.file_path, vcs_id }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "rev_parse", tp.null_ })) {
        const request: *VcsIdRequest = @ptrFromInt(context);
        defer request.deinit();
        if (!request.found) parent.send(.{ "PRJ", "vcs_id", request.file_path, null }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "cat_file", tp.extract(&vcs_content) })) {
        const request: *VcsContentRequest = @ptrFromInt(context);
        parent.send(.{ "PRJ", "vcs_content", request.file_path, request.vcs_id, vcs_content }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "cat_file", tp.null_ })) {
        const request: *VcsContentRequest = @ptrFromInt(context);
        defer request.deinit();
        parent.send(.{ "PRJ", "vcs_content", request.file_path, request.vcs_id, null }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "ls_tree", tp.string })) {
        const request: *VcsFileStateRequest = @ptrFromInt(context);
        request.state = .clean;
    } else if (try m.match(.{ tp.any, tp.extract(&context), "ls_tree", tp.null_ })) {
        const request: *VcsFileStateRequest = @ptrFromInt(context);
        if (request.state == .unversioned) return request.done(parent);
        git.file_status(context, self.root, request.file_path) catch {
            request.state = .modified;
            request.done(parent);
        };
    } else if (try m.match(.{ tp.any, tp.extract(&context), "file_status", tp.string })) {
        const request: *VcsFileStateRequest = @ptrFromInt(context);
        request.state = .modified;
    } else if (try m.match(.{ tp.any, tp.extract(&context), "file_status", tp.null_ })) {
        const request: *VcsFileStateRequest = @ptrFromInt(context);
        request.done(parent);
    } else if (try m.match(.{ tp.any, tp.extract(&context), "update_index", tp.extract(&exit_code) }) or
        try m.match(.{ tp.any, tp.extract(&context), "apply_patch", tp.extract(&exit_code) }))
    {
        const request: *VcsIndexUpdateRequest = @ptrFromInt(context);
        request.deinit();
        parent.send(.{ "PRJ", "vcs_update_index_done", exit_code }) catch {};
        self.status_reply = true;
        self.refresh_vcs_status();
    } else if (try m.match(.{ tp.any, tp.extract(&context), "diff", tp.extract(&diff_output) })) {
        const request: *VcsDiffRequest = @ptrFromInt(context);
        try request.output.appendSlice(request.allocator, diff_output);
    } else if (try m.match(.{ tp.any, tp.extract(&context), "diff", tp.null_ })) {
        const request: *VcsDiffRequest = @ptrFromInt(context);
        defer request.deinit();
        parent.send(.{ "PRJ", "vcs_diff", request.file_path, request.mode, request.output.items }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "first_change", tp.extract(&line) })) {
        const request: *VcsFirstChangeRequest = @ptrFromInt(context);
        if (request.line == null) request.line = line;
    } else if (try m.match(.{ tp.any, tp.extract(&context), "first_change", tp.null_ })) {
        const request: *VcsFirstChangeRequest = @ptrFromInt(context);
        defer request.deinit();
        parent.send(.{ "PRJ", "vcs_first_change", request.file_path, request.line }) catch {};
    }
}
