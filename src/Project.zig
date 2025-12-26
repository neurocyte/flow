const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("soft_root").root;
const dizzy = @import("dizzy");
const Buffer = @import("Buffer");
const fuzzig = @import("fuzzig");
const tracy = @import("tracy");
const git = @import("git");
const VcsStatus = @import("VcsStatus");
const file_type_config = @import("file_type_config");
const builtin = @import("builtin");

const project_manager = @import("project_manager.zig");
const LSP = @import("LSP.zig");
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
pub const RequestError = error{InvalidRequest} || OutOfMemoryError || cbor.Error;
pub const StartLspError = (error{ ThespianSpawnFailed, Timeout, InvalidLspCommand } || LspError || OutOfMemoryError || cbor.Error);
pub const LspError = (error{ NoLsp, LspFailed } || OutOfMemoryError || std.Io.Writer.Error);
pub const GitError = error{InvalidGitResponse};
pub const LspInfoError = error{ InvalidInfoMessage, InvalidTriggerCharacters };

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

const Task = struct {
    command: []const u8,
    mtime: i64,
};

const State = enum { none, running, done, failed };

pub fn init(allocator: std.mem.Allocator, name: []const u8) OutOfMemoryError!Self {
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .open_time = std.time.milliTimestamp(),
        .language_servers = std.StringHashMap(*const LSP).init(allocator),
        .file_language_server_name = std.StringHashMap([]const u8).init(allocator),
        .tasks = .empty,
        .logger = log.logger("project"),
        .logger_lsp = log.logger("lsp"),
        .logger_git = log.logger("git"),
        .last_used = std.time.nanoTimestamp(),
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
        const stat = std.fs.cwd().statFile(path) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => {
                try self.update_mru_internal(path, mtime, row, col);
                continue;
            },
        };
        switch (stat.kind) {
            .sym_link, .file => try self.update_mru_internal(path, mtime, row, col),
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
        const stat = std.fs.cwd().statFile(path) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => {
                try self.update_mru_internal(path, mtime, row, col);
                continue;
            },
        };
        switch (stat.kind) {
            .sym_link, .file => try self.update_mru_internal(path, mtime, row, col),
            else => {},
        }
    }
}

fn get_existing_language_server(self: *Self, language_server: []const u8) ?*const LSP {
    if (self.language_servers.get(language_server)) |lsp| {
        if (!lsp.pid.expired()) return lsp;
        if (self.language_servers.fetchRemove(language_server)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
        }
    }
    return null;
}

fn get_language_server_instance(self: *Self, from: tp.pid_ref, language_server: []const u8, language_server_options: []const u8) StartLspError!*const LSP {
    if (self.get_existing_language_server(language_server)) |lsp| return lsp;
    const lsp = try LSP.open(self.allocator, self.name, .{ .buf = language_server });
    errdefer lsp.deinit();
    const uri = try self.make_URI(null);
    defer self.allocator.free(uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, self.name, std.fs.path.sep);
    const basename = if (basename_begin) |begin| self.name[begin + 1 ..] else self.name;

    errdefer lsp.deinit();
    try self.send_lsp_init_request(from, lsp, self.name, basename, uri, language_server, language_server_options);
    try self.language_servers.put(try self.allocator.dupe(u8, language_server), lsp);
    return lsp;
}

fn get_or_start_language_server(self: *Self, from: tp.pid_ref, file_path: []const u8, language_server: []const u8, language_server_options: []const u8) StartLspError!*const LSP {
    if (self.file_language_server_name.get(file_path)) |lsp_name|
        return self.get_existing_language_server(lsp_name) orelse error.LspFailed;
    const lsp = try self.get_language_server_instance(from, language_server, language_server_options);
    const key = try self.allocator.dupe(u8, file_path);
    const value = try self.allocator.dupe(u8, language_server);
    try self.file_language_server_name.put(key, value);
    return lsp;
}

fn get_language_server(self: *Self, file_path: []const u8) LspError!*const LSP {
    const lsp_name = self.file_language_server_name.get(file_path) orelse return error.NoLsp;
    return self.get_existing_language_server(lsp_name) orelse error.LspFailed;
}

fn make_URI(self: *Self, file_path: ?[]const u8) LspError![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    if (file_path) |path| {
        if (std.fs.path.isAbsolute(path)) {
            try writer.print("file://{s}", .{path});
        } else {
            try writer.print("file://{s}{c}{s}", .{ self.name, std.fs.path.sep, path });
        }
    } else try writer.print("file://{s}", .{self.name});
    return buf.toOwnedSlice();
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
    if (n >= self.files.items.len) return error.InvalidRequest;
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
                return error.InvalidRequest;
            };
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn query_new_or_modified_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) RequestError!usize {
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
            return error.InvalidRequest;
        };
    return @min(max, matches.items.len);
}

pub fn request_new_or_modified_files(self: *Self, from: tp.pid_ref, max: usize) RequestError!void {
    defer from.send(.{ "PRJ", "new_or_modified_files_done", self.longest_new_or_modified_file_path, "" }) catch {};
    for (self.new_or_modified_files.items, 0..) |file, i| {
        from.send(.{ "PRJ", "new_or_modified_files", self.longest_new_or_modified_file_path, file.path, file.type, file.icon, file.color, file.vcs_status }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return error.InvalidRequest;
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
                return error.InvalidRequest;
            };
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) RequestError!usize {
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
            return error.InvalidRequest;
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

    self.longest_file_path = @max(self.longest_file_path, file_path.len);
    (try self.pending.addOne(self.allocator)).* = .{
        .path = try self.allocator.dupe(u8, file_path),
        .type = file_type,
        .icon = file_icon,
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
        const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_only }) catch break :blk &.{};
        defer file.close();
        const size = file.read(&buf) catch break :blk &.{};
        break :blk buf[0..size];
    };
    return if (file_type_config.guess_file_type(file_path, content)) |ft| .{
        ft.name,
        ft.icon orelse file_type_config.default.icon,
        ft.color orelse file_type_config.default.color,
    } else default_ft();
}

fn merge_pending_files(self: *Self) OutOfMemoryError!void {
    defer self.sort_files_by_mtime();
    const existing = try self.files.toOwnedSlice(self.allocator);
    defer self.allocator.free(existing);
    self.files = self.pending;
    self.pending = .empty;

    for (existing) |*file| {
        self.update_mru_internal(file.path, file.mtime, file.pos.row, file.pos.col) catch {};
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
        std.time.milliTimestamp() - self.open_time,
    });

    parent.send(.{ "PRJ", "open_done", self.name, self.longest_file_path, self.files.items.len }) catch {};
}

pub fn update_mru(self: *Self, file_path: []const u8, row: usize, col: usize) OutOfMemoryError!void {
    defer self.sort_files_by_mtime();
    try self.update_mru_internal(file_path, std.time.nanoTimestamp(), row, col);
}

fn update_mru_internal(self: *Self, file_path: []const u8, mtime: i128, row: usize, col: usize) OutOfMemoryError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        file.mtime = mtime;
        if (row != 0) {
            file.pos.row = row;
            file.pos.col = col;
            file.visited = true;
        }
        return;
    }
    const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(file_path);
    if (row != 0) {
        (try self.files.addOne(self.allocator)).* = .{
            .path = try self.allocator.dupe(u8, file_path),
            .type = file_type,
            .icon = file_icon,
            .color = file_color,
            .mtime = mtime,
            .pos = .{ .row = row, .col = col },
            .visited = true,
        };
    } else {
        (try self.files.addOne(self.allocator)).* = .{
            .path = try self.allocator.dupe(u8, file_path),
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
        from.send(.{ file.pos.row + 1, file.pos.col + 1 }) catch return error.InvalidRequest;
        return;
    }
    from.send(.{"none"}) catch return error.InvalidRequest;
}

