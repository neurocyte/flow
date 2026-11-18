const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const EditSet = @import("EditSet");
const log = @import("log");
const root = @import("soft_root").root;
const git = @import("git");
const file_type_config = @import("file_type_config");
const file_link = @import("file_link");
const Buffer = @import("Buffer");
const bin_path = @import("bin_path");
const builtin = @import("builtin");

const file_finder = @import("file_finder");

const project_manager = @import("project_manager.zig");
const Repo = @import("Repo.zig");
const RecentFiles = @import("RecentFiles.zig");
const LSP = @import("LSP.zig");
const LSPClient = @import("LSPClient.zig");

allocator: std.mem.Allocator,
name: []const u8,
/// Recently used files, persisted with the project. Every update is also
/// reported to the file finder, which owns the full list of project files.
mru: RecentFiles,
finder: file_finder.Handle,
file_finder_longest: usize = 0,
file_finder_count: usize = 0,
open_time: i64,
language_servers: std.StringHashMap(*LSPClient),
diagnostics: std.StringHashMapUnmanaged([]const u8) = .empty,
file_language_server_name: std.StringHashMap([]const u8),
lsp_unavailable: std.StringHashMapUnmanaged(void) = .empty,
lsp_commands: std.StringHashMapUnmanaged(LspCommand) = .empty,
lsp_settings: std.StringHashMapUnmanaged([]const u8) = .empty,
lsp_status_subscribers: std.AutoHashMapUnmanaged(tp.piid, void) = .empty,
tasks: std.ArrayList(Task),
persistent: bool = false,
logger: log.Logger,
logger_lsp: log.Logger,
logger_git: log.Logger,
last_used: i128,
parent: tp.pid,

repo: ?*Repo = null,
active: bool = false,

// async task states
state: struct {
    file_finder: State = .running,
    repo: State = .running,
} = .{},

load_complete: bool = false,

const Self = @This();

const OutOfMemoryError = error{OutOfMemory};
pub const RequestError = error{
    InvalidRequestVcsStatusFilesRequest,
    InvalidVcsUpdateIndexRequest,
    InvalidGetMruPositionRequest,
    InvalidTasksRequest,
} || OutOfMemoryError || cbor.Error;
pub const StartLspError = LSPClient.StartLspError;
pub const LspError = LSPClient.LspError;
pub const GitError = error{InvalidGitResponse};
pub const LspInfoError = LSPClient.LspInfoError;

pub const FilePos = RecentFiles.FilePos;

pub const SourceLocation = LSPClient.SourceLocation;

const Task = struct {
    command: []const u8,
    mtime: i64,
};

const State = enum { running, done, failed };

