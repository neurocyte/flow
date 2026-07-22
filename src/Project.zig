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
const Buffer = @import("Buffer");
const bin_path = @import("bin_path");
const builtin = @import("builtin");

const project_manager = @import("project_manager.zig");
const LSP = @import("LSP.zig");
const LSPClient = @import("LSPClient.zig");
const walk_tree = @import("walk_tree.zig");
const convert_path = LSPClient.convert_path;

allocator: std.mem.Allocator,
name: []const u8,
files: std.ArrayListUnmanaged(File) = .empty,
new_or_modified_files: std.ArrayListUnmanaged(FileVcsStatus) = .empty,
pending: std.ArrayListUnmanaged(File) = .empty,
longest_file_path: usize = 0,
longest_new_or_modified_file_path: usize = 0,
open_time: i64,
language_servers: std.StringHashMap(*LSPClient),
file_language_server_name: std.StringHashMap([]const u8),
lsp_unavailable: std.StringHashMapUnmanaged(void) = .empty,
lsp_commands: std.StringHashMapUnmanaged(LspCommand) = .empty,
lsp_status_subscribers: std.AutoHashMapUnmanaged(usize, tp.pid) = .empty,
tasks: std.ArrayList(Task),
persistent: bool = false,
logger: log.Logger,
logger_lsp: log.Logger,
logger_git: log.Logger,
last_used: i128,
parent: tp.pid,

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
pub const StartLspError = LSPClient.StartLspError;
pub const LspError = LSPClient.LspError;
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

pub const SourceLocation = LSPClient.SourceLocation;

const Task = struct {
    command: []const u8,
    mtime: i64,
};

const State = enum { none, running, done, failed };

pub fn init(allocator: std.mem.Allocator, name: []const u8, parent: tp.pid_ref) OutOfMemoryError!Self {
    const now = root.get_now();
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .open_time = now.toMilliseconds(),
        .language_servers = std.StringHashMap(*LSPClient).init(allocator),
        .file_language_server_name = std.StringHashMap([]const u8).init(allocator),
        .tasks = .empty,
        .logger = log.logger("project"),
        .logger_lsp = log.logger("lsp"),
        .logger_git = log.logger("git"),
        .last_used = @as(i128, now.toNanoseconds()),
        .parent = parent.clone(),
    };
}

pub fn deinit(self: *Self) void {
    self.parent.deinit();
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
        p.value_ptr.*.deinit();
    }
    var i_unavail = self.lsp_unavailable.iterator();
    while (i_unavail.next()) |p| self.allocator.free(p.key_ptr.*);
    self.lsp_unavailable.deinit(self.allocator);
    var i_commands = self.lsp_commands.iterator();
    while (i_commands.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        self.allocator.free(p.value_ptr.language_server);
        self.allocator.free(p.value_ptr.language_server_options);
    }
    self.lsp_commands.deinit(self.allocator);
    var i_subs = self.lsp_status_subscribers.valueIterator();
    while (i_subs.next()) |sub| sub.deinit();
    self.lsp_status_subscribers.deinit(self.allocator);
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

pub fn get_existing_lsp_client(self: *Self, lsp_name: []const u8) ?*LSPClient {
    const client = self.language_servers.get(lsp_name) orelse return null;
    return if (client.expired()) null else client;
}

pub fn evict_lsp_client(self: *Self, lsp_name: []const u8) void {
    if (self.language_servers.fetchRemove(lsp_name)) |kv| {
        self.allocator.free(kv.key);
        kv.value.deinit();
    }
}

pub fn handle_lsp_terminated(self: *Self, from: tp.pid_ref, lsp_name: []const u8) StartLspError!void {
    // ignore the termination of a client that has already been superseded
    if (self.language_servers.get(lsp_name)) |client|
        if (!client.expired() and client.process_instance_id() != from.instance_id())
            return;
    self.notify_lsp_status(lsp_name, .crashed);
    if (self.is_lsp_unavailable(lsp_name)) return;
    _ = try self.restart_lsp_client(lsp_name);
    self.logger_lsp.print("restarted '{s}'", .{lsp_name});
}

pub fn handle_lsp_not_found(self: *Self, lsp_name: []const u8) void {
    self.mark_lsp_unavailable(lsp_name);
    self.notify_lsp_status(lsp_name, .not_found);
    self.logger_lsp.print("'{s}' executable not found", .{lsp_name});
}