pub fn request_vcs_status(self: *Self, from: tp.pid_ref) RequestError!void {
    switch (self.state.status) {
        .failed => return,
        .none => switch (self.state.workspace_path) {
            .running => {
                if (self.status_request) |_| return;
                self.status_request = from.clone();
            },
            else => return error.InvalidRequest,
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
        return error.InvalidRequest;
    };
}

pub fn add_task(self: *Self, command: []const u8) OutOfMemoryError!void {
    defer self.sort_tasks_by_mtime();
    const mtime = std.time.milliTimestamp();
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

pub fn did_open(self: *Self, from: tp.pid_ref, file_path: []const u8, file_type: []const u8, language_server: []const u8, language_server_options: []const u8, version: usize, text: []const u8) StartLspError!void {
    defer std.heap.c_allocator.free(text);
    self.update_mru(file_path, 0, 0) catch {};
    const lsp = try self.get_or_start_language_server(from, file_path, language_server, language_server_options);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    }) catch return error.LspFailed;
}

pub fn did_change(self: *Self, file_path: []const u8, version: usize, text_dst: []const u8, text_src: []const u8, eol_mode: Buffer.EolMode) LspError!void {
    _ = eol_mode;
    defer std.heap.c_allocator.free(text_dst);
    defer std.heap.c_allocator.free(text_src);
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);

    var arena_ = std.heap.ArenaAllocator.init(self.allocator);
    const arena = arena_.allocator();
    var scratch_alloc: ?[]u32 = null;
    defer {
        const frame = tracy.initZone(@src(), .{ .name = "deinit" });
        self.allocator.free(uri);
        arena_.deinit();
        frame.deinit();
        if (scratch_alloc) |scratch|
            self.allocator.free(scratch);
    }

    var dizzy_edits = std.ArrayListUnmanaged(dizzy.Edit){};
    var edits_cb: std.Io.Writer.Allocating = .init(self.allocator);
    const writer = &edits_cb.writer;

    const scratch_len = 4 * (text_dst.len + text_src.len) + 2;
    const scratch = blk: {
        const frame = tracy.initZone(@src(), .{ .name = "scratch" });
        defer frame.deinit();
        break :blk try self.allocator.alloc(u32, scratch_len);
    };
    scratch_alloc = scratch;

    {
        const frame = tracy.initZone(@src(), .{ .name = "diff" });
        defer frame.deinit();
        try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, text_src, text_dst, scratch);
    }
    var lines_dst: usize = 0;
    var last_offset: usize = 0;
    var edits_count: usize = 0;

    {
        const frame = tracy.initZone(@src(), .{ .name = "transform" });
        defer frame.deinit();
        for (dizzy_edits.items) |dizzy_edit| {
            switch (dizzy_edit.kind) {
                .equal => {
                    scan_char(text_src[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .insert => {
                    const line_start_dst: usize = lines_dst;
                    try cbor.writeValue(writer, .{
                        .range = .{
                            .start = .{ .line = line_start_dst, .character = last_offset },
                            .end = .{ .line = line_start_dst, .character = last_offset },
                        },
                        .text = text_dst[dizzy_edit.range.start..dizzy_edit.range.end],
                    });
                    edits_count += 1;
                    scan_char(text_dst[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .delete => {
                    var line_end_dst: usize = lines_dst;
                    var offset_end_dst: usize = last_offset;
                    scan_char(text_src[dizzy_edit.range.start..dizzy_edit.range.end], &line_end_dst, '\n', &offset_end_dst);
                    try cbor.writeValue(writer, .{
                        .range = .{
                            .start = .{ .line = lines_dst, .character = last_offset },
                            .end = .{ .line = line_end_dst, .character = offset_end_dst },
                        },
                        .text = "",
                    });
                    edits_count += 1;
                },
            }
        }
    }
    {
        const frame = tracy.initZone(@src(), .{ .name = "send" });
        defer frame.deinit();
        var msg: std.Io.Writer.Allocating = .init(self.allocator);
        defer msg.deinit();
        const msg_writer = &msg.writer;
        try cbor.writeMapHeader(msg_writer, 2);
        try cbor.writeValue(msg_writer, "textDocument");
        try cbor.writeValue(msg_writer, .{ .uri = uri, .version = version });
        try cbor.writeValue(msg_writer, "contentChanges");
        try cbor.writeArrayHeader(msg_writer, edits_count);
        _ = try msg_writer.write(edits_cb.written());

        lsp.send_notification_raw("textDocument/didChange", msg.written()) catch return error.LspFailed;
    }
}

fn scan_char(chars: []const u8, lines: *usize, char: u8, last_offset: ?*usize) void {
    var pos = chars;
    if (last_offset) |off| off.* += pos.len;
    while (pos.len > 0) {
        if (pos[0] == char) {
            if (last_offset) |off| off.* = pos.len - 1;
            lines.* += 1;
        }
        pos = pos[1..];
    }
}

pub fn did_save(self: *Self, file_path: []const u8) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    lsp.send_notification("textDocument/didSave", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub fn did_close(self: *Self, file_path: []const u8) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    lsp.send_notification("textDocument/didClose", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/definition");
}

pub fn goto_declaration(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/declaration");
}

pub fn goto_implementation(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/implementation");
}

pub fn goto_type_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/typeDefinition");
}

pub const SendGotoRequestError = (error{} || LspError || GetLineOfFileError || cbor.Error);

fn send_goto_request(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize, method: []const u8) SendGotoRequestError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        name: []const u8,
        project: *Self,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.name);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var link: []const u8 = undefined;
            var locations: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, .{tp.extract_cbor(&link)} })) {
                    try navigate_to_location_link(self_.from.ref(), link);
                } else if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&locations) })) {
                    _ = try send_reference_list("REF", self_.from.ref(), locations, self_.name);
                }
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&link) })) {
                try navigate_to_location_link(self_.from.ref(), link);
            }
        }
    } = .{
        .from = from.clone(),
        .name = try std.heap.c_allocator.dupe(u8, self.name),
        .project = self,
    };

    lsp.send_request(self.allocator, method, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    }, handler) catch return error.LspFailed;
}

fn file_uri_to_path(uri: []const u8, file_path_buf: []u8) error{InvalidTargetURI}![]u8 {
    return std.Uri.percentDecodeBackwards(file_path_buf, if (std.mem.eql(u8, uri[0..7], "file://"))
        uri[7..]
    else if (std.mem.eql(u8, uri[0..5], "file:"))
        uri[5..]
    else
        return error.InvalidTargetURI);
}

fn navigate_to_location_link(from: tp.pid_ref, location_link: []const u8) (error{InvalidTargetURI} || LocationLinkError)!void {
    const location: LocationLink = try read_locationlink(location_link);
    if (location.targetUri == null or location.targetRange == null) return error.InvalidLocationLink;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_path = try file_uri_to_path(location.targetUri.?, &file_path_buf);
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    if (location.targetSelectionRange) |sel| {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                location.targetSelectionRange.?.start.line + 1,
                location.targetSelectionRange.?.start.character + 1,
                sel.start.line,
                sel.start.character,
                sel.end.line,
                sel.end.character,
            },
        } }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return;
        };
    } else {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                location.targetRange.?.start.line + 1,
                location.targetRange.?.start.character + 1,
            },
        } }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return;
        };
    }
}

pub fn references(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    self.logger_lsp.print("finding references...", .{});

    const handler: struct {
        from: tp.pid,
        name: []const u8,
        project: *Self,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.name);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var locations: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&locations) })) {
                const count = try send_reference_list("REF", self_.from.ref(), locations, self_.name);
                self_.project.logger_lsp.print("found {d} references", .{count});
            }
        }
    } = .{
        .from = from.clone(),
        .name = try std.heap.c_allocator.dupe(u8, self.name),
        .project = self,
    };

    lsp.send_request(self.allocator, "textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
        .context = .{ .includeDeclaration = true },
    }, handler) catch return error.LspFailed;
}