/// Takes ownership of `finder`, the file finder of the project.
pub fn init(allocator: std.mem.Allocator, name: []const u8, parent: tp.pid_ref, finder: file_finder.Handle) OutOfMemoryError!Self {
    const now = root.get_now();
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .mru = .init(allocator),
        .finder = finder,
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
    self.finder.deinit();
    self.parent.deinit();
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
    var i_diagnostics = self.diagnostics.iterator();
    while (i_diagnostics.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        self.allocator.free(p.value_ptr.*);
    }
    self.diagnostics.deinit(self.allocator);
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
    var i_settings = self.lsp_settings.iterator();
    while (i_settings.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        self.allocator.free(p.value_ptr.*);
    }
    self.lsp_settings.deinit(self.allocator);
    self.lsp_status_subscribers.deinit(self.allocator);
    self.mru.deinit();
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
    self.mru.sort();
    try cbor.writeValue(writer, self.name);
    var visited: usize = 0;
    for (self.mru.files.items) |file| {
        if (file.visited) visited += 1;
    }
    tp.trace(tp.channel.debug, .{ "write_state_v1", "files", visited });
    try cbor.writeArrayHeader(writer, visited);
    for (self.mru.files.items) |file| {
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
    self.mru.sort();
    try cbor.writeValue(writer, self.name);
    for (self.mru.files.items) |file| {
        if (!file.visited) continue;
        try cbor.writeArrayHeader(writer, 4);
        try cbor.writeValue(writer, file.path);
        try cbor.writeValue(writer, file.mtime);
        try cbor.writeValue(writer, file.pos.row);
        try cbor.writeValue(writer, file.pos.col);
    }
}

pub fn restore_state(self: *Self, data: []const u8) !void {
    self.restore_state_inner(data) catch |e|
        tp.trace(tp.channel.debug, .{ "restore_state", "abort", e });
}

pub fn restore_state_inner(self: *Self, data: []const u8) !void {
    tp.trace(tp.channel.debug, .{"restore_state"});
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
        if (client.process_instance_id() != from.instance_id())
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
    self.replay_lsp_status(subscriber);
}

pub fn remove_lsp_status_subscriber(self: *Self, subscriber: tp.pid_ref) void {
    _ = self.lsp_status_subscribers.remove(subscriber.instance_id());
}

fn notify_lsp_status(self: *Self, lsp_name: []const u8, status: LspStatus) void {
    var expired: std.ArrayList(tp.piid) = .empty;
    defer expired.deinit(self.allocator);
    var i = self.lsp_status_subscribers.keyIterator();
    while (i.next()) |piid| {
        const sub = tp.pid.from_id(piid.*) orelse {
            expired.append(self.allocator, piid.*) catch {};
            continue;
        };
        defer sub.deinit();
        sub.send(.{ "lsp_status", self.name, lsp_name, status }) catch {};
    }
    for (expired.items) |piid| _ = self.lsp_status_subscribers.remove(piid);
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

// A live file finder completes these requests. Complete them here when it
// cannot be asked; its exit separately cancels an outstanding palette query.

pub fn request_n_most_recent_file(self: *Self, from: tp.pid_ref, n: usize) void {
    if (self.state.file_finder == .failed or
        std.meta.isError(self.finder.request_n_most_recent_file(from, n)))
        from.send(.{@as(?[]const u8, null)}) catch {};
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) void {
    if (self.state.file_finder == .failed or
        std.meta.isError(self.finder.request_recent_files(from, max)))
        file_finder.send_recent_done(from, 0, "", 0);
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) void {
    if (self.state.file_finder == .failed or
        std.meta.isError(self.finder.query_recent_files(from, max, query)))
        file_finder.send_recent_done(from, 0, query, 0);
}

fn loaded(self: *Self, parent: tp.pid_ref) OutOfMemoryError!void {
    inline for (@typeInfo(@TypeOf(self.state)).@"struct".field_names) |f|
        if (@field(self.state, f) == .running) return;

    if (self.load_complete) return;
    self.load_complete = true;

    self.logger.print("opened: {s} with {d} files in {d} ms", .{
        self.name,
        self.file_finder_count,
        root.get_now().toMilliseconds() - self.open_time,
    });

    parent.send(.{ "PRJ", "open_done", self.name, self.file_finder_longest, self.file_finder_count }) catch {};
}

pub fn file_finder_ready(self: *Self, parent: tp.pid_ref, longest: usize, count: usize) OutOfMemoryError!void {
    self.file_finder_longest = longest;
    self.file_finder_count = count;
    self.state.file_finder = .done;
    return self.loaded(parent);
}

pub fn file_finder_exited(self: *Self, parent: tp.pid_ref) OutOfMemoryError!void {
    self.state.file_finder = .failed;
    parent.send(.{ "PRJ", "file_finder_failed", self.name }) catch {};
    return self.loaded(parent);
}

/// A file or directory was renamed outside of flow.
///
/// A use of the old path that was in flight may still arrive afterwards and
/// list it again, here and in the file finder, until the project is opened
/// again, which skips files that are gone. That takes a use racing the
/// change, which is rare.
pub fn file_renamed(self: *Self, from_path: []const u8, to_path: []const u8) OutOfMemoryError!void {
    return self.mru.renamed(from_path, to_path);
}

/// A file or directory was deleted outside of flow. See `file_renamed`.
pub fn file_deleted(self: *Self, path: []const u8) void {
    self.mru.deleted(path);
}

pub fn update_mru(self: *Self, source_location: *const SourceLocation) OutOfMemoryError!void {
    try self.update_mru_internal(source_location, @as(i128, std.Io.Clock.real.now(root.get_io()).toNanoseconds()));
}

fn update_mru_internal(self: *Self, source_location: *const SourceLocation, mtime: i128) OutOfMemoryError!void {
    const path = source_location.src.path;
    defer self.finder.update_mru(path, mtime) catch {};
    const visited = source_location.src.line != 0;
    const pos: FilePos = .{ .row = source_location.src.line, .col = source_location.src.column };
    return self.mru.update(path, if (visited) pos else null, mtime);
}

pub fn get_mru_position(self: *Self, from: tp.pid_ref, file_path: []const u8) RequestError!void {
    if (self.mru.position(file_path)) |pos| {
        from.send(.{ pos.row + 1, pos.col + 1 }) catch return error.InvalidGetMruPositionRequest;
        return;
    }
    from.send(.{"none"}) catch return error.InvalidGetMruPositionRequest;
}

/// links the repository that contains the project, or none
pub fn set_repo(self: *Self, parent: tp.pid_ref, repo_: ?*Repo) OutOfMemoryError!void {
    self.repo = repo_;
    const repo = repo_ orelse return self.repo_done(parent);
    repo.refresh_vcs_status();
    if (repo.state != .running) return self.repo_done(parent);
}

/// the first status run of the linked repository is done
pub fn repo_done(self: *Self, parent: tp.pid_ref) OutOfMemoryError!void {
    if (self.state.repo != .running) return;
    self.state.repo = .done;
    return self.loaded(parent);
}

pub fn count_language_servers(self: *Self) usize {
    var count: usize = 0;
    var i = self.language_servers.iterator();
    while (i.next()) |entry| {
        if (!entry.value_ptr.*.expired() and self.lsp_commands.contains(entry.key_ptr.*)) count += 1;
    }
    return count;
}

pub fn write_language_servers(self: *Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var i = self.language_servers.iterator();
    while (i.next()) |entry| {
        if (entry.value_ptr.*.expired()) continue;
        const command = self.lsp_commands.get(entry.key_ptr.*) orelse continue;
        const resolved = bin_path.find_binary_in_path(self.allocator, entry.key_ptr.*) catch null;
        defer if (resolved) |path| self.allocator.free(path);
        try cbor.writeArrayHeader(writer, 5);
        try cbor.writeValue(writer, self.name);
        try cbor.writeValue(writer, @as([]const u8, resolved orelse ""));
        try cbor.writeValue(writer, entry.value_ptr.*.server_name);
        try cbor.writeValue(writer, entry.value_ptr.*.server_version);
        try writer.writeAll(command.language_server);
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
    language_server_settings: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
    version: usize,
    hash: EditSet.Hash,
    text: []const u8,
) StartLspError!void {
    self.update_mru(&.{ .src = .{ .path = file_path, .line = 0, .column = 0 } }) catch {};
    var lsp_name: []const u8 = "";
    _ = cbor.match(language_server, .{ cbor.extract(&lsp_name), cbor.more }) catch false;
    self.lsp_settings_changed(lsp_name, language_server_settings, .if_changed) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    const client = try self.get_or_start_lsp_client(from, file_path, language_server, language_server_options, language_server_protocol);
    return client.did_open(file_path, file_type, version, hash, text);
}

pub fn did_change(self: *Self, file_path: []const u8, version: usize, hash: EditSet.Hash, edit_set: cbor.Raw) StartLspError!void {
    const client = try self.get_lsp_client_for_file(file_path);
    client.did_change(file_path, version, hash, edit_set) catch |e| switch (e) {
        error.OutOfSync => self.parent.send(.{ "PRJ", "lsp_out_of_sync", file_path }) catch {},
        else => |e_| return e_,
    };
}

pub fn did_change_full(self: *Self, file_path: []const u8, version: usize, hash: EditSet.Hash, text: []const u8) StartLspError!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.did_change_full(file_path, version, hash, text);
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

pub fn completion_resolve(self: *Self, from: tp.pid_ref, file_path: []const u8, token: u32, item: []const u8) StartLspError!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.completion_resolve(from, file_path, token, item);
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
    self.set_diagnostics(file_path, diagnostics) catch {};
    return self.send_diagnostics(to, file_path, diagnostics);
}

fn send_diagnostics(self: *Self, to: tp.pid_ref, file_path: []const u8, diagnostics: []const u8) DiagnosticError!void {
    self.send_clear_diagnostics(to, file_path);
    var iter = diagnostics;
    var len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic))) {
            try self.send_diagnostic(to, file_path, diagnostic);
        } else return error.InvalidDiagnosticField;
    }
}

