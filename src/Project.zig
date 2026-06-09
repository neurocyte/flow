const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("soft_root").root;
const fuzzig = @import("fuzzig");
const git = @import("git");
const VcsStatus = @import("VcsStatus");
const file_type_config = @import("file_type_config");
const file_link = @import("file_link");
const builtin = @import("builtin");

const project_manager = @import("project_manager.zig");
const LSP = @import("LSP.zig");
const LSPClient = @import("LSPClient.zig");
const walk_tree = @import("walk_tree.zig");

allocator: std.mem.Allocator,
name: []const u8,
files: std.ArrayListUnmanaged(File) = .empty,
new_or_modified_files: std.ArrayListUnmanaged(FileVcsStatus) = .empty,
pending: std.ArrayListUnmanaged(File) = .empty,
longest_file_path: usize = 0,
longest_new_or_modified_file_path: usize = 0,
open_time: i64,
language_servers: std.StringHashMap(*const LSP),
file_language_server_name: std.StringHashMap([]const u8),
tasks: std.ArrayList(Task),
persistent: bool = false,
logger: log.Logger,
logger_lsp: log.Logger,
logger_git: log.Logger,
last_used: i128,

workspace: ?[]const u8 = null,

walker: ?tp.pid = null,

// async task states
state: struct {
    walk_tree: State = .none,
    workspace_path: State = .none,
    current_branch: State = .none,
    workspace_files: State = .none,
    status: State = .none,
    vcs_new_or_modified_files: State = .none,
} = .{},

status: VcsStatus = .{},
status_request: ?tp.pid = null,
load_complete: bool = false,

const Self = @This();

const OutOfMemoryError = error{OutOfMemory};
const SpawnError = (OutOfMemoryError || error{ThespianSpawnFailed});
pub const RequestError = error{
    InvalidMostRecentFileRequest,
    InvalidNewOrModifiedFilesRequest,
    InvalidQueryNewOrModifiedFilesRequest,
    InvalidRequestNewOrModifiedFilesRequest,
    InvalidRecentFilesRequest,
    InvalidQueryRecentFilesRequest,
    InvalidGetMruPositionRequest,
    InvalidVcsStatusRequest,
    InvalidTasksRequest,
} || OutOfMemoryError || cbor.Error;
pub const StartLspError = (error{ ThespianSpawnFailed, Timeout, InvalidLspCommand } || LspError || OutOfMemoryError || cbor.Error);
pub const LspError = (error{ NoLsp, LspFailed } || OutOfMemoryError || std.Io.Writer.Error);
pub const GitError = error{InvalidGitResponse};
pub const LspInfoError = LSPClient.LspInfoError;

const File = struct {
    path: []const u8,
    type: []const u8,
    icon: []const u8,
    color: u24,
    mtime: i128,
    pos: FilePos = .{},
    visited: bool = false,
};

const FileVcsStatus = struct {
    path: []const u8,
    type: []const u8,
    icon: []const u8,
    color: u24,
    vcs_status: u8,
};

pub const FilePos = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const SourceLocation = struct {
    src: file_link.FileSrc,
    alternative_destination: ?file_link.FileDest = null,
};

const Task = struct {
    command: []const u8,
    mtime: i64,
};

const State = enum { none, running, done, failed };

pub fn init(allocator: std.mem.Allocator, name: []const u8) OutOfMemoryError!Self {
    const now = root.get_now();
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .open_time = now.toMilliseconds(),
        .language_servers = std.StringHashMap(*const LSP).init(allocator),
        .file_language_server_name = std.StringHashMap([]const u8).init(allocator),
        .tasks = .empty,
        .logger = log.logger("project"),
        .logger_lsp = log.logger("lsp"),
        .logger_git = log.logger("git"),
        .last_used = @as(i128, now.toNanoseconds()),
    };
}

pub fn deinit(self: *Self) void {
    if (self.walker) |pid| pid.send(.{"stop"}) catch {};
    if (self.workspace) |p| self.allocator.free(p);
    var i_ = self.file_language_server_name.iterator();
    while (i_.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        self.allocator.free(p.value_ptr.*);
    }
    var i = self.language_servers.iterator();
    while (i.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.term();
    }
    for (self.new_or_modified_files.items) |file| self.allocator.free(file.path);
    self.new_or_modified_files.deinit(self.allocator);
    for (self.files.items) |file| self.allocator.free(file.path);
    self.files.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    for (self.tasks.items) |task| self.allocator.free(task.command);
    self.tasks.deinit(self.allocator);
    self.logger_lsp.deinit();
    self.logger_git.deinit();
    self.logger.deinit();
    self.allocator.free(self.name);
}

pub fn write_state(self: *Self, writer: anytype) !void {
    return self.write_state_v1(writer);
}