pub fn highlight_references(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        name: []const u8,
        project: *Self,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.name);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var locations: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&locations) })) {
                _ = try send_reference_list("HREF", self_.from.ref(), locations, self_.name);
            }
        }
    } = .{
        .from = from.clone(),
        .name = try std.heap.c_allocator.dupe(u8, self.name),
        .project = self,
    };

    lsp.send_request(self.allocator, "textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
        .context = .{ .includeDeclaration = true },
    }, handler) catch return error.LspFailed;
}

fn send_reference_list(tag: []const u8, to: tp.pid_ref, locations: []const u8, name: []const u8) (error{
    InvalidTargetURI,
    InvalidReferenceList,
} || LocationLinkError || GetLineOfFileError || cbor.Error)!usize {
    defer to.send(.{ tag, "done" }) catch {};
    var iter = locations;
    var len = try cbor.decodeArrayHeader(&iter);
    const count = len;
    while (len > 0) : (len -= 1) {
        var location: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&location))) {
            try send_reference(tag, to, location, name);
        } else return error.InvalidReferenceList;
    }
    return count;
}

fn send_reference(tag: []const u8, to: tp.pid_ref, location_: []const u8, name: []const u8) (error{InvalidTargetURI} || LocationLinkError || GetLineOfFileError || cbor.Error)!void {
    const allocator = std.heap.c_allocator;
    const location: LocationLink = try read_locationlink(location_);
    if (location.targetUri == null or location.targetRange == null) return error.InvalidLocationLink;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_path = try file_uri_to_path(location.targetUri.?, &file_path_buf);
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    const line = try get_line_of_file(allocator, file_path, location.targetRange.?.start.line);
    defer allocator.free(line);
    const file_path_ = if (file_path.len > name.len and std.mem.eql(u8, name, file_path[0..name.len]))
        file_path[name.len + 1 ..]
    else
        file_path;
    to.send(.{
        tag,
        file_path_,
        location.targetRange.?.start.line + 1,
        location.targetRange.?.start.character,
        location.targetRange.?.end.line + 1,
        location.targetRange.?.end.character,
        line,
    }) catch |e| {
        std.log.err("send {s} (in send_reference) failed: {t}", .{ tag, e });
        return;
    };
}

pub const CompletionError = error{
    InvalidTargetURI,
} || CompletionListError || CompletionItemError || TextEditError || cbor.Error;

pub fn completion(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,
        row: usize,
        col: usize,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) (CompletionError || cbor.Error)!void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                try send_content_msg_empty(self_.from.ref(), "hover", self_.file_path, self_.row, self_.col);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_completion_items(self_.from.ref(), self_.file_path, self_.row, self_.col, result, false);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_completion_list(self_.from.ref(), self_.file_path, self_.row, self_.col, result);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
        .row = row,
        .col = col,
    };

    lsp.send_request(self.allocator, "textDocument/completion", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    }, handler) catch return error.LspFailed;
}

pub fn symbols(self: *Self, from: tp.pid_ref, file_path: []const u8) (LspError || SymbolInformationError)!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                try send_content_msg_empty(self_.from.ref(), "hover", self_.file_path, 1, 1);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_symbol_items(self_.from.ref(), self_.file_path, result);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
    };

    lsp.send_request(self.allocator, "textDocument/documentSymbol", .{
        .textDocument = .{ .uri = uri },
    }, handler) catch return error.LspFailed;
}

fn send_symbol_items(to: tp.pid_ref, file_path: []const u8, items: []const u8) (SymbolInformationError || cbor.Error)!void {
    var iter = items;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var item: []const u8 = "";
    var node_count: usize = 0;
    while (len > 0) : (len -= 1) {
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&item)))) return error.InvalidSymbolInformation;
        node_count += try send_symbol_information(to, file_path, item, "");
    }
    const logger = log.logger("lsp");
    defer logger.deinit();
    logger.print("LSP accounted {d} symbols", .{node_count});
    return to.send(.{ "cmd", "add_document_symbol_done", .{file_path} }) catch |e| {
        std.log.err("send add_document_symbol_done failed: {t}", .{e});
        return;
    };
}

pub const CompletionListError = error{
    InvalidCompletionListField,
    InvalidCompletionListFieldName,
} || CompletionItemError || TextEditError || cbor.Error;
fn send_completion_list(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) (CompletionListError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var items: []const u8 = "";
    var is_incomplete: bool = false;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidCompletionListFieldName;
        if (std.mem.eql(u8, field_name, "items")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&items)))) return error.InvalidCompletionListField;
        } else if (std.mem.eql(u8, field_name, "isIncomplete")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&is_incomplete)))) return error.InvalidCompletionListField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return send_completion_items(to, file_path, row, col, items, is_incomplete);
}

pub const CompletionItemError = error{
    InvalidCompletionItem,
    InvalidCompletionItemField,
    InvalidCompletionItemFieldName,
} || TextEditError || cbor.Error;
fn send_completion_items(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, items: []const u8, is_incomplete: bool) (CompletionItemError || cbor.Error)!void {
    var iter = items;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var item: []const u8 = "";
    while (len > 0) : (len -= 1) {
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&item)))) return error.InvalidCompletionItem;
        try send_completion_item(to, file_path, row, col, item, if (len > 1) true else is_incomplete);
    }
    return to.send(.{ "cmd", "add_completion_done", .{ file_path, row, col } }) catch |e| {
        std.log.err("send add_completion_done failed: {t}", .{e});
    };
}

fn invalid_symbol_information_field(field: []const u8) error{InvalidSymbolInformationField} {
    std.log.err("invalid symbol information field '{s}'", .{field});
    return error.InvalidSymbolInformationField;
}