/// send the last published diagnostics of file_path again, for an editor that just opened the file
pub fn resend_diagnostics(self: *Self, to: tp.pid_ref, file_path: []const u8) DiagnosticError!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = self.diagnostics.getEntry(self.diagnostics_key(file_path, &buf)) orelse return;
    return self.send_diagnostics(to, entry.key_ptr.*, entry.value_ptr.*);
}

fn diagnostics_key(self: *const Self, file_path: []const u8, buf: []u8) []const u8 {
    return if (std.fs.path.isAbsolute(file_path))
        file_path
    else
        std.fmt.bufPrint(buf, "{s}{c}{s}", .{ self.name, std.fs.path.sep, file_path }) catch file_path;
}

fn send_diagnostic(self: *Self, to: tp.pid_ref, file_path: []const u8, diagnostic: []const u8) DiagnosticError!void {
    var source: []const u8 = "unknown";
    var code: []const u8 = "none";
    var code_int: i64 = 0;
    var code_int_buf: [64]u8 = undefined;
    var message: []const u8 = "empty";
    var severity: i64 = 1;
    var range: ?LSPClient.Range = null;
    var rendered: []const u8 = "";
    var code_href: []const u8 = "";
    var related: std.Io.Writer.Allocating = .init(self.allocator);
    defer related.deinit();
    try cbor.writeArrayHeader(&related.writer, 0);
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
        } else if (std.mem.eql(u8, field_name, "relatedInformation")) {
            var related_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&related_)))) return error.InvalidDiagnosticField;
            related.clearRetainingCapacity();
            try write_related_information(&related.writer, related_);
        } else if (std.mem.eql(u8, field_name, "data")) {
            var data: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&data)))) return error.InvalidDiagnosticField;
            rendered = read_string_field(data, "rendered") catch "";
        } else if (std.mem.eql(u8, field_name, "codeDescription")) {
            var code_description: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&code_description)))) return error.InvalidDiagnosticField;
            code_href = read_string_field(code_description, "href") catch "";
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
        rendered,
        cbor.Raw{ .bytes = related.written() },
        code_href,
    } }) catch |e| {
        std.log.err("send add_diagnostic failed: {t}", .{e});
    };
}