pub fn write_state_v1(self: *Self, writer: anytype) !void {
    tp.trace(tp.channel.debug, .{"write_state_v1"});
    try cbor.writeValue(writer, self.name);
    var visited: usize = 0;
    for (self.files.items) |file| {
        if (file.visited) visited += 1;
    }
    tp.trace(tp.channel.debug, .{ "write_state_v1", "files", visited });
    try cbor.writeArrayHeader(writer, visited);
    for (self.files.items) |file| {
        if (!file.visited) continue;
        try cbor.writeArrayHeader(writer, 4);
        try cbor.writeValue(writer, file.path);
        try cbor.writeValue(writer, file.mtime);
        try cbor.writeValue(writer, file.pos.row);
        try cbor.writeValue(writer, file.pos.col);
        tp.trace(tp.channel.debug, .{ "write_state_v1", "file", file.path, file.mtime, file.pos.row, file.pos.col });
    }
    try cbor.writeArrayHeader(writer, self.tasks.items.len);
    tp.trace(tp.channel.debug, .{ "write_state_v1", "tasks", self.tasks.items.len });
    for (self.tasks.items) |task| {
        try cbor.writeArrayHeader(writer, 2);
        try cbor.writeValue(writer, task.command);
        try cbor.writeValue(writer, task.mtime);
        tp.trace(tp.channel.debug, .{ "write_state_v1", "task", task.command, task.mtime });
    }
}

pub fn write_state_v0(self: *Self, writer: anytype) !void {
    try cbor.writeValue(writer, self.name);
    for (self.files.items) |file| {
        if (!file.visited) continue;
        try cbor.writeArrayHeader(writer, 4);
        try cbor.writeValue(writer, file.path);
        try cbor.writeValue(writer, file.mtime);
        try cbor.writeValue(writer, file.row);
        try cbor.writeValue(writer, file.col);
    }
}

pub fn restore_state(self: *Self, data: []const u8) !void {
    tp.trace(tp.channel.debug, .{"restore_state"});
    errdefer |e| tp.trace(tp.channel.debug, .{ "restore_state", "abort", e });
    defer self.sort_files_by_mtime();
    defer self.sort_tasks_by_mtime();
    var iter: []const u8 = data;
    _ = cbor.matchValue(&iter, tp.string) catch {};
    _ = cbor.decodeArrayHeader(&iter) catch |e| switch (e) {
        error.InvalidArrayType => return self.restore_state_v0(data),
        else => return tp.trace(tp.channel.debug, .{ "restore_state", "unknown format", data }),
    };
    self.persistent = true;
    return self.restore_state_v1(data);
}

pub fn restore_state_v1(self: *Self, data: []const u8) !void {
    tp.trace(tp.channel.debug, .{"restore_state_v1"});
    var iter: []const u8 = data;

    var name: []const u8 = undefined;
    _ = cbor.matchValue(&iter, tp.extract(&name)) catch {};
    tp.trace(tp.channel.debug, .{ "restore_state_v1", "name", name });

    var files = try cbor.decodeArrayHeader(&iter);
    tp.trace(tp.channel.debug, .{ "restore_state_v1", "files", files });
    while (files > 0) : (files -= 1) {
        var path_: []const u8 = undefined;
        var mtime: i128 = undefined;
        var row: usize = undefined;
        var col: usize = undefined;
        if (!try cbor.matchValue(&iter, .{
            tp.extract(&path_),
            tp.extract(&mtime),
            tp.extract(&row),
            tp.extract(&col),
        })) {
            try cbor.skipValue(&iter);
            continue;
        }
        tp.trace(tp.channel.debug, .{ "restore_state_v1", "file", path_, mtime, row, col });
        const path = project_manager.normalize_file_path_dot_prefix(path_);
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const stat = std.Io.Dir.cwd().statFile(root.get_io(), path[0..@min(path.len, std.Io.Dir.max_name_bytes)], .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => {
                try self.update_mru_internal(&.{ .src = .{ .path = path, .line = row, .column = col } }, mtime);
                continue;
            },
        };
        switch (stat.kind) {
            .sym_link, .file => try self.update_mru_internal(&.{ .src = .{ .path = path, .line = row, .column = col } }, mtime),
            else => {},
        }
    }

    var tasks = try cbor.decodeArrayHeader(&iter);
    tp.trace(tp.channel.debug, .{ "restore_state_v1", "tasks", tasks });
    while (tasks > 0) : (tasks -= 1) {
        var command: []const u8 = undefined;
        var mtime: i64 = undefined;
        if (!try cbor.matchValue(&iter, .{
            tp.extract(&command),
            tp.extract(&mtime),
        })) {
            try cbor.skipValue(&iter);
            continue;
        }
        tp.trace(tp.channel.debug, .{ "restore_state_v1", "task", command, mtime });
        (try self.tasks.addOne(self.allocator)).* = .{
            .command = try self.allocator.dupe(u8, command),
            .mtime = mtime,
        };
    }
}