pub const SymbolInformationError = error{
    InvalidSymbolInformation,
    InvalidSymbolInformationField,
    InvalidTargetURI,
} || LocationLinkError || cbor.Error;
fn send_symbol_information(to: tp.pid_ref, file_path: []const u8, item: []const u8, parent_name: []const u8) SymbolInformationError!usize {
    var name: []const u8 = "";
    var detail: ?[]const u8 = "";
    var kind: usize = 0;
    var tags: [32]usize = undefined;
    var deprecated: ?bool = false;
    var range: Range = undefined;
    var selectionRange: Range = undefined;
    var location: ?Location = null;
    var containerName: ?[]const u8 = "";
    var len_tags_: usize = 0;
    var descendant_count: usize = 0;
    var symbolKind: SymbolType = undefined;
    const logger_t = log.logger("lsp");
    defer logger_t.deinit();
    var iter = item;
    var len = cbor.decodeMapHeader(&iter) catch return 0;
    tags[0] = 0;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidSymbolInformation;
        if (std.mem.eql(u8, field_name, "name")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&name)))) return invalid_symbol_information_field("name");
        } else if (std.mem.eql(u8, field_name, "detail")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&detail)))) return invalid_symbol_information_field("detail");
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return invalid_symbol_information_field("kind");
        } else if (std.mem.eql(u8, field_name, "tags")) {
            var len_ = cbor.decodeArrayHeader(&iter) catch return 0;
            var idx: usize = 0;
            var this_tag: usize = undefined;
            len_tags_ = len_;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&this_tag)))) return invalid_symbol_information_field("tags");
                tags[idx] = this_tag;
                idx += 1;
            }
            try cbor.skipValue(&iter);
        } else if (std.mem.eql(u8, field_name, "deprecated")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&deprecated)))) return invalid_symbol_information_field("deprecated");
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return invalid_symbol_information_field("range");
            range = try read_range(range_);
            symbolKind = SymbolType.document_symbol;
        } else if (std.mem.eql(u8, field_name, "selectionRange")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return invalid_symbol_information_field("selectionRange");
            selectionRange = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "children")) {
            var len_ = cbor.decodeArrayHeader(&iter) catch return 0;
            var descendant: []const u8 = "";
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&descendant)))) return error.InvalidSymbolInformationField;
                descendant_count += try send_symbol_information(to, file_path, descendant, name);
            }
        } else if (std.mem.eql(u8, field_name, "location")) {} else if (std.mem.eql(u8, field_name, "location")) {
            var location_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&location_)))) return invalid_symbol_information_field("selectionRange");
            location = try read_locationlink(iter);
            symbolKind = SymbolType.document_symbol;
        } else if (std.mem.eql(u8, field_name, "containerName")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&containerName)))) return invalid_symbol_information_field("containerName");
        } else {
            try cbor.skipValue(&iter);
        }
    }

    try switch (symbolKind) {
        SymbolType.document_symbol => {
            to.send(.{ "cmd", "add_document_symbol", .{
                file_path,
                name,
                parent_name,
                kind,
                range.start.line,
                range.start.character,
                range.end.line,
                range.end.character,
                tags[0..len_tags_],
                selectionRange.start.line,
                selectionRange.start.character,
                selectionRange.end.line,
                selectionRange.end.character,
                deprecated,
                detail,
            } }) catch |e| {
                std.log.err("send add_document_symbol failed: {t}", .{e});
                return 0;
            };
            return descendant_count + 1;
        },
        SymbolType.symbol_information => {
            var fp = file_path;
            if (location) |location_| {
                if (location_.targetUri == null or location_.targetRange == null) return error.InvalidSymbolInformationField;
                var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                var file_path_ = try file_uri_to_path(location_.targetUri.?, &file_path_buf);
                if (builtin.os.tag == .windows) {
                    if (file_path_[0] == '/') file_path_ = file_path_[1..];
                    for (file_path_, 0..) |c, i| if (c == '/') {
                        file_path_[i] = '\\';
                    };
                }
                fp = file_path_;
                to.send(.{ "cmd", "add_symbol_information", .{ fp, name, parent_name, kind, location_.targetRange.?.start.line, location_.targetRange.?.start.character, location_.targetRange.?.end.line, location_.targetRange.?.end.character, tags[0..len_tags_], location_.targetSelectionRange.?.start.line, location_.targetSelectionRange.?.start.character, location_.targetSelectionRange.?.end.line, location_.targetSelectionRange.?.end.character, deprecated, location_.targetUri } }) catch |e| {
                    std.log.err("send add_symbol_information failed: {t}", .{e});
                    return 0;
                };
                return 1;
            } else {
                return error.InvalidSymbolInformationField;
            }
        },
    };
}

fn invalid_completion_item_field(field: []const u8) error{InvalidCompletionItemField} {
    std.log.err("invalid completion item field '{s}'", .{field});
    return error.InvalidCompletionItemField;
}

fn send_completion_item(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, item: []const u8, is_incomplete: bool) CompletionItemError!void {
    var label: []const u8 = "";
    var label_detail: []const u8 = "";
    var label_description: []const u8 = "";
    var kind: usize = 0;
    var detail: []const u8 = "";
    var documentation: []const u8 = "";
    var documentation_kind: []const u8 = "";
    var sortText: []const u8 = "";
    var insertText: []const u8 = "";
    var insertTextFormat: usize = 0;
    var textEdit: TextEdit = .{};
    var additionalTextEdits: [32]TextEdit = undefined;
    var additionalTextEdits_len: usize = 0;

    var iter = item;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidCompletionItemFieldName;
        if (std.mem.eql(u8, field_name, "label")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&label)))) return invalid_completion_item_field("label");
        } else if (std.mem.eql(u8, field_name, "labelDetails")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return invalid_completion_item_field("labelDetails");
                if (std.mem.eql(u8, field_name, "detail")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_detail)))) return invalid_completion_item_field("labelDetails.detail");
                } else if (std.mem.eql(u8, field_name, "description")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_description)))) return invalid_completion_item_field("labelDetails.description");
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return invalid_completion_item_field("kind");
        } else if (std.mem.eql(u8, field_name, "detail")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&detail)))) return invalid_completion_item_field("detail");
        } else if (std.mem.eql(u8, field_name, "documentation")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return invalid_completion_item_field("documentation");
                if (std.mem.eql(u8, field_name, "kind")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&documentation_kind)))) return invalid_completion_item_field("documentation.kind");
                } else if (std.mem.eql(u8, field_name, "value")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&documentation)))) return invalid_completion_item_field("documentation.value");
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "insertText")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&insertText)))) return invalid_completion_item_field("insertText");
        } else if (std.mem.eql(u8, field_name, "sortText")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&sortText)))) return invalid_completion_item_field("sortText");
        } else if (std.mem.eql(u8, field_name, "insertTextFormat")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&insertTextFormat)))) return invalid_completion_item_field("insertTextFormat");
        } else if (std.mem.eql(u8, field_name, "textEdit")) {
            textEdit = try read_textEdit(&iter);
        } else if (std.mem.eql(u8, field_name, "additionalTextEdits")) {
            var len_ = cbor.decodeArrayHeader(&iter) catch return;
            additionalTextEdits_len = len_;
            var idx: usize = 0;
            while (len_ > 0) : (len_ -= 1) {
                additionalTextEdits[idx] = try read_textEdit(&iter);
                idx += 1;
            }
            try cbor.skipValue(&iter);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const insert = textEdit.insert orelse Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    const replace = textEdit.replace orelse Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    return to.send(.{
        "cmd", "add_completion", .{
            file_path,
            row,
            col,
            is_incomplete,
            label,
            label_detail,
            label_description,
            kind,
            detail,
            documentation,
            documentation_kind,
            sortText,
            insertText,
            insertTextFormat,
            textEdit.newText,
            insert.start.line,
            insert.start.character,
            insert.end.line,
            insert.end.character,
            replace.start.line,
            replace.start.character,
            replace.end.line,
            replace.end.character,
            additionalTextEdits[0..additionalTextEdits_len],
        },
    }) catch |e| {
        std.log.err("send add_completion failed: {t}", .{e});
    };
}

fn invalid_text_edit_field(field: []const u8) error{InvalidTextEditField} {
    std.log.err("invalid text edit field '{s}'", .{field});
    return error.InvalidTextEditField;
}

const TextEditError = error{
    InvalidTextEdit,
    InvalidTextEditField,
    InvalidTextEditFieldName,
} || RangeError || cbor.Error;
fn read_textEdit(iter: *[]const u8) TextEditError!TextEdit {
    var field_name: []const u8 = undefined;
    var newText: []const u8 = "";
    var insert: ?Range = null;
    var replace: ?Range = null;
    var len_ = cbor.decodeMapHeader(iter) catch return invalid_text_edit_field("textEdit");
    while (len_ > 0) : (len_ -= 1) {
        if (!(try cbor.matchString(iter, &field_name))) return invalid_text_edit_field("textEdit");
        if (std.mem.eql(u8, field_name, "newText")) {
            if (!(try cbor.matchValue(iter, cbor.extract(&newText)))) return invalid_text_edit_field("textEdit.newText");
        } else if (std.mem.eql(u8, field_name, "insert")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range_)))) return invalid_text_edit_field("textEdit.insert");
            insert = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "replace") or std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range_)))) return invalid_text_edit_field("textEdit.replace");
            replace = try read_range(range_);
        } else {
            try cbor.skipValue(iter);
        }
    }
    return .{ .newText = newText, .insert = insert, .replace = replace };
}