/// write a DiagnosticRelatedInformation list as an array of [file_path, line, character, message]
fn write_related_information(writer: *std.Io.Writer, related: []const u8) DiagnosticError!void {
    var iter = related;
    var len = try cbor.decodeArrayHeader(&iter);
    try cbor.writeArrayHeader(writer, len);
    while (len > 0) : (len -= 1) {
        var uri: ?[]const u8 = null;
        var message: []const u8 = "";
        var range: ?LSPClient.Range = null;
        var fields = try cbor.decodeMapHeader(&iter);
        while (fields > 0) : (fields -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDiagnosticFieldName;
            if (std.mem.eql(u8, field_name, "location")) {
                var location: []const u8 = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&location)))) return error.InvalidDiagnosticField;
                var range_: []const u8 = undefined;
                var uri_: []const u8 = undefined;
                var loc_iter = location;
                var loc_fields = try cbor.decodeMapHeader(&loc_iter);
                while (loc_fields > 0) : (loc_fields -= 1) {
                    var loc_field: []const u8 = undefined;
                    if (!(try cbor.matchString(&loc_iter, &loc_field))) return error.InvalidDiagnosticFieldName;
                    if (std.mem.eql(u8, loc_field, "uri")) {
                        if (!(try cbor.matchValue(&loc_iter, cbor.extract(&uri_)))) return error.InvalidDiagnosticField;
                        uri = uri_;
                    } else if (std.mem.eql(u8, loc_field, "range")) {
                        if (!(try cbor.matchValue(&loc_iter, cbor.extract_cbor(&range_)))) return error.InvalidDiagnosticField;
                        range = try LSPClient.read_range(range_);
                    } else {
                        try cbor.skipValue(&loc_iter);
                    }
                }
            } else if (std.mem.eql(u8, field_name, "message")) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidDiagnosticField;
            } else {
                try cbor.skipValue(&iter);
            }
        }
        var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try LSPClient.file_uri_to_path(uri orelse return error.InvalidDiagnosticField, &file_path_buf);
        const start = (range orelse return error.InvalidDiagnosticField).start;
        try cbor.writeValue(writer, .{ file_path, start.line, start.character, message });
    }
}