pub fn restore_state_v0(self: *Self, data: []const u8) error{
    OutOfMemory,
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    InvalidFloatType,
    InvalidArrayType,
    InvalidPIntType,
    JsonIncompatibleType,
    NotAnObject,
    BadArrayAllocExtract,
    InvalidMapType,
    InvalidUnion,
    WriteFailed,
}!void {
    tp.trace(tp.channel.debug, .{"restore_state_v0"});
    defer self.sort_files_by_mtime();
    var name: []const u8 = undefined;
    var path_: []const u8 = undefined;
    var mtime: i128 = undefined;
    var row: usize = undefined;
    var col: usize = undefined;
    var iter: []const u8 = data;
    _ = cbor.matchValue(&iter, tp.extract(&name)) catch {};
    tp.trace(tp.channel.debug, .{ "restore_state_v0", "name", name });
    while (cbor.matchValue(&iter, .{
        tp.extract(&path_),
        tp.extract(&mtime),
        tp.extract(&row),
        tp.extract(&col),
    }) catch |e| switch (e) {
        error.TooShort => return,
        else => return e,
    }) {
        tp.trace(tp.channel.debug, .{ "restore_state_v0", "file", path_, mtime, row, col });
        const path = project_manager.normalize_file_path_dot_prefix(path_);
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const stat = std.Io.Dir.cwd().statFile(root.get_io(), path[0..@min(path.len, std.Io.Dir.max_name_bytes)], .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => {
                try self.update_mru_internal(&.{ .src = .{ .path = path, .line = row, .column = col } }, mtime);
                continue;
            },
        };
        switch (stat.kind) {
            .sym_link, .file => try self.update_mru_internal(&.{ .src = .{ .path = path, .line = row, .column = col } }, mtime),
            else => {},
        }
    }
}

pub fn get_existing_language_server(self: *Self, language_server: []const u8) ?*const LSP {
    if (self.language_servers.get(language_server)) |lsp| {
        if (!lsp.pid.expired()) return lsp;
        if (self.language_servers.fetchRemove(language_server)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
        }
    }
    return null;
}

pub fn get_or_start_language_server(self: *Self, from: tp.pid_ref, file_path: []const u8, language_server: []const u8, language_server_options: []const u8, language_server_protocol: file_type_config.ProtocolLevel) StartLspError!*const LSP {
    if (self.file_language_server_name.get(file_path)) |lsp_name|
        return self.get_existing_language_server(lsp_name) orelse error.LspFailed;
    const lsp = try LSPClient.start_language_server(self, from, language_server, language_server_options, language_server_protocol);
    const key = try self.allocator.dupe(u8, file_path);
    const value = try self.allocator.dupe(u8, language_server);
    try self.file_language_server_name.put(key, value);
    return lsp;
}

pub fn get_language_server(self: *Self, file_path: []const u8) LspError!*const LSP {
    const lsp_name = self.file_language_server_name.get(file_path) orelse return error.NoLsp;
    return self.get_existing_language_server(lsp_name) orelse error.LspFailed;
}

fn sort_files_by_mtime(self: *Self) void {
    sort_by_mtime(File, self.files.items);
}

fn sort_tasks_by_mtime(self: *Self) void {
    sort_by_mtime(Task, self.tasks.items);
}

inline fn sort_by_mtime(T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn cmp(_: void, lhs: T, rhs: T) bool {
            return lhs.mtime > rhs.mtime;
        }
    }.cmp);
}

pub fn request_n_most_recent_file(self: *Self, from: tp.pid_ref, n: usize) RequestError!void {
    if (n >= self.files.items.len) return error.InvalidMostRecentFileRequest;
    const file_path = if (self.files.items.len > 0) self.files.items[n].path else null;
    from.send(.{file_path}) catch |e|
        std.log.err("send request_n_most_recent_file failed: {t}", .{e});
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) RequestError!void {
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, "", self.files.items.len }) catch {};
    for (self.files.items, 0..) |file, i| {
        from.send(.{ "PRJ", "recent", self.longest_file_path, file.path, file.type, file.icon, file.color }) catch |e| {
            std.log.err("send recent failed: {t}", .{e});
            return;
        };
        if (i >= max) return;
    }
}