const TextEdit = struct {
    newText: []const u8 = &.{},
    insert: ?Range = null,
    replace: ?Range = null,
};

const Rename = struct {
    uri: []const u8,
    new_text: []const u8,
    range: Range,
};

pub fn rename_symbol(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspError || GetLineOfFileError)!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            const allocator = std.heap.c_allocator;
            var result: []const u8 = undefined;
            // buffer the renames in order to send as a single, atomic message
            var renames = std.array_list.Managed(Rename).init(allocator);
            defer renames.deinit();

            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
                    try decode_rename_symbol_map(result, &renames);
                    // write the renames message manually since there doesn't appear to be an array helper
                    var msg_buf: std.Io.Writer.Allocating = .init(allocator);
                    defer msg_buf.deinit();
                    const w = &msg_buf.writer;
                    try cbor.writeArrayHeader(w, 3);
                    try cbor.writeValue(w, "cmd");
                    try cbor.writeValue(w, "rename_symbol_item");
                    try cbor.writeArrayHeader(w, renames.items.len);
                    for (renames.items) |rename| {
                        var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        var file_path_ = try file_uri_to_path(rename.uri, &file_path_buf);
                        if (builtin.os.tag == .windows) {
                            if (file_path_[0] == '/') file_path_ = file_path_[1..];
                            for (file_path_, 0..) |c, i| if (c == '/') {
                                file_path_[i] = '\\';
                            };
                        }
                        const line = try get_line_of_file(allocator, self_.file_path, rename.range.start.line);
                        try cbor.writeValue(w, .{
                            file_path_,
                            rename.range.start.line,
                            rename.range.start.character,
                            rename.range.end.line,
                            rename.range.end.character,
                            rename.new_text,
                            line,
                        });
                    }
                    self_.from.send_raw(.{ .buf = msg_buf.written() }) catch return error.ClientFailed;
                }
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
    };

    lsp.send_request(self.allocator, "textDocument/rename", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
        .newName = "PLACEHOLDER",
    }, handler) catch return error.LspFailed;
}

// decode a WorkspaceEdit record which may have shape {"changes": {}} or {"documentChanges": []}
// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit
fn decode_rename_symbol_map(result: []const u8, renames: *std.array_list.Managed(Rename)) DocumentChangesError!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidDocumentChanges;
    var changes: []const u8 = "";
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDocumentChangesFieldName;
        if (std.mem.eql(u8, field_name, "changes")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidDocumentChangesField;
            try decode_rename_symbol_changes(changes, renames);
            return;
        } else if (std.mem.eql(u8, field_name, "documentChanges")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidDocumentChangesField;
            try decode_rename_symbol_doc_changes(changes, renames);
            return;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return error.InvalidDocumentChanges;
}

fn decode_rename_symbol_changes(changes: []const u8, renames: *std.array_list.Managed(Rename)) TextEditError!void {
    var iter = changes;
    var files_len = cbor.decodeMapHeader(&iter) catch return error.InvalidTextEdit;
    while (files_len > 0) : (files_len -= 1) {
        var file_uri: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidTextEdit;
        try decode_rename_symbol_item(file_uri, &iter, renames);
    }
}

const DocumentChangesError = error{
    InvalidDocumentChanges,
    InvalidDocumentChangesField,
    InvalidDocumentChangesFieldName,
} || TextEditError || cbor.Error;
fn decode_rename_symbol_doc_changes(changes: []const u8, renames: *std.array_list.Managed(Rename)) DocumentChangesError!void {
    var iter = changes;
    var changes_len = cbor.decodeArrayHeader(&iter) catch return error.InvalidDocumentChanges;
    while (changes_len > 0) : (changes_len -= 1) {
        var dc_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidDocumentChanges;
        var file_uri: []const u8 = "";
        while (dc_fields_len > 0) : (dc_fields_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDocumentChangesFieldName;
            if (std.mem.eql(u8, field_name, "textDocument")) {
                var td_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidDocumentChangesField;
                while (td_fields_len > 0) : (td_fields_len -= 1) {
                    var td_field_name: []const u8 = undefined;
                    if (!(try cbor.matchString(&iter, &td_field_name))) return error.InvalidDocumentChangesField;
                    if (std.mem.eql(u8, td_field_name, "uri")) {
                        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidDocumentChangesField;
                    } else try cbor.skipValue(&iter); // skip "version": 1
                }
            } else if (std.mem.eql(u8, field_name, "edits")) {
                if (file_uri.len == 0) return error.InvalidDocumentChangesField;
                try decode_rename_symbol_item(file_uri, &iter, renames);
            }
        }
    }
}

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit
fn decode_rename_symbol_item(file_uri: []const u8, iter: *[]const u8, renames: *std.array_list.Managed(Rename)) TextEditError!void {
    var text_edits_len = cbor.decodeArrayHeader(iter) catch return error.InvalidTextEditField;
    while (text_edits_len > 0) : (text_edits_len -= 1) {
        var m_range: ?Range = null;
        var new_text: []const u8 = "";
        var edits_len = cbor.decodeMapHeader(iter) catch return error.InvalidTextEditField;
        while (edits_len > 0) : (edits_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(iter, &field_name))) return error.InvalidTextEditField;
            if (std.mem.eql(u8, field_name, "range")) {
                var range: []const u8 = undefined;
                if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range)))) return error.InvalidTextEditField;
                m_range = try read_range(range);
            } else if (std.mem.eql(u8, field_name, "newText")) {
                if (!(try cbor.matchString(iter, &new_text))) return error.InvalidTextEditField;
            } else {
                try cbor.skipValue(iter);
            }
        }

        const range = m_range orelse return error.InvalidTextEditField;
        try renames.append(.{ .uri = file_uri, .range = range, .new_text = new_text });
    }
}

pub fn hover(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    // self.logger_lsp.print("fetching hover information...", .{});

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,
        row: usize,
        col: usize,

        pub fn deinit(self_: *@This()) void {
            self_.from.deinit();
            std.heap.c_allocator.free(self_.file_path);
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                try send_content_msg_empty(self_.from.ref(), "hover", self_.file_path, self_.row, self_.col);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&result) })) {
                try send_hover(self_.from.ref(), self_.file_path, self_.row, self_.col, result);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
        .row = row,
        .col = col,
    };

    lsp.send_request(self.allocator, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    }, handler) catch return error.LspFailed;
}

const HoverError = error{
    InvalidHover,
    InvalidHoverField,
    InvalidHoverFieldName,
} || HoverContentsError || RangeError || cbor.Error;

fn send_hover(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) HoverError!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var contents: []const u8 = "";
    var range: ?Range = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidHoverFieldName;
        if (std.mem.eql(u8, field_name, "contents")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&contents)))) return error.InvalidHoverField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidHoverField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (contents.len > 0)
        return send_contents(to, "hover", file_path, row, col, contents, range);
}

const HoverContentsError = error{
    InvalidHoverContents,
    InvalidHoverContentsField,
    InvalidHoverContentsFieldName,
} || cbor.Error;

fn send_contents(
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    result: []const u8,
    range: ?Range,
) HoverContentsError!void {
    var iter = result;
    var kind: []const u8 = "plaintext";
    var value: []const u8 = "";
    if (try cbor.matchValue(&iter, cbor.extract(&value)))
        return send_content_msg(to, tag, file_path, row, col, kind, value, range);

    var list_size = cbor.decodeArrayHeader(&iter) catch blk: {
        iter = result;
        break :blk 1;
    };

    while (list_size > 0) : (list_size -= 1) {
        var len = cbor.decodeMapHeader(&iter) catch return;
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidHoverContentsFieldName;
            if (std.mem.eql(u8, field_name, "kind")) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return error.InvalidHoverContentsField;
            } else if (std.mem.eql(u8, field_name, "value")) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidHoverContentsField;
            } else {
                try cbor.skipValue(&iter);
            }
        }
        try send_content_msg(to, tag, file_path, row, col, kind, value, range);
    }
}