/// the full compiler output rust-analyzer sends in data.rendered
/// the string field `name` of a cbor map, or "" if it has none
fn read_string_field(map: []const u8, name: []const u8) cbor.Error![]const u8 {
    var iter = map;
    var len = cbor.decodeMapHeader(&iter) catch return "";
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return "";
        var value: []const u8 = undefined;
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return "";
        var string: []const u8 = undefined;
        if (std.mem.eql(u8, field_name, name) and try cbor.matchValue(&value, cbor.extract(&string)))
            return string;
    }
    return "";
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

pub const ApplyEditResult = enum { applied, failed };
pub const CodeActionTrigger = LSPClient.CodeActionTrigger;
pub const Range = LSPClient.Range;
pub const CodeActionError = LSPClient.CodeActionError;

pub fn apply_code_action(self: *Self, from: tp.pid_ref, file_path: []const u8, action: []const u8) (StartLspError || LSPClient.CodeActionError)!void {
    const client = try self.get_lsp_client_for_file(file_path);
    return client.apply_code_action(from, action);
}

pub fn execute_code_action(self: *Self, to: tp.pid_ref, language_server: []const u8, action: []const u8) !void {
    const client = self.get_existing_lsp_client(language_server) orelse return error.NoLsp;
    return client.execute_code_action(to, action);
}

pub fn execute_command(self: *Self, language_server: []const u8, command: []const u8) LspError!void {
    const client = self.get_existing_lsp_client(language_server) orelse return error.NoLsp;
    return client.execute_command(command);
}

pub fn code_actions(self: *Self, from: tp.pid_ref, file_path: []const u8, range: LSPClient.Range, only: []const u8, trigger: CodeActionTrigger, token: u32) StartLspError!void {
    const client = self.get_lsp_client_for_file(file_path) catch |e| switch (e) {
        error.NoLsp => return LSPClient.send_code_actions_result(from, file_path, "", token, null) catch error.LspFailed,
        else => |e_| return e_,
    };
    var diagnostics: std.Io.Writer.Allocating = .init(self.allocator);
    defer diagnostics.deinit();
    self.write_diagnostics_in_range(&diagnostics.writer, file_path, range) catch {
        diagnostics.clearRetainingCapacity();
        try cbor.writeArrayHeader(&diagnostics.writer, 0);
    };
    return client.code_actions(from, file_path, range, diagnostics.written(), only, trigger, token);
}

pub fn lsp_initialized(self: *Self, lsp_name: []const u8) LspError!void {
    const json = self.lsp_settings.get(lsp_name) orelse return;
    if (json.len == 0) return;
    const client = self.get_existing_lsp_client(lsp_name) orelse return;
    const settings = cbor.fromJsonAlloc(self.allocator, json) catch
        return self.logger_lsp.print_err("configuration", "ignored invalid JSON in LSP settings for {s}", .{lsp_name});
    defer self.allocator.free(settings);
    return client.did_change_configuration(.{ .bytes = settings });
}

pub fn set_lsp_server_info(self: *Self, lsp_name: []const u8, server_info: []const u8) (error{OutOfMemory} || cbor.Error)!void {
    const client = self.get_existing_lsp_client(lsp_name) orelse return;
    return client.set_server_info(server_info);
}