fn simple_query_new_or_modified_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) RequestError!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "new_or_modified_files_done", self.longest_file_path, query }) catch {};
    for (self.new_or_modified_files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |idx| {
            var matches = try self.allocator.alloc(usize, query.len);
            defer self.allocator.free(matches);
            var n: usize = 0;
            while (n < query.len) : (n += 1) matches[n] = idx + n;
            from.send(.{ "PRJ", "new_or_modified_files", self.longest_new_or_modified_file_path, file.path, file.type, file.icon, file.color, file.vcs_status, matches }) catch |e| {
                std.log.err("send new_or_modified_files failed: {t}", .{e});
                return error.InvalidNewOrModifiedFilesRequest;
            };
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

fn strip_non_search_chars(self: *const Self, s: []const u8) error{OutOfMemory}![]const u8 {
    var stripped: std.ArrayList(u8) = try .initCapacity(self.allocator, s.len);
    for (s) |c| switch (c) {
        ' ', '\t', '\n' => {},
        else => |c_| (try stripped.addOne(self.allocator)).* = c_,
    };
    return try stripped.toOwnedSlice(self.allocator);
}

pub fn query_new_or_modified_files(self: *Self, from: tp.pid_ref, max: usize, query_: []const u8) RequestError!usize {
    const query = try self.strip_non_search_chars(query_);
    defer self.allocator.free(query);
    if (query.len < 3)
        return self.simple_query_new_or_modified_files(from, max, query);
    defer from.send(.{ "PRJ", "new_or_modified_files_done", self.longest_file_path, query }) catch {};

    var searcher = try fuzzig.Ascii.init(
        self.allocator,
        4096, // haystack max size
        4096, // needle max size
        .{ .case_sensitive = false },
    );
    defer searcher.deinit();

    const Match = struct {
        path: []const u8,
        type: []const u8,
        icon: []const u8,
        color: u24,
        vcs_status: u8,
        score: i32,
        matches: []const usize,
    };
    var matches: std.ArrayList(Match) = .empty;

    for (self.new_or_modified_files.items) |file| {
        const match = searcher.scoreMatches(file.path, query);
        if (match.score) |score| {
            (try matches.addOne(self.allocator)).* = .{
                .path = file.path,
                .type = file.type,
                .icon = file.icon,
                .color = file.color,
                .vcs_status = file.vcs_status,
                .score = score,
                .matches = try self.allocator.dupe(usize, match.matches),
            };
        }
    }
    if (matches.items.len == 0) return 0;

    const less_fn = struct {
        fn less_fn(_: void, lhs: Match, rhs: Match) bool {
            return lhs.score > rhs.score;
        }
    }.less_fn;
    std.mem.sort(Match, matches.items, {}, less_fn);

    for (matches.items[0..@min(max, matches.items.len)]) |match|
        from.send(.{ "PRJ", "new_or_modified_files", self.longest_new_or_modified_file_path, match.path, match.type, match.icon, match.color, match.vcs_status, match.matches }) catch |e| {
            std.log.err("send new_or_modified_files failed: {t}", .{e});
            return error.InvalidQueryNewOrModifiedFilesRequest;
        };
    return @min(max, matches.items.len);
}

pub fn request_new_or_modified_files(self: *Self, from: tp.pid_ref, max: usize) RequestError!void {
    defer from.send(.{ "PRJ", "new_or_modified_files_done", self.longest_new_or_modified_file_path, "" }) catch {};
    for (self.new_or_modified_files.items, 0..) |file, i| {
        from.send(.{ "PRJ", "new_or_modified_files", self.longest_new_or_modified_file_path, file.path, file.type, file.icon, file.color, file.vcs_status }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return error.InvalidRequestNewOrModifiedFilesRequest;
        };
        if (i >= max) return;
    }
}

fn simple_query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) RequestError!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query, self.files.items.len }) catch {};
    for (self.files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |idx| {
            var matches = try self.allocator.alloc(usize, query.len);
            defer self.allocator.free(matches);
            var n: usize = 0;
            while (n < query.len) : (n += 1) matches[n] = idx + n;
            from.send(.{ "PRJ", "recent", self.longest_file_path, file.path, file.type, file.icon, file.color, matches }) catch |e| {
                std.log.err("send navigate failed: {t}", .{e});
                return error.InvalidRecentFilesRequest;
            };
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query_: []const u8) RequestError!usize {
    const query = try self.strip_non_search_chars(query_);
    defer self.allocator.free(query);
    if (query.len < 3)
        return self.simple_query_recent_files(from, max, query);
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query, self.files.items.len }) catch {};

    var searcher = try fuzzig.Ascii.init(
        self.allocator,
        4096, // haystack max size
        4096, // needle max size
        .{ .case_sensitive = false },
    );
    defer searcher.deinit();

    const Match = struct {
        path: []const u8,
        type: []const u8,
        icon: []const u8,
        color: u24,
        score: i32,
        matches: []const usize,
    };
    var matches: std.ArrayList(Match) = .empty;

    for (self.files.items) |file| {
        const match = searcher.scoreMatches(file.path, query);
        if (match.score) |score| {
            (try matches.addOne(self.allocator)).* = .{
                .path = file.path,
                .type = file.type,
                .icon = file.icon,
                .color = file.color,
                .score = score,
                .matches = try self.allocator.dupe(usize, match.matches),
            };
        }
    }
    if (matches.items.len == 0) return 0;

    const less_fn = struct {
        fn less_fn(_: void, lhs: Match, rhs: Match) bool {
            return lhs.score > rhs.score;
        }
    }.less_fn;
    std.mem.sort(Match, matches.items, {}, less_fn);

    for (matches.items[0..@min(max, matches.items.len)]) |match|
        from.send(.{ "PRJ", "recent", self.longest_file_path, match.path, match.type, match.icon, match.color, match.matches }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return error.InvalidQueryRecentFilesRequest;
        };
    return @min(max, matches.items.len);
}

fn walk_tree_entry_callback(parent: tp.pid_ref, root_path: []const u8, file_path: []const u8, mtime_high: i64, mtime_low: i64) error{Exit}!void {
    const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(file_path);
    try parent.send(.{ "walk_tree_entry", root_path, file_path, mtime_high, mtime_low, file_type, file_icon, file_color });
}

pub fn walk_tree_entry(self: *Self, m: tp.message) OutOfMemoryError!void {
    var file_path: []const u8 = undefined;
    var mtime_high: i64 = 0;
    var mtime_low: i64 = 0;
    var file_type: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var file_color: u32 = 0;
    if (!(cbor.match(m.buf, .{
        tp.string,
        tp.string,
        tp.extract(&file_path),
        tp.extract(&mtime_high),
        tp.extract(&mtime_low),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
    }) catch return)) return;
    const mtime = (@as(i128, @intCast(mtime_high)) << 64) | @as(i128, @intCast(mtime_low));
    const ft = file_type_config.get(file_type) catch null;

    self.longest_file_path = @max(self.longest_file_path, file_path.len);
    (try self.pending.addOne(self.allocator)).* = .{
        .path = try self.allocator.dupe(u8, file_path),
        .type = if (ft) |ft_| ft_.name else try self.allocator.dupe(u8, file_type),
        .icon = if (ft) |ft_| ft_.icon orelse &.{} else try self.allocator.dupe(u8, file_icon),
        .color = @intCast(file_color),
        .mtime = mtime,
    };
}