pub const LspStatus = enum { starting, running, not_found, crashed, unavailable };

pub fn add_lsp_status_subscriber(self: *Self, subscriber: tp.pid_ref) void {
    const gop = self.lsp_status_subscribers.getOrPut(self.allocator, subscriber.instance_id()) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = subscriber.clone();
    self.replay_lsp_status(subscriber);
}

pub fn remove_lsp_status_subscriber(self: *Self, subscriber: tp.pid_ref) void {
    if (self.lsp_status_subscribers.fetchRemove(subscriber.instance_id())) |kv| {
        var pid = kv.value;
        pid.deinit();
    }
}

fn notify_lsp_status(self: *Self, lsp_name: []const u8, status: LspStatus) void {
    var i = self.lsp_status_subscribers.valueIterator();
    while (i.next()) |sub| sub.send(.{ "lsp_status", self.name, lsp_name, status }) catch {};
}

fn replay_lsp_status(self: *Self, subscriber: tp.pid_ref) void {
    var i = self.lsp_commands.iterator();
    while (i.next()) |p| {
        const lsp_name = p.key_ptr.*;
        const status: LspStatus = if (self.is_lsp_unavailable(lsp_name))
            .not_found
        else if (self.get_existing_lsp_client(lsp_name) != null)
            .running
        else
            .crashed;
        subscriber.send(.{ "lsp_status", self.name, lsp_name, status }) catch {};
    }
}

fn check_lsp_available(self: *Self, lsp_name: []const u8) error{LspFailed}!void {
    if (bin_path.can_execute(self.allocator, lsp_name)) return;
    self.handle_lsp_not_found(lsp_name);
    return error.LspFailed;
}

const LspCommand = struct {
    language_server: []const u8,
    language_server_options: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
};

fn remember_lsp_command(
    self: *Self,
    lsp_name: []const u8,
    language_server: []const u8,
    language_server_options: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
) error{OutOfMemory}!void {
    if (self.lsp_commands.contains(lsp_name)) return;
    const key = try self.allocator.dupe(u8, lsp_name);
    errdefer self.allocator.free(key);
    const command = try self.allocator.dupe(u8, language_server);
    errdefer self.allocator.free(command);
    const options = try self.allocator.dupe(u8, language_server_options);
    errdefer self.allocator.free(options);
    try self.lsp_commands.put(self.allocator, key, .{
        .language_server = command,
        .language_server_options = options,
        .language_server_protocol = language_server_protocol,
    });
}

fn mark_lsp_unavailable(self: *Self, lsp_name: []const u8) void {
    if (self.lsp_unavailable.contains(lsp_name)) return;
    const key = self.allocator.dupe(u8, lsp_name) catch return;
    self.lsp_unavailable.put(self.allocator, key, {}) catch self.allocator.free(key);
}

fn clear_lsp_unavailable(self: *Self, lsp_name: []const u8) void {
    if (self.lsp_unavailable.fetchRemove(lsp_name)) |kv| self.allocator.free(kv.key);
}

fn is_lsp_unavailable(self: *Self, lsp_name: []const u8) bool {
    return self.lsp_unavailable.contains(lsp_name);
}

pub fn restart_lsp_client(self: *Self, lsp_name: []const u8) StartLspError!*LSPClient {
    return self.restart_lsp_client_inner(lsp_name, .if_dead);
}

pub fn force_restart_lsp_client(self: *Self, lsp_name: []const u8) StartLspError!*LSPClient {
    self.clear_lsp_unavailable(lsp_name);
    return self.restart_lsp_client_inner(lsp_name, .always);
}

const RestartMode = enum { if_dead, always };

fn restart_lsp_client_inner(self: *Self, lsp_name: []const u8, mode: RestartMode) StartLspError!*LSPClient {
    if (mode == .if_dead) {
        if (self.is_lsp_unavailable(lsp_name)) return error.LspFailed;
        if (self.get_existing_lsp_client(lsp_name)) |client| return client;
    }
    try self.check_lsp_available(lsp_name);
    self.notify_lsp_status(lsp_name, .starting);
    const new_client = if (self.language_servers.get(lsp_name)) |old_client|
        try old_client.restart()
    else blk: {
        const command = self.lsp_commands.get(lsp_name) orelse return error.LspFailed;
        break :blk try LSPClient.start(
            self.allocator,
            self.name,
            command.language_server,
            command.language_server_options,
            command.language_server_protocol,
            self.parent.ref(),
            true, // notify_restart
        );
    };
    errdefer new_client.deinit();
    self.evict_lsp_client(lsp_name);
    try self.language_servers.put(try self.allocator.dupe(u8, lsp_name), new_client);
    self.notify_lsp_status(lsp_name, .running);
    return new_client;
}