fn send_content_msg(
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    kind: []const u8,
    content: []const u8,
    range: ?Range,
) error{}!void {
    const r = range orelse Range{
        .start = .{ .line = row, .character = col },
        .end = .{ .line = row, .character = col },
    };
    to.send(.{ tag, file_path, kind, content, r.start.line, r.start.character, r.end.line, r.end.character }) catch |e| {
        std.log.err("send {s} (in send_content_msg) failed: {t}", .{ tag, e });
    };
}

fn send_content_msg_empty(to: tp.pid_ref, tag: []const u8, file_path: []const u8, row: usize, col: usize) error{}!void {
    return send_content_msg(to, tag, file_path, row, col, "plaintext", "", null);
}

pub fn publish_diagnostics(self: *Self, to: tp.pid_ref, params_cb: []const u8) DiagnosticError!void {
    var uri: ?[]const u8 = null;
    var diagnostics: []const u8 = &.{};
    var iter = params_cb;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDiagnostic;
        if (std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&uri)))) return error.InvalidDiagnosticField;
        } else if (std.mem.eql(u8, field_name, "diagnostics")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostics)))) return error.InvalidDiagnosticField;
        } else {
            try cbor.skipValue(&iter);
        }
    }

    if (uri == null) return error.InvalidDiagnosticField;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try file_uri_to_path(uri.?, &file_path_buf);

    self.send_clear_diagnostics(to, file_path);

    iter = diagnostics;
    len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic))) {
            try self.send_diagnostic(to, file_path, diagnostic);
        } else return error.InvalidDiagnosticField;
    }
}

pub const DiagnosticError = error{
    InvalidTargetURI,
    InvalidDiagnostic,
    InvalidDiagnosticFieldName,
    InvalidDiagnosticField,
} || RangeError || cbor.Error;
fn send_diagnostic(_: *Self, to: tp.pid_ref, file_path: []const u8, diagnostic: []const u8) DiagnosticError!void {
    var source: []const u8 = "unknown";
    var code: []const u8 = "none";
    var code_int: i64 = 0;
    var code_int_buf: [64]u8 = undefined;
    var message: []const u8 = "empty";
    var severity: i64 = 1;
    var range: ?Range = null;
    var iter = diagnostic;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDiagnosticFieldName;
        if (std.mem.eql(u8, field_name, "source") or std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&source)))) return error.InvalidDiagnosticField;
        } else if (std.mem.eql(u8, field_name, "code")) {
            if (try cbor.matchValue(&iter, cbor.extract(&code_int))) {
                var writer = std.Io.Writer.fixed(&code_int_buf);
                try writer.print("{}", .{code_int});
                code = writer.buffered();
            } else if (!(try cbor.matchValue(&iter, cbor.extract(&code))))
                return error.InvalidDiagnosticField;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidDiagnosticField;
        } else if (std.mem.eql(u8, field_name, "severity")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&severity)))) return error.InvalidDiagnosticField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidDiagnosticField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (range == null) return error.InvalidDiagnostic;
    to.send(.{ "cmd", "add_diagnostic", .{
        file_path,
        source,
        code,
        message,
        severity,
        range.?.start.line,
        range.?.start.character,
        range.?.end.line,
        range.?.end.character,
    } }) catch |e| {
        std.log.err("send add_diagnostic failed: {t}", .{e});
    };
}

fn send_clear_diagnostics(_: *Self, to: tp.pid_ref, file_path: []const u8) void {
    to.send(.{ "cmd", "clear_diagnostics", .{file_path} }) catch |e| {
        std.log.err("send clear_diagnostics failed: {t}", .{e});
    };
}

const SymbolType = enum { document_symbol, symbol_information };

const DocumentSymbol = struct {
    name: []const u8 = &.{},
    detail: ?[]const u8 = &.{},
    kind: usize,
    tags: ?[]const usize = &.{},
    deprecated: ?bool = false,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = &.{},
    parent_name: []const u8 = &.{},
};

// Location is a subset of LocationLink
const Location = LocationLink;

const LocationLink = struct {
    targetUri: ?[]const u8 = null,
    targetRange: ?Range = null,
    targetSelectionRange: ?Range = null,
};
const LocationLinkError = error{
    InvalidLocationLink,
    InvalidLocationLinkFieldName,
    InvalidLocationLinkField,
} || RangeError || cbor.Error;
fn read_locationlink(location_link: []const u8) LocationLinkError!LocationLink {
    var iter = location_link;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidLocationLinkFieldName;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var uri_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&uri_)))) return error.InvalidLocationLinkField;
            targetUri = uri_;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidLocationLinkField;
            targetRange = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidLocationLinkField;
            targetSelectionRange = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return .{ .targetUri = targetUri, .targetRange = targetRange, .targetSelectionRange = targetSelectionRange };
}

const Range = struct { start: Position, end: Position };
const RangeError = error{
    InvalidRange,
    InvalidRangeFieldName,
    InvalidRangeField,
} || PositionError || cbor.Error;
fn read_range(range: []const u8) RangeError!Range {
    var iter = range;
    var start: ?Position = null;
    var end: ?Position = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidRangeFieldName;
        if (std.mem.eql(u8, field_name, "start")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidRangeField;
            start = try read_position(position);
        } else if (std.mem.eql(u8, field_name, "end")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidRangeField;
            end = try read_position(position);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (start == null or end == null) return error.InvalidRange;
    return .{ .start = start.?, .end = end.? };
}

const Position = struct { line: usize, character: usize };
const PositionError = error{
    InvalidPosition,
    InvalidPositionFieldName,
    InvalidPositionField,
} || cbor.Error;
fn read_position(position: []const u8) PositionError!Position {
    var iter = position;
    var line: ?usize = 0;
    var character: ?usize = 0;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidPositionFieldName;
        if (std.mem.eql(u8, field_name, "line")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&line)))) return error.InvalidPositionField;
        } else if (std.mem.eql(u8, field_name, "character")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&character)))) return error.InvalidPositionField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (line == null or character == null) return error.InvalidPosition;
    return .{ .line = line.?, .character = character.? };
}

pub fn show_message(self: *Self, params_cb: []const u8) !void {
    return self.show_or_log_message(.show, params_cb);
}

pub fn log_message(self: *Self, params_cb: []const u8) !void {
    return self.show_or_log_message(.log, params_cb);
}

pub const LogMessageError = error{
    InvalidLogMessage,
    InvalidLogMessageField,
    InvalidLogMessageFieldName,
} || cbor.Error;
fn show_or_log_message(self: *Self, operation: enum { show, log }, params_cb: []const u8) LogMessageError!void {
    if (!tp.env.get().is("lsp_verbose")) return;
    var type_: i32 = 0;
    var message: ?[]const u8 = null;
    var iter = params_cb;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidLogMessage;
        if (std.mem.eql(u8, field_name, "type")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&type_)))) return error.InvalidLogMessageField;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidLogMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const msg = message orelse return;
    if (type_ <= 2)
        self.logger_lsp.err_msg("lsp", msg)
    else
        self.logger_lsp.print("{t}: {s}", .{ operation, msg });
}

pub fn show_notification(self: *Self, method: []const u8, params_cb: []const u8) !void {
    if (!tp.env.get().is("lsp_verbose")) return;
    const params = try cbor.toJsonAlloc(self.allocator, params_cb);
    defer self.allocator.free(params);
    self.logger_lsp.print("LSP notification: {s} -> {s}", .{ method, params });
}