fn walk_tree_done_callback(parent: tp.pid_ref, root_path: []const u8) error{Exit}!void {
    try parent.send(.{ "walk_tree_done", root_path });
}

pub fn walk_tree_done(self: *Self, parent: tp.pid_ref) OutOfMemoryError!void {
    self.state.walk_tree = .done;
    if (self.walker) |pid| pid.deinit();
    self.walker = null;
    return self.loaded(parent);
}

fn default_ft() struct { []const u8, []const u8, u24 } {
    return .{
        file_type_config.default.name,
        file_type_config.default.icon,
        file_type_config.default.color,
    };
}

pub fn guess_path_file_type(path: []const u8, file_name: []const u8) struct { []const u8, []const u8, u24 } {
    var buf: [4096]u8 = undefined;
    const file_path = std.fmt.bufPrint(&buf, "{s}{}{s}", .{ path, std.fs.path.sep, file_name }) catch return default_ft();
    return guess_file_type(file_path);
}

pub fn guess_file_type(file_path: []const u8) struct { []const u8, []const u8, u24 } {
    var buf: [1024]u8 = undefined;
    const content: []const u8 = blk: {
        const io = root.get_io();
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch break :blk &.{};
        defer file.close(io);
        const size = safe_file_read(file, &buf) catch break :blk &.{};
        break :blk buf[0..size];
    };
    return if (file_type_config.guess_file_type(file_path, content)) |ft| .{
        ft.name,
        ft.icon orelse file_type_config.default.icon,
        ft.color orelse file_type_config.default.color,
    } else default_ft();
}

fn safe_file_read(self: std.Io.File, buffer: []u8) (error{ FileHandleInvalidForReading, ProcessNotFound, ConnectionTimedOut } || std.Io.File.ReadStreamingError)!usize {
    return switch (builtin.os.tag) {
        .windows => safe_windows_read(self.handle, buffer),
        else => safe_posix_read(self.handle, buffer),
    };
}

fn safe_windows_read(handle: std.os.windows.HANDLE, buffer: []u8) (error{ FileHandleInvalidForReading, ProcessNotFound, ConnectionTimedOut } || std.Io.File.ReadStreamingError)!usize {
    const windows = std.os.windows;
    const ReadFile = struct {
        extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: ?[*]u8, nNumberOfBytesToRead: windows.DWORD, lpNumberOfBytesRead: ?*windows.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    }.ReadFile;
    var bytes_read: windows.DWORD = 0;
    const len: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
    if (ReadFile(handle, buffer.ptr, len, &bytes_read, null) == .FALSE)
        return windows.unexpectedError(windows.GetLastError());
    return @intCast(bytes_read);
}

fn safe_posix_read(fd: std.posix.fd_t, buf: []u8) (error{ FileHandleInvalidForReading, ConnectionTimedOut, ProcessNotFound } || std.Io.File.ReadStreamingError)!usize {
    const native_os = builtin.os.tag;
    const unexpectedErrno = safe_unexpectedErrno;
    const maxInt = std.math.maxInt;
    const system = std.posix.system;
    const errno = std.posix.errno;
    if (buf.len == 0) return 0;
    if (native_os == .wasi and !builtin.link_libc) {
        const iovec = std.os.posix.iovec;
        const wasi = std.os.wasi;
        const iovs = [1]iovec{iovec{
            .base = buf.ptr,
            .len = buf.len,
        }};

        var nread: usize = undefined;
        switch (wasi.fd_read(fd, &iovs, iovs.len, &nread)) {
            .SUCCESS => return nread,
            .INTR => unreachable,
            .INVAL => return error.FileHandleInvalidForReading,
            .FAULT => unreachable,
            .AGAIN => unreachable,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    // Prevents EINVAL.
    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };
    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.FileHandleInvalidForReading,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn safe_unexpectedErrno(_: std.posix.system.E) std.posix.UnexpectedError {
    return error.Unexpected;
}

fn merge_pending_files(self: *Self) OutOfMemoryError!void {
    defer self.sort_files_by_mtime();
    const existing = try self.files.toOwnedSlice(self.allocator);
    defer self.allocator.free(existing);
    self.files = self.pending;
    self.pending = .empty;

    for (existing) |*file| {
        self.update_mru_internal(&.{ .src = .{ .path = file.path, .line = file.pos.row, .column = file.pos.col } }, file.mtime) catch {};
        self.allocator.free(file.path);
    }
}

fn loaded(self: *Self, parent: tp.pid_ref) OutOfMemoryError!void {
    inline for (@typeInfo(@TypeOf(self.state)).@"struct".fields) |f|
        if (@field(self.state, f.name) == .running) return;

    if (self.load_complete) return;
    self.load_complete = true;

    self.logger.print("project files: {d} restored, {d} {s}", .{
        self.files.items.len,
        self.pending.items.len,
        if (self.state.workspace_files == .done) "tracked" else "walked",
    });

    try self.merge_pending_files();
    self.logger.print("opened: {s} with {d} files in {d} ms", .{
        self.name,
        self.files.items.len,
        root.get_now().toMilliseconds() - self.open_time,
    });

    parent.send(.{ "PRJ", "open_done", self.name, self.longest_file_path, self.files.items.len }) catch {};
}

pub fn update_mru(self: *Self, source_location: *const SourceLocation) OutOfMemoryError!void {
    defer self.sort_files_by_mtime();
    try self.update_mru_internal(source_location, @as(i128, std.Io.Clock.real.now(root.get_io()).toNanoseconds()));
}

fn update_mru_internal(self: *Self, source_location: *const SourceLocation, mtime: i128) OutOfMemoryError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, source_location.src.path)) continue;
        file.mtime = mtime;
        if (source_location.src.line != 0) {
            file.pos.row = source_location.src.line;
            file.pos.col = source_location.src.column;
            file.visited = true;
        }
        return;
    }
    const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(source_location.src.path);
    if (source_location.src.line != 0) {
        (try self.files.addOne(self.allocator)).* = .{
            .path = try self.allocator.dupe(u8, source_location.src.path),
            .type = file_type,
            .icon = file_icon,
            .color = file_color,
            .mtime = mtime,
            .pos = .{ .row = source_location.src.line, .col = source_location.src.column },
            .visited = true,
        };
    } else {
        (try self.files.addOne(self.allocator)).* = .{
            .path = try self.allocator.dupe(u8, source_location.src.path),
            .type = file_type,
            .icon = file_icon,
            .color = file_color,
            .mtime = mtime,
        };
    }
}