pub fn set_lsp_capabilities(self: *Self, lsp_name: []const u8, capabilities: []const u8) (error{OutOfMemory} || cbor.Error)!void {
    const client = self.get_existing_lsp_client(lsp_name) orelse return;
    return client.set_server_capabilities(capabilities);
}

fn set_diagnostics(self: *Self, file_path: []const u8, diagnostics: []const u8) error{OutOfMemory}!void {
    var iter = diagnostics;
    const empty = (cbor.decodeArrayHeader(&iter) catch 0) == 0;
    if (self.diagnostics.fetchRemove(file_path)) |kv| {
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }
    if (empty) return;
    const key = try self.allocator.dupe(u8, file_path);
    errdefer self.allocator.free(key);
    const value = try self.allocator.dupe(u8, diagnostics);
    errdefer self.allocator.free(value);
    try self.diagnostics.put(self.allocator, key, value);
}

/// write the published diagnostics of file_path that overlap or touch range as an array
pub fn write_diagnostics_in_range(self: *Self, writer: *std.Io.Writer, file_path: []const u8, range: LSPClient.Range) (LSPClient.RangeError || std.Io.Writer.Error)!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const diagnostics = self.diagnostics.get(self.diagnostics_key(file_path, &buf)) orelse return cbor.writeArrayHeader(writer, 0);
    return LSPClient.write_diagnostics_in_range(writer, diagnostics, range);
}

pub fn apply_edit(self: *Self, from: tp.pid_ref, to: tp.pid_ref, language_server: []const u8, cbor_id: []const u8, params_cb: []const u8) LspError!void {
    var workspace_edit: std.Io.Writer.Allocating = .init(self.allocator);
    defer workspace_edit.deinit();
    const hashes = if (self.get_existing_lsp_client(language_server)) |client| &client.document_hashes else null;
    write_apply_edit_params(&workspace_edit.writer, params_cb, hashes) catch |e|
        return LSP.send_response(self.allocator, from, cbor_id, .{ .applied = false, .failureReason = @errorName(e) }) catch error.LspFailed;
    to.send(.{ "cmd", "apply_workspace_edit", .{
        cbor.Raw{ .bytes = workspace_edit.written() },
        .{ "apply_edit_response", self.name, language_server, cbor.Raw{ .bytes = cbor_id } },
    } }) catch return error.LspFailed;
}

fn write_apply_edit_params(writer: *std.Io.Writer, params_cb: []const u8, hashes: ?*const LSPClient.DocumentHashes) (LSPClient.WorkspaceEditError || error{InvalidApplyEditParams})!void {
    var iter = params_cb;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidApplyEditParams;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidApplyEditParams;
        if (std.mem.eql(u8, field_name, "edit")) {
            var edit: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&edit)))) return error.InvalidApplyEditParams;
            return LSPClient.write_workspace_edit(writer, edit, hashes);
        }
        try cbor.skipValue(&iter);
    }
    return error.InvalidApplyEditParams;
}

pub fn apply_edit_response(self: *Self, language_server: []const u8, cbor_id: []const u8, result: ApplyEditResult, reason: []const u8) LspError!void {
    const client = self.get_existing_lsp_client(language_server) orelse return error.NoLsp;
    const to = client.lsp.pid.ref();
    return (switch (result) {
        .applied => LSP.send_response(self.allocator, to, cbor_id, .{ .applied = true }),
        .failed => LSP.send_response(self.allocator, to, cbor_id, .{ .applied = false, .failureReason = reason }),
    }) catch error.LspFailed;
}

pub fn workDoneProgress_create(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) LspError!void {
    _ = params_cb;
    return LSP.send_response(self.allocator, from, cbor_id, null) catch error.LspFailed;
}

pub const SendSettings = enum { if_changed, always };

pub fn lsp_settings_changed(self: *Self, lsp_name: []const u8, settings: []const u8, mode: SendSettings) LspError!void {
    if (lsp_name.len == 0) return;
    const known = self.lsp_settings.get(lsp_name);
    const changed = if (known) |old| !std.mem.eql(u8, old, settings) else false;
    if (known == null or changed) try self.store_lsp_settings(lsp_name, settings);
    if (known == null or (mode == .if_changed and !changed)) return;
    const client = self.get_existing_lsp_client(lsp_name) orelse return;
    if (settings.len == 0)
        return if (changed) client.did_change_configuration(null);
    const settings_cb = cbor.fromJsonAlloc(self.allocator, settings) catch
        return self.logger_lsp.print_err("configuration", "ignored invalid JSON in LSP settings for {s}", .{lsp_name});
    defer self.allocator.free(settings_cb);
    return client.did_change_configuration(.{ .bytes = settings_cb });
}