pub fn register_capability(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) LspError!void {
    _ = params_cb;
    return LSP.send_response(self.allocator, from, cbor_id, null) catch error.LspFailed;
}

pub fn workDoneProgress_create(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) LspError!void {
    _ = params_cb;
    return LSP.send_response(self.allocator, from, cbor_id, null) catch error.LspFailed;
}

pub fn unsupported_lsp_request(self: *Self, from: tp.pid_ref, cbor_id: []const u8, method: []const u8) LspError!void {
    return LSP.send_error_response(self.allocator, from, cbor_id, LSP.ErrorCode.MethodNotFound, method) catch error.LspFailed;
}

fn send_lsp_init_request(self: *Self, from: tp.pid_ref, lsp: *const LSP, project_path: []const u8, project_basename: []const u8, project_uri: []const u8, language_server: []const u8, language_server_options: []const u8) !void {
    const handler: struct {
        from: tp.pid,
        language_server: []const u8,
        lsp: LSP,
        project: *Self,
        project_path: []const u8,

        pub fn deinit(self_: *@This()) void {
            self_.from.deinit();
            self_.lsp.pid.deinit();
            std.heap.c_allocator.free(self_.language_server);
            std.heap.c_allocator.free(self_.project_path);
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            self_.lsp.send_notification("initialized", .{}) catch return error.LspFailed;
            if (self_.lsp.pid.expired()) return error.LspFailed;
            self_.project.logger_lsp.print("initialized LSP: {f}", .{fmt_lsp_name_func(self_.language_server)});

            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_lsp_init_response(self_.from.ref(), self_.project_path, self_.language_server, result);
            }
        }
    } = .{
        .from = from.clone(),
        .language_server = try std.heap.c_allocator.dupe(u8, language_server),
        .lsp = .{
            .allocator = lsp.allocator,
            .pid = lsp.pid.clone(),
        },
        .project = self,
        .project_path = try std.heap.c_allocator.dupe(u8, project_path),
    };

    const version = if (root.version.len > 0 and root.version[0] == 'v') root.version[1..] else root.version;
    const initializationOptions: struct {
        pub fn cborEncode(ctx: @This(), writer: *std.Io.Writer) std.io.Writer.Error!void {
            if (ctx.language_server_options.len == 0) {
                try cbor.writeValue(writer, null);
                return;
            }
            const toCbor = cbor.fromJsonAlloc(ctx.self.allocator, ctx.language_server_options) catch {
                try cbor.writeValue(writer, null);
                ctx.self.logger_lsp.print_err("init", "ignored invalid JSON in LSP initialization options", .{});
                return;
            };
            defer ctx.self.allocator.free(toCbor);

            writer.writeAll(toCbor) catch return error.WriteFailed;
        }
        self: *Self,
        language_server_options: []const u8,
    } = .{ .self = self, .language_server_options = language_server_options };

    try lsp.send_request(self.allocator, "initialize", .{
        .initializationOptions = initializationOptions,
        .processId = if (builtin.os.tag == .linux) std.os.linux.getpid() else null,
        .rootPath = project_path,
        .rootUri = project_uri,
        .workspaceFolders = .{
            .{
                .uri = project_uri,
                .name = project_basename,
            },
        },
        .trace = "verbose",
        .locale = "en-us",
        .clientInfo = .{
            .name = root.application_name,
            .version = version,
        },
        .capabilities = .{
            .workspace = .{
                .applyEdit = true,
                .workspaceEdit = .{
                    .documentChanges = true,
                    .resourceOperations = .{
                        "create",
                        "rename",
                        "delete",
                    },
                    .failureHandling = "textOnlyTransactional",
                    .normalizesLineEndings = true,
                    .changeAnnotationSupport = .{ .groupsOnLabel = true },
                },
                // .configuration = true,
                .didChangeWatchedFiles = .{
                    .dynamicRegistration = true,
                    .relativePatternSupport = true,
                },
                .symbol = .{
                    .dynamicRegistration = true,
                    .symbolKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 },
                    },
                    .tagSupport = .{ .valueSet = .{1} },
                    .resolveSupport = .{ .properties = .{"location.range"} },
                },
                .codeLens = .{ .refreshSupport = false },
                .executeCommand = .{ .dynamicRegistration = true },
                // .didChangeConfiguration = .{ .dynamicRegistration = true },
                .workspaceFolders = true,
                .semanticTokens = .{ .refreshSupport = false },
                .fileOperations = .{
                    .dynamicRegistration = true,
                    .didCreate = true,
                    .didRename = true,
                    .didDelete = true,
                    .willCreate = true,
                    .willRename = true,
                    .willDelete = true,
                },
                .inlineValue = .{ .refreshSupport = false },
                .inlayHint = .{ .refreshSupport = false },
                .diagnostics = .{ .refreshSupport = true },
            },
            .textDocument = .{
                .publishDiagnostics = .{
                    .relatedInformation = true,
                    .versionSupport = false,
                    .tagSupport = .{ .valueSet = .{ 1, 2 } },
                    .codeDescriptionSupport = true,
                    .dataSupport = true,
                },
                .synchronization = .{
                    .dynamicRegistration = true,
                    .willSave = true,
                    .willSaveWaitUntil = true,
                    .didSave = true,
                },
                .completion = .{
                    .dynamicRegistration = true,
                    .contextSupport = true,
                    .completionItem = .{
                        .snippetSupport = true,
                        .commitCharactersSupport = true,
                        .documentationFormat = .{
                            // "markdown",
                            "plaintext",
                        },
                        .deprecatedSupport = true,
                        .preselectSupport = true,
                        .tagSupport = .{ .valueSet = .{1} },
                        .insertReplaceSupport = true,
                        .resolveSupport = .{ .properties = .{
                            "documentation",
                            "detail",
                            "additionalTextEdits",
                        } },
                        .insertTextModeSupport = .{ .valueSet = .{ 1, 2 } },
                        .labelDetailsSupport = true,
                    },
                    .insertTextMode = 2,
                    .completionItemKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 },
                    },
                    .completionList = .{ .itemDefaults = .{
                        "commitCharacters",
                        "editRange",
                        "insertTextFormat",
                        "insertTextMode",
                    } },
                },
                .hover = .{
                    .dynamicRegistration = true,
                    .contentFormat = .{
                        // "markdown",
                        "plaintext",
                    },
                },
                .signatureHelp = .{
                    .dynamicRegistration = true,
                    .signatureInformation = .{
                        .documentationFormat = .{
                            // "markdown",
                            "plaintext",
                        },
                        .parameterInformation = .{ .labelOffsetSupport = true },
                        .activeParameterSupport = true,
                    },
                    .contextSupport = true,
                },
                .definition = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .references = .{ .dynamicRegistration = true },
                .documentHighlight = .{ .dynamicRegistration = true },
                .documentSymbol = .{
                    .dynamicRegistration = true,
                    .symbolKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 },
                    },
                    .hierarchicalDocumentSymbolSupport = true,
                    .tagSupport = .{ .valueSet = .{1} },
                    .labelSupport = true,
                },
                .codeAction = .{
                    .dynamicRegistration = true,
                    .isPreferredSupport = true,
                    .disabledSupport = true,
                    .dataSupport = true,
                    .resolveSupport = .{ .properties = .{"edit"} },
                    .codeActionLiteralSupport = .{
                        .codeActionKind = .{
                            .valueSet = .{
                                "",
                                "quickfix",
                                "refactor",
                                "refactor.extract",
                                "refactor.inline",
                                "refactor.rewrite",
                                "source",
                                "source.organizeImports",
                            },
                        },
                    },
                    .honorsChangeAnnotations = false,
                },
                .codeLens = .{ .dynamicRegistration = true },
                .formatting = .{ .dynamicRegistration = true },
                .rangeFormatting = .{ .dynamicRegistration = true },
                .onTypeFormatting = .{ .dynamicRegistration = true },
                .rename = .{
                    .dynamicRegistration = true,
                    .prepareSupport = true,
                    .prepareSupportDefaultBehavior = 1,
                    .honorsChangeAnnotations = true,
                },
                .documentLink = .{
                    .dynamicRegistration = true,
                    .tooltipSupport = true,
                },
                .typeDefinition = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .implementation = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .colorProvider = .{ .dynamicRegistration = true },
                .foldingRange = .{
                    .dynamicRegistration = true,
                    .rangeLimit = 5000,
                    .lineFoldingOnly = true,
                    .foldingRangeKind = .{ .valueSet = .{ "comment", "imports", "region" } },
                    .foldingRange = .{ .collapsedText = false },
                },
                .declaration = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .selectionRange = .{ .dynamicRegistration = true },
                .callHierarchy = .{ .dynamicRegistration = true },
                .semanticTokens = .{
                    .dynamicRegistration = true,
                    .tokenTypes = .{
                        "namespace",
                        "type",
                        "class",
                        "enum",
                        "interface",
                        "struct",
                        "typeParameter",
                        "parameter",
                        "variable",
                        "property",
                        "enumMember",
                        "event",
                        "function",
                        "method",
                        "macro",
                        "keyword",
                        "modifier",
                        "comment",
                        "string",
                        "number",
                        "regexp",
                        "operator",
                        "decorator",
                    },
                    .tokenModifiers = .{
                        "declaration",
                        "definition",
                        "readonly",
                        "static",
                        "deprecated",
                        "abstract",
                        "async",
                        "modification",
                        "documentation",
                        "defaultLibrary",
                    },
                    .formats = .{"relative"},
                    .requests = .{
                        .range = true,
                        .full = .{ .delta = true },
                    },
                    .multilineTokenSupport = false,
                    .overlappingTokenSupport = false,
                    .serverCancelSupport = true,
                    .augmentsSyntaxTokens = true,
                },
                .linkedEditingRange = .{ .dynamicRegistration = true },
                .typeHierarchy = .{ .dynamicRegistration = true },
                .inlineValue = .{ .dynamicRegistration = true },
                .inlayHint = .{
                    .dynamicRegistration = true,
                    .resolveSupport = .{
                        .properties = .{
                            "tooltip",
                            "textEdits",
                            "label.tooltip",
                            "label.location",
                            "label.command",
                        },
                    },
                },
            },
            .window = .{
                .showMessage = .{
                    .messageActionItem = .{ .additionalPropertiesSupport = true },
                },
                .showDocument = .{ .support = true },
                .workDoneProgress = false,
            },
            .general = .{
                .staleRequestSupport = .{
                    .cancel = true,
                    .retryOnContentModified = .{
                        "textDocument/semanticTokens/full",
                        "textDocument/semanticTokens/range",
                        "textDocument/semanticTokens/full/delta",
                    },
                },
                .regularExpressions = .{
                    .engine = "ECMAScript",
                    .version = "ES2020",
                },
                .markdown = .{
                    .parser = "marked",
                    .version = "1.1.0",
                },
                .positionEncodings = .{"utf-8"},
            },
            .notebookDocument = .{
                .synchronization = .{
                    .dynamicRegistration = true,
                    .executionSummarySupport = true,
                },
            },
        },
    }, handler);
}