pub fn get_mru_position(self: *Self, from: tp.pid_ref, file_path: []const u8) RequestError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        from.send(.{ file.pos.row + 1, file.pos.col + 1 }) catch return error.InvalidGetMruPositionRequest;
        return;
    }
    from.send(.{"none"}) catch return error.InvalidGetMruPositionRequest;
}

pub fn request_vcs_status(self: *Self, from: tp.pid_ref) RequestError!void {
    switch (self.state.status) {
        .failed => return,
        .none => switch (self.state.workspace_path) {
            .running => {
                if (self.status_request) |_| return;
                self.status_request = from.clone();
            },
            .failed => return,
            .done => if (self.workspace == null) return,
            .none => return error.InvalidVcsStatusRequest,
        },
        .running => {
            if (self.status_request) |_| return;
            self.status_request = from.clone();
        },
        .done => {
            if (self.status_request) |_| return;
            self.status_request = from.clone();
            self.state.status = .running;
            git.status(@intFromPtr(self)) catch {
                self.state.status = .failed;
            };
        },
    }
    switch (self.state.vcs_new_or_modified_files) {
        .done => {
            for (self.new_or_modified_files.items) |file| self.allocator.free(file.path);
            self.new_or_modified_files.clearRetainingCapacity();
            self.state.vcs_new_or_modified_files = .running;
            git.new_or_modified_files(@intFromPtr(self)) catch {
                self.state.vcs_new_or_modified_files = .failed;
            };
        },
        else => {},
    }
}

pub fn request_tasks(self: *Self, from: tp.pid_ref) RequestError!void {
    var message: std.Io.Writer.Allocating = .init(self.allocator);
    defer message.deinit();
    const writer = &message.writer;
    try cbor.writeArrayHeader(writer, self.tasks.items.len);
    for (self.tasks.items) |task|
        try cbor.writeValue(writer, task.command);
    from.send_raw(.{ .buf = message.written() }) catch |e| {
        std.log.err("send navigate failed: {t}", .{e});
        return error.InvalidTasksRequest;
    };
}

pub fn add_task(self: *Self, command: []const u8) OutOfMemoryError!void {
    defer self.sort_tasks_by_mtime();
    const mtime = root.get_now().toMilliseconds();
    for (self.tasks.items) |*task|
        if (std.mem.eql(u8, task.command, command)) {
            tp.trace(tp.channel.debug, .{ "Project", self.name, "add_task", command, task.mtime, "->", mtime });
            task.mtime = mtime;
            return;
        };
    tp.trace(tp.channel.debug, .{ "project", self.name, "add_task", command, mtime });
    (try self.tasks.addOne(self.allocator)).* = .{
        .command = try self.allocator.dupe(u8, command),
        .mtime = mtime,
    };
}

pub fn delete_task(self: *Self, command: []const u8) error{}!void {
    for (self.tasks.items, 0..) |task, i|
        if (std.mem.eql(u8, task.command, command)) {
            const removed = self.tasks.orderedRemove(i);
            self.allocator.free(removed.command);
            return;
        };
}

pub const did_open = LSPClient.did_open;
pub const did_change = LSPClient.did_change;
pub const did_save = LSPClient.did_save;
pub const did_close = LSPClient.did_close;

pub const SendGotoRequestError = LSPClient.SendGotoRequestError;
pub const goto_definition = LSPClient.goto_definition;
pub const goto_declaration = LSPClient.goto_declaration;
pub const goto_implementation = LSPClient.goto_implementation;
pub const goto_type_definition = LSPClient.goto_type_definition;

pub fn convert_path(file_path_: []u8) []u8 {
    var file_path = file_path_;
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    return file_path;
}