fn store_lsp_settings(self: *Self, lsp_name: []const u8, settings: []const u8) error{OutOfMemory}!void {
    const value = try self.allocator.dupe(u8, settings);
    errdefer self.allocator.free(value);
    const gop = try self.lsp_settings.getOrPut(self.allocator, lsp_name);
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = self.allocator.dupe(u8, lsp_name) catch |e| {
            self.lsp_settings.removeByPtr(gop.key_ptr);
            return e;
        };
    }
    gop.value_ptr.* = value;
}

pub fn workspace_configuration(self: *Self, from: tp.pid_ref, language_server: []const u8, cbor_id: []const u8, params_cb: []const u8) LspError!void {
    const json = self.lsp_settings.get(language_server) orelse "";
    const settings = if (json.len == 0) "" else cbor.fromJsonAlloc(self.allocator, json) catch blk: {
        self.logger_lsp.print_err("configuration", "ignored invalid JSON in LSP settings for {s}", .{language_server});
        break :blk "";
    };
    defer self.allocator.free(settings);
    var result: std.Io.Writer.Allocating = .init(self.allocator);
    defer result.deinit();
    LSPClient.write_configuration(&result.writer, settings, params_cb) catch |e|
        return LSP.send_error_response(self.allocator, from, cbor_id, LSP.ErrorCode.InvalidParams, @errorName(e)) catch error.LspFailed;
    return LSP.send_response(self.allocator, from, cbor_id, cbor.Raw{ .bytes = result.written() }) catch error.LspFailed;
}

pub fn unsupported_lsp_request(self: *Self, from: tp.pid_ref, cbor_id: []const u8, method: []const u8) LspError!void {
    return LSP.send_error_response(self.allocator, from, cbor_id, LSP.ErrorCode.MethodNotFound, method) catch error.LspFailed;
}

pub const GetLineOfFileError = LSPClient.GetLineOfFileError;

pub fn sync_file_finder(self: *Self) void {
    self.finder.sync() catch {};
}

pub fn process_git_response(_: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || GitError || error{Exit})!void {
    var context: usize = undefined;
    var blame_output: []const u8 = undefined;

    if (try m.match(.{ tp.any, tp.extract(&context), "blame", tp.extract(&blame_output) })) {
        const request: *GitBlameRequest = @ptrFromInt(context);
        parent.send(.{ "PRJ", "git_blame", request.file_path, blame_output }) catch {};
    } else if (try m.match(.{ tp.any, tp.extract(&context), "blame", tp.null_ })) {
        const request: *GitBlameRequest = @ptrFromInt(context);
        defer request.deinit();
        parent.send(.{ "PRJ", "git_blame", request.file_path, null }) catch {};
    }
}

pub const VcsDiffMode = Repo.VcsDiffMode;
pub const VcsIndexUpdate = Repo.VcsIndexUpdate;
pub const VcsFileState = Repo.VcsFileState;

/// editor paths are relative to the project
fn abs_path(self: *const Self, file_path: []const u8) error{OutOfMemory}![]const u8 {
    if (std.fs.path.isAbsolute(file_path)) return self.allocator.dupe(u8, file_path);
    return std.fs.path.join(self.allocator, &.{ self.name, file_path });
}

pub fn request_vcs_blame(self: *Self, file_path: []const u8) error{OutOfMemory}!void {
    const request = try self.allocator.create(GitBlameRequest);
    request.* = .{
        .allocator = self.allocator,
        .project = @intFromPtr(self),
        .file_path = try self.allocator.dupe(u8, file_path),
    };
    const path = try self.abs_path(file_path);
    defer self.allocator.free(path);
    git.blame(@intFromPtr(request), path) catch |e|
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