pub fn restart_language_server_for_file(self: *Self, file_path: []const u8) StartLspError!void {
    const lsp_name = self.file_language_server_name.get(file_path) orelse return error.NoLsp;
    _ = try self.force_restart_lsp_client(lsp_name);
    self.logger_lsp.print("language server restarted for {s}", .{file_path});
}

pub fn get_or_start_lsp_client(self: *Self, from: tp.pid_ref, file_path: []const u8, language_server: []const u8, language_server_options: []const u8, language_server_protocol: file_type_config.ProtocolLevel) StartLspError!*LSPClient {
    var lsp_name: []const u8 = "";
    _ = cbor.match(language_server, .{ cbor.extract(&lsp_name), cbor.more }) catch false;
    if (lsp_name.len == 0) return error.LspFailed;

    if (self.file_language_server_name.get(file_path)) |existing|
        return self.restart_lsp_client(existing);
    if (self.is_lsp_unavailable(lsp_name)) return error.LspFailed;

    try self.remember_lsp_command(lsp_name, language_server, language_server_options, language_server_protocol);
    {
        const key = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, lsp_name);
        errdefer self.allocator.free(value);
        try self.file_language_server_name.put(key, value);
    }

    return self.get_existing_lsp_client(lsp_name) orelse blk: {
        try self.check_lsp_available(lsp_name);
        self.notify_lsp_status(lsp_name, .starting);
        self.evict_lsp_client(lsp_name);
        const new_client = try LSPClient.start(self.allocator, self.name, language_server, language_server_options, language_server_protocol, from, false);
        errdefer new_client.deinit();
        try self.language_servers.put(try self.allocator.dupe(u8, lsp_name), new_client);
        self.notify_lsp_status(lsp_name, .running);
        break :blk new_client;
    };
}

pub fn get_lsp_client_for_file(self: *Self, file_path: []const u8) StartLspError!*LSPClient {
    const lsp_name = self.file_language_server_name.get(file_path) orelse return error.NoLsp;
    if (self.get_existing_lsp_client(lsp_name)) |client| return client;
    return self.restart_lsp_client(lsp_name);
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
    defer from.send(.{ "PRJ", "new_or_modified_files_done", self.longest_new_or_modified_file_path, query_ }) catch {};
    if (query.len < 3)
        return self.simple_query_new_or_modified_files(from, max, query);

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
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query_, self.files.items.len }) catch {};
    if (query.len < 3)
        return self.simple_query_recent_files(from, max, query);

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

pub fn file_added(self: *Self, file_path: []const u8) OutOfMemoryError!void {
    for (self.files.items) |file|
        if (std.mem.eql(u8, file.path, file_path)) return;
    for (self.pending.items) |file|
        if (std.mem.eql(u8, file.path, file_path)) return;
    const file_type, const file_icon, const file_color = guess_file_type(file_path);
    (try self.files.addOne(self.allocator)).* = .{
        .path = try self.allocator.dupe(u8, file_path),
        .type = file_type,
        .icon = file_icon,
        .color = file_color,
        .mtime = @as(i128, std.Io.Clock.real.now(root.get_io()).toNanoseconds()),
    };
    self.longest_file_path = @max(self.longest_file_path, file_path.len);
    self.sort_files_by_mtime();
}

pub fn file_modified(self: *Self, file_path: []const u8) void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        file.mtime = @as(i128, std.Io.Clock.real.now(root.get_io()).toNanoseconds());
        self.sort_files_by_mtime();
        return;
    }
}

pub fn file_renamed(self: *Self, from_path: []const u8, to_path: []const u8) OutOfMemoryError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, to_path)) continue;
        self.file_deleted(from_path);
        return;
    }
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, from_path)) continue;
        const new_path = try self.allocator.dupe(u8, to_path);
        self.allocator.free(file.path);
        file.path = new_path;
        file.mtime = @as(i128, std.Io.Clock.real.now(root.get_io()).toNanoseconds());
        self.longest_file_path = @max(self.longest_file_path, to_path.len);
        self.sort_files_by_mtime();
        return;
    }
    return self.file_added(to_path);
}