pub const references = LSPClient.references;
pub const highlight_references = LSPClient.highlight_references;

pub const CompletionError = LSPClient.CompletionError;
pub const completion = LSPClient.completion;

pub const SymbolInformationError = LSPClient.SymbolInformationError;
pub const symbols = LSPClient.symbols;

pub const rename_symbol = LSPClient.rename_symbol;

pub const hover = LSPClient.hover;

pub const DiagnosticError = LSPClient.DiagnosticError;
pub const publish_diagnostics = LSPClient.publish_diagnostics;

pub const LogMessageError = LSPClient.LogMessageError;
pub const show_message = LSPClient.show_message;
pub const log_message = LSPClient.log_message;
pub const show_notification = LSPClient.show_notification;

pub const register_capability = LSPClient.register_capability;
pub const workDoneProgress_create = LSPClient.workDoneProgress_create;
pub const unsupported_lsp_request = LSPClient.unsupported_lsp_request;

pub const GetLineOfFileError = LSPClient.GetLineOfFileError;

pub fn query_git(self: *Self) void {
    self.state.workspace_path = .running;
    git.workspace_path(@intFromPtr(self)) catch {
        self.state.workspace_path = .failed;
        self.start_walker();
    };
    self.state.current_branch = .running;
    git.current_branch(@intFromPtr(self)) catch {
        self.state.current_branch = .failed;
    };
}

fn start_walker(self: *Self) void {
    self.state.walk_tree = .running;
    self.walker = walk_tree.start(self.allocator, self.name, walk_tree_entry_callback, walk_tree_done_callback, .{
        .follow_directory_symlinks = tp.env.get().is("follow_directory_symlinks"),
        .maximum_symlink_depth = @intCast(tp.env.get().num("maximum_symlink_depth")),
        .log_ignored_links = tp.env.get().is("log_ignored_links"),
    }) catch blk: {
        self.state.walk_tree = .failed;
        break :blk null;
    };
}

pub fn process_git(self: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || error{Exit})!void {
    var value: []const u8 = undefined;
    var path: []const u8 = undefined;
    var vcs_status: u8 = undefined;
    if (try m.match(.{ tp.any, tp.any, "status", tp.more })) {
        return self.process_status(parent, m);
    } else if (try m.match(.{ tp.any, tp.any, "workspace_path", tp.null_ })) {
        self.state.workspace_path = .done;
        self.start_walker();
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "workspace_path", tp.extract(&value) })) {
        if (self.workspace) |p| self.allocator.free(p);
        self.workspace = convert_path(try self.allocator.dupe(u8, value));
        self.state.workspace_path = .done;
        self.state.workspace_files = .running;
        git.workspace_files(@intFromPtr(self)) catch {
            self.state.workspace_files = .failed;
        };
        self.state.status = .running;
        git.status(@intFromPtr(self)) catch {
            self.state.status = .failed;
        };
        for (self.new_or_modified_files.items) |file| self.allocator.free(file.path);
        self.new_or_modified_files.clearRetainingCapacity();
        self.state.vcs_new_or_modified_files = .running;
        git.new_or_modified_files(@intFromPtr(self)) catch {
            self.state.vcs_new_or_modified_files = .failed;
        };
    } else if (try m.match(.{ tp.any, tp.any, "current_branch", tp.null_ })) {
        self.state.current_branch = .done;
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "current_branch", tp.extract(&value) })) {
        if (self.status.branch) |p| self.allocator.free(p);
        self.status.branch = try self.allocator.dupe(u8, value);
        self.state.current_branch = .done;
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "workspace_files", tp.extract(&path) })) {
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const mtime: i128 = blk: {
            break :blk @as(i128, (std.Io.Dir.cwd().statFile(root.get_io(), path, .{}) catch break :blk 0).mtime.nanoseconds);
        };
        const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(path);
        (try self.pending.addOne(self.allocator)).* = .{
            .path = convert_path(try self.allocator.dupe(u8, path)),
            .type = file_type,
            .icon = file_icon,
            .color = file_color,
            .mtime = mtime,
        };
    } else if (try m.match(.{ tp.any, tp.any, "workspace_files", tp.null_ })) {
        self.state.workspace_files = .done;
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "new_or_modified_files", tp.null_ })) {
        self.state.vcs_new_or_modified_files = .done;
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "new_or_modified_files", tp.extract(&vcs_status), tp.extract(&path) })) {
        self.longest_new_or_modified_file_path = @max(self.longest_new_or_modified_file_path, path.len);
        const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(path);
        (try self.new_or_modified_files.addOne(self.allocator)).* = .{
            .path = convert_path(try self.allocator.dupe(u8, path)),
            .type = file_type,
            .icon = file_icon,
            .color = file_color,
            .vcs_status = vcs_status,
        };
    } else {
        self.logger_git.err("git", tp.unexpected(m));
    }
}