fn send_lsp_init_response(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, result: []const u8) (LspInfoError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "capabilities")) {
            try send_lsp_capabilities(to, project_path, language_server, &iter);
        } else {
            try cbor.skipValue(&iter);
        }
    }
}

fn send_lsp_capabilities(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, iter: *[]const u8) (LspInfoError || cbor.Error)!void {
    var len = cbor.decodeMapHeader(iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "completionProvider")) {
            try send_lsp_completionProvider(to, project_path, language_server, iter);
        } else {
            try cbor.skipValue(iter);
        }
    }
}

fn send_lsp_completionProvider(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, iter: *[]const u8) (LspInfoError || cbor.Error)!void {
    var len = cbor.decodeMapHeader(iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "triggerCharacters")) {
            var items: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&items)))) return error.InvalidTriggerCharacters;
            try send_lsp_triggerCharacters(to, project_path, language_server, items);
        } else {
            try cbor.skipValue(iter);
        }
    }
}

fn send_lsp_triggerCharacters(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, items: []const u8) (LspInfoError || cbor.Error)!void {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const w = &writer;
    try cbor.writeArrayHeader(w, 5);
    try cbor.writeValue(w, "PRJ");
    try cbor.writeValue(w, "triggerCharacters");
    try cbor.writeValue(w, project_path);
    try w.writeAll(language_server);
    try w.writeAll(items);
    to.send_raw(.{ .buf = w.buffered() }) catch |e| {
        std.log.err("send triggerCharacters failed: {t}", .{e});
        return;
    };
}

fn fmt_lsp_name_func(bytes: []const u8) std.fmt.Formatter([]const u8, format_lsp_name_func) {
    return .{ .data = bytes };
}

fn format_lsp_name_func(
    bytes: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var iter: []const u8 = bytes;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var first: bool = true;
    while (len > 0) : (len -= 1) {
        var value: []const u8 = undefined;
        if (!(cbor.matchValue(&iter, cbor.extract(&value)) catch return))
            return;
        if (first) first = false else try writer.writeAll(" ");
        try writer.writeAll(value);
    }
}

const eol = '\n';

pub const GetLineOfFileError = (OutOfMemoryError || std.fs.File.OpenError || std.fs.File.ReadError);

fn get_line_of_file(allocator: std.mem.Allocator, file_path: []const u8, line_: usize) GetLineOfFileError![]const u8 {
    const line = line_ + 1;
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    const read_size = try file.readAll(buf);
    if (read_size != @as(@TypeOf(read_size), @intCast(stat.size)))
        @panic("get_line_of_file: buffer underrun");

    var line_count: usize = 1;
    for (0..buf.len) |i| {
        if (line_count == line)
            return get_line(allocator, buf[i..]);
        if (buf[i] == eol) line_count += 1;
    }
    return allocator.dupe(u8, "");
}

pub fn get_line(allocator: std.mem.Allocator, buf: []const u8) ![]const u8 {
    for (0..buf.len) |i| {
        if (buf[i] == eol) return allocator.dupe(u8, buf[0..i]);
    }
    return allocator.dupe(u8, buf);
}

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
    self.walker = walk_tree.start(self.allocator, self.name, walk_tree_entry_callback, walk_tree_done_callback) catch blk: {
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
        self.workspace = try self.allocator.dupe(u8, value);
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
            break :blk (std.fs.cwd().statFile(path) catch break :blk 0).mtime;
        };
        const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(path);
        (try self.pending.addOne(self.allocator)).* = .{
            .path = try self.allocator.dupe(u8, path),
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
            .path = try self.allocator.dupe(u8, path),
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
        .project = self,
        .file_path = try self.allocator.dupe(u8, file_path),
    };
    git.rev_parse(@intFromPtr(request), "HEAD", file_path) catch |e|
        self.logger_git.print_err("rev-parse", "failed: {t}", .{e});
}

pub const VcsIdRequest = struct {
    allocator: std.mem.Allocator,
    project: *Self,
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
        .project = self,
        .file_path = try self.allocator.dupe(u8, file_path),
        .vcs_id = try self.allocator.dupe(u8, vcs_id),
    };
    git.cat_file(@intFromPtr(request), vcs_id) catch |e|
        self.logger_git.print_err("cat-file", "failed: {t}", .{e});
}

pub const VcsContentRequest = struct {
    allocator: std.mem.Allocator,
    project: *Self,
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
    }
}