pub fn file_deleted(self: *Self, file_path: []const u8) void {
    for (self.files.items, 0..) |file, i| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        self.allocator.free(file.path);
        _ = self.files.swapRemove(i);
        self.sort_files_by_mtime();
        return;
    }
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

pub fn did_open(
    self: *Self,
    from: tp.pid_ref,
    file_path: []const u8,
    file_type: []const u8,
    language_server: []const u8,
    language_server_options: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
    version: usize,
    text: []const u8,
) StartLspError!void {
    self.update_mru(&.{ .src = .{ .path = file_path, .line = 0, .column = 0 } }) catch {};
    const client = try self.get_or_start_lsp_client(from, file_path, language_server, language_server_options, language_server_protocol);
    return client.did_open(file_path, file_type, version, text);
}

pub fn did_change(self: *Self, file_path: []const u8, version: usize, text_dst: []const u8, text_src: []const u8, eol_mode: Buffer.EolMode) StartLspError!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.did_change(file_path, version, text_dst, text_src, eol_mode);
}

pub fn did_save(self: *Self, file_path: []const u8) StartLspError!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.did_save(file_path);
}

pub fn did_close(self: *Self, file_path: []const u8) StartLspError!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.did_close(file_path);
}

pub const SendGotoRequestError = LSPClient.SendGotoRequestError;

fn goto_client(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!?*LSPClient {
    return self.get_lsp_client_for_file(args.src.path) catch |e| switch (e) {
        // no language server is available for this file
        error.NoLsp,
        error.LspFailed,
        error.ThespianSpawnFailed,
        error.InvalidLspCommand,
        error.Timeout,
        => {
            if (args.alternative_destination) |*link| try LSPClient.navigate_to_alternate_destination(from.ref(), link);
            return null;
        },
        else => return e,
    };
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    const client = (try self.goto_client(from, args)) orelse return;
    return client.goto_definition(from, args);
}

pub fn goto_declaration(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    const client = (try self.goto_client(from, args)) orelse return;
    return client.goto_declaration(from, args);
}

pub fn goto_implementation(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    const client = (try self.goto_client(from, args)) orelse return;
    return client.goto_implementation(from, args);
}

pub fn goto_type_definition(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    const client = (try self.goto_client(from, args)) orelse return;
    return client.goto_type_definition(from, args);
}

pub fn references(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) SendGotoRequestError!void {
    const client = try self.get_lsp_client_for_file(source_location.src.path);
    return client.references(from, source_location);
}

pub fn highlight_references(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) SendGotoRequestError!void {
    const client = try self.get_lsp_client_for_file(source_location.src.path);
    return client.highlight_references(from, source_location);
}

pub const CompletionError = LSPClient.CompletionError;
pub fn completion(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) StartLspError!void {
    const client = try self.get_lsp_client_for_file(source_location.src.path);
    return client.completion(from, source_location);
}

pub const SymbolInformationError = LSPClient.SymbolInformationError;
pub fn symbols(self: *Self, from: tp.pid_ref, file_path: []const u8) (StartLspError || SymbolInformationError)!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.symbols(from, file_path);
}

pub fn rename_symbol(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) (StartLspError || GetLineOfFileError)!void {
    const client = try self.get_lsp_client_for_file(source_location.src.path);
    return client.rename_symbol(from, source_location);
}

pub fn hover(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) StartLspError!void {
    const client = try self.get_lsp_client_for_file(source_location.src.path);
    return client.hover(from, source_location);
}

pub const DiagnosticError = error{
    InvalidTargetURI,
    InvalidDiagnostic,
    InvalidDiagnosticFieldName,
    InvalidDiagnosticField,
} || LSPClient.RangeError || cbor.Error;

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
    const file_path = try LSPClient.file_uri_to_path(uri.?, &file_path_buf);

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

fn send_diagnostic(_: *Self, to: tp.pid_ref, file_path: []const u8, diagnostic: []const u8) DiagnosticError!void {
    var source: []const u8 = "unknown";
    var code: []const u8 = "none";
    var code_int: i64 = 0;
    var code_int_buf: [64]u8 = undefined;
    var message: []const u8 = "empty";
    var severity: i64 = 1;
    var range: ?LSPClient.Range = null;
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
            range = try LSPClient.read_range(range_);
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