fn process_status(self: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || error{Exit})!void {
    const any = cbor.any;
    const extract = cbor.extract;
    const null_ = cbor.null_;

    var value: []const u8 = undefined;
    var ahead: []const u8 = undefined;
    var behind: []const u8 = undefined;

    if (self.state.status == .done)
        self.status.reset(self.allocator);

    if (try m.match(.{ any, any, "status", "#", "branch.oid", extract(&value) })) {
        // commit | (initial)
    } else if (try m.match(.{ any, any, "status", "#", "branch.head", extract(&value) })) {
        if (self.status.branch) |p| self.allocator.free(p);
        self.status.branch = try self.allocator.dupe(u8, value);
    } else if (try m.match(.{ any, any, "status", "#", "branch.upstream", extract(&value) })) {
        // upstream-branch
    } else if (try m.match(.{ any, any, "status", "#", "branch.ab", extract(&ahead), extract(&behind) })) {
        if (self.status.ahead) |p| self.allocator.free(p);
        self.status.ahead = try self.allocator.dupe(u8, ahead);
        if (self.status.behind) |p| self.allocator.free(p);
        self.status.behind = try self.allocator.dupe(u8, behind);
    } else if (try m.match(.{ any, any, "status", "#", "stash", extract(&value) })) {
        if (self.status.stash) |p| self.allocator.free(p);
        self.status.stash = try self.allocator.dupe(u8, value);
    } else if (try m.match(.{ any, any, "status", "1", tp.more })) {
        // ordinary file: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        self.status.changed += 1;
    } else if (try m.match(.{ any, any, "status", "2", tp.more })) {
        // rename or copy: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><sep><origPath>
        self.status.changed += 1;
    } else if (try m.match(.{ any, any, "status", "u", tp.more })) {
        // unmerged file: <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        self.status.changed += 1;
    } else if (try m.match(.{ any, any, "status", "?", tp.more })) {
        // untracked file: <path>
        self.status.untracked += 1;
    } else if (try m.match(.{ any, any, "status", "!", tp.more })) {
        // ignored file: <path>
    } else if (try m.match(.{ any, any, "status", null_ })) {
        self.state.status = .done;
        try self.loaded(parent);
        if (self.status_request) |from| {
            from.send(.{ "vcs_status", self.status }) catch {};
            from.deinit();
            self.status_request = null;
        }
    }
}

pub fn request_vcs_id(self: *Self, file_path: []const u8) error{OutOfMemory}!void {
    const request = try self.allocator.create(VcsIdRequest);
    request.* = .{
        .allocator = self.allocator,
        .project = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
    };
    git.rev_parse(@intFromPtr(request), "HEAD", file_path) catch |e|
        self.logger_git.print_err("rev-parse", "failed: {t}", .{e});
}

pub const VcsIdRequest = struct {
    allocator: std.mem.Allocator,
    project: usize,
    file_path: []const u8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub fn request_vcs_content(self: *Self, file_path: []const u8, vcs_id: []const u8) error{OutOfMemory}!void {
    const request = try self.allocator.create(VcsContentRequest);
    request.* = .{
        .allocator = self.allocator,
        .project = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
        .vcs_id = try self.allocator.dupe(u8, vcs_id),
    };
    git.cat_file(@intFromPtr(request), vcs_id) catch |e|
        self.logger_git.print_err("cat-file", "failed: {t}", .{e});
}

pub const VcsContentRequest = struct {
    allocator: std.mem.Allocator,
    project: usize,
    file_path: []const u8,
    vcs_id: []const u8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.vcs_id);
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};

pub fn process_git_response(self: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || GitError || error{Exit})!void {
    var context: usize = undefined;
    var vcs_id: []const u8 = undefined;
    var vcs_content: []const u8 = undefined;
    var blame_output: []const u8 = undefined;

    _ = self;

    if (try m.match(.{ tp.any, tp.extract(&context), "rev_parse", tp.extract(&vcs_id) })) {
        const request: *VcsIdRequest = @ptrFromInt(context);
        parent.send(.{ "PRJ", "vcs_id", request.file_path, vcs_id }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "rev_parse", tp.null_ })) {
        const request: *VcsIdRequest = @ptrFromInt(context);
        defer request.deinit();
    } else if (try m.match(.{ tp.any, tp.extract(&context), "cat_file", tp.extract(&vcs_content) })) {
        const request: *VcsContentRequest = @ptrFromInt(context);
        parent.send(.{ "PRJ", "vcs_content", request.file_path, request.vcs_id, vcs_content }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "cat_file", tp.null_ })) {
        const request: *VcsContentRequest = @ptrFromInt(context);
        defer request.deinit();
        parent.send(.{ "PRJ", "vcs_content", request.file_path, request.vcs_id, null }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "blame", tp.extract(&blame_output) })) {
        const request: *GitBlameRequest = @ptrFromInt(context);
        parent.send(.{ "PRJ", "git_blame", request.file_path, blame_output }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "blame", tp.null_ })) {
        const request: *GitBlameRequest = @ptrFromInt(context);
        defer request.deinit();
        parent.send(.{ "PRJ", "git_blame", request.file_path, null }) catch {};
    }
}

pub fn request_vcs_blame(self: *Self, file_path: []const u8) error{OutOfMemory}!void {
    const request = try self.allocator.create(GitBlameRequest);
    request.* = .{
        .allocator = self.allocator,
        .project = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
    };
    git.blame(@intFromPtr(request), file_path) catch |e|
        self.logger_git.print_err("blame", "failed: {t}", .{e});
}

pub const GitBlameRequest = struct {
    allocator: std.mem.Allocator,
    project: usize,
    file_path: []const u8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }
};
