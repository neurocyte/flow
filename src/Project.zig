const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("root");
const dizzy = @import("dizzy");
const Buffer = @import("Buffer");
const fuzzig = @import("fuzzig");
const tracy = @import("tracy");
const git = @import("git");
const file_type_config = @import("file_type_config");
const builtin = @import("builtin");

const LSP = @import("LSP.zig");
const walk_tree = @import("walk_tree.zig");

allocator: std.mem.Allocator,
name: []const u8,
files: std.ArrayListUnmanaged(File) = .empty,
pending: std.ArrayListUnmanaged(File) = .empty,
longest_file_path: usize = 0,
open_time: i64,
language_servers: std.StringHashMap(*const LSP),
file_language_server: std.StringHashMap(*const LSP),
tasks: std.ArrayList(Task),
persistent: bool = false,
logger: log.Logger,
logger_lsp: log.Logger,
logger_git: log.Logger,

workspace: ?[]const u8 = null,
branch: ?[]const u8 = null,

walker: ?tp.pid = null,

// async task states
state: struct {
    walk_tree: State = .none,
    workspace_path: State = .none,
    current_branch: State = .none,
    workspace_files: State = .none,
} = .{},

const Self = @This();

const OutOfMemoryError = error{OutOfMemory};
const SpawnError = (OutOfMemoryError || error{ThespianSpawnFailed});
pub const InvalidMessageError = error{ InvalidMessage, InvalidMessageField, InvalidTargetURI, InvalidMapType };
pub const StartLspError = (error{ ThespianSpawnFailed, Timeout, InvalidLspCommand } || LspError || OutOfMemoryError || cbor.Error);
pub const LspError = (error{ NoLsp, LspFailed } || OutOfMemoryError);
pub const ClientError = (error{ClientFailed} || OutOfMemoryError);
pub const LspOrClientError = (LspError || ClientError);

const File = struct {
    path: []const u8,
    type: []const u8,
    icon: []const u8,
    color: u24,
    mtime: i128,
    pos: FilePos = .{},
    visited: bool = false,
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
        .file_language_server = std.StringHashMap(*const LSP).init(allocator),
        .tasks = std.ArrayList(Task).init(allocator),
        .logger = log.logger("project"),
        .logger_lsp = log.logger("lsp"),
        .logger_git = log.logger("git"),
    };
}

pub fn deinit(self: *Self) void {
    if (self.walker) |pid| pid.send(.{"stop"}) catch {};
    if (self.workspace) |p| self.allocator.free(p);
    if (self.branch) |p| self.allocator.free(p);
    var i_ = self.file_language_server.iterator();
    while (i_.next()) |p| {
        self.allocator.free(p.key_ptr.*);
    }
    var i = self.language_servers.iterator();
    while (i.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.term();
    }
    for (self.files.items) |file| self.allocator.free(file.path);
    self.files.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    for (self.tasks.items) |task| self.allocator.free(task.command);
    self.tasks.deinit();
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
        var path: []const u8 = undefined;
        var mtime: i128 = undefined;
        var row: usize = undefined;
        var col: usize = undefined;
        if (!try cbor.matchValue(&iter, .{
            tp.extract(&path),
            tp.extract(&mtime),
            tp.extract(&row),
            tp.extract(&col),
        })) {
            try cbor.skipValue(&iter);
            continue;
        }
        tp.trace(tp.channel.debug, .{ "restore_state_v1", "file", path, mtime, row, col });
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const stat = std.fs.cwd().statFile(path) catch continue;
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
        (try self.tasks.addOne()).* = .{
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
}!void {
    tp.trace(tp.channel.debug, .{"restore_state_v0"});
    defer self.sort_files_by_mtime();
    var name: []const u8 = undefined;
    var path: []const u8 = undefined;
    var mtime: i128 = undefined;
    var row: usize = undefined;
    var col: usize = undefined;
    var iter: []const u8 = data;
    _ = cbor.matchValue(&iter, tp.extract(&name)) catch {};
    tp.trace(tp.channel.debug, .{ "restore_state_v0", "name", name });
    while (cbor.matchValue(&iter, .{
        tp.extract(&path),
        tp.extract(&mtime),
        tp.extract(&row),
        tp.extract(&col),
    }) catch |e| switch (e) {
        error.TooShort => return,
        else => return e,
    }) {
        tp.trace(tp.channel.debug, .{ "restore_state_v0", "file", path, mtime, row, col });
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const stat = std.fs.cwd().statFile(path) catch continue;
        switch (stat.kind) {
            .sym_link, .file => try self.update_mru_internal(path, mtime, row, col),
            else => {},
        }
    }
}

fn get_language_server_instance(self: *Self, language_server: []const u8) StartLspError!*const LSP {
    if (self.language_servers.get(language_server)) |lsp| {
        if (lsp.pid.expired()) {
            _ = self.language_servers.remove(language_server);
            lsp.deinit();
        } else {
            return lsp;
        }
    }
    const lsp = try LSP.open(self.allocator, self.name, .{ .buf = language_server });
    errdefer lsp.deinit();
    const uri = try self.make_URI(null);
    defer self.allocator.free(uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, self.name, std.fs.path.sep);
    const basename = if (basename_begin) |begin| self.name[begin + 1 ..] else self.name;

    try self.send_lsp_init_request(lsp, self.name, basename, uri, language_server);
    try self.language_servers.put(try self.allocator.dupe(u8, language_server), lsp);
    return lsp;
}

fn get_or_start_language_server(self: *Self, file_path: []const u8, language_server: []const u8) StartLspError!*const LSP {
    const lsp = self.file_language_server.get(file_path) orelse blk: {
        const new_lsp = try self.get_language_server_instance(language_server);
        const key = try self.allocator.dupe(u8, file_path);
        try self.file_language_server.put(key, new_lsp);
        break :blk new_lsp;
    };
    return lsp;
}

fn get_language_server(self: *Self, file_path: []const u8) LspError!*const LSP {
    const lsp = self.file_language_server.get(file_path) orelse return error.NoLsp;
    if (lsp.pid.expired()) {
        if (self.file_language_server.fetchRemove(file_path)) |kv|
            self.allocator.free(kv.key);
        return error.LspFailed;
    }
    return lsp;
}

fn make_URI(self: *Self, file_path: ?[]const u8) LspError![]const u8 {
    var buf = std.ArrayList(u8).init(self.allocator);
    if (file_path) |path| {
        if (std.fs.path.isAbsolute(path)) {
            try buf.writer().print("file://{s}", .{path});
        } else {
            try buf.writer().print("file://{s}{c}{s}", .{ self.name, std.fs.path.sep, path });
        }
    } else try buf.writer().print("file://{s}", .{self.name});
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

pub fn request_n_most_recent_file(self: *Self, from: tp.pid_ref, n: usize) ClientError!void {
    if (n >= self.files.items.len) return error.ClientFailed;
    const file_path = if (self.files.items.len > 0) self.files.items[n].path else null;
    from.send(.{file_path}) catch return error.ClientFailed;
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) ClientError!void {
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, "" }) catch {};
    for (self.files.items, 0..) |file, i| {
        from.send(.{ "PRJ", "recent", self.longest_file_path, file.path, file.type, file.icon, file.color }) catch return error.ClientFailed;
        if (i >= max) return;
    }
}

fn simple_query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) ClientError!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query }) catch {};
    for (self.files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |idx| {
            var matches = try self.allocator.alloc(usize, query.len);
            defer self.allocator.free(matches);
            var n: usize = 0;
            while (n < query.len) : (n += 1) matches[n] = idx + n;
            from.send(.{ "PRJ", "recent", self.longest_file_path, file.path, file.type, file.icon, file.color, matches }) catch return error.ClientFailed;
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) ClientError!usize {
    if (query.len < 3)
        return self.simple_query_recent_files(from, max, query);
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query }) catch {};

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
    var matches = std.ArrayList(Match).init(self.allocator);

    for (self.files.items) |file| {
        const match = searcher.scoreMatches(file.path, query);
        if (match.score) |score| {
            (try matches.addOne()).* = .{
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
        from.send(.{ "PRJ", "recent", self.longest_file_path, match.path, match.type, match.icon, match.color, match.matches }) catch return error.ClientFailed;
    return @min(max, matches.items.len);
}

pub fn walk_tree_entry(
    self: *Self,
    file_path: []const u8,
    mtime: i128,
) OutOfMemoryError!void {
    const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(file_path);
    self.longest_file_path = @max(self.longest_file_path, file_path.len);
    (try self.pending.addOne(self.allocator)).* = .{
        .path = try self.allocator.dupe(u8, file_path),
        .type = file_type,
        .icon = file_icon,
        .color = file_color,
        .mtime = mtime,
    };
}

pub fn walk_tree_done(self: *Self, parent: tp.pid_ref) OutOfMemoryError!void {
    self.state.walk_tree = .done;
    if (self.walker) |pid| pid.deinit();
    self.walker = null;
    return self.loaded(parent);
}

fn guess_file_type(file_path: []const u8) struct { []const u8, []const u8, u24 } {
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
    } else .{
        file_type_config.default.name,
        file_type_config.default.icon,
        file_type_config.default.color,
    };
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

pub fn get_mru_position(self: *Self, from: tp.pid_ref, file_path: []const u8) ClientError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        from.send(.{ file.pos.row + 1, file.pos.col + 1 }) catch return error.ClientFailed;
        return;
    }
    from.send(.{"none"}) catch return error.ClientFailed;
}

pub fn request_tasks(self: *Self, from: tp.pid_ref) ClientError!void {
    var message = std.ArrayList(u8).init(self.allocator);
    const writer = message.writer();
    try cbor.writeArrayHeader(writer, self.tasks.items.len);
    for (self.tasks.items) |task|
        try cbor.writeValue(writer, task.command);
    from.send_raw(.{ .buf = message.items }) catch return error.ClientFailed;
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
    (try self.tasks.addOne()).* = .{
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

pub fn did_open(self: *Self, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) StartLspError!void {
    defer std.heap.c_allocator.free(text);
    self.update_mru(file_path, 0, 0) catch {};
    const lsp = try self.get_or_start_language_server(file_path, language_server);
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
    var edits_cb = std.ArrayList(u8).init(arena);
    const writer = edits_cb.writer();

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
        var msg = std.ArrayList(u8).init(arena);
        const msg_writer = msg.writer();
        try cbor.writeMapHeader(msg_writer, 2);
        try cbor.writeValue(msg_writer, "textDocument");
        try cbor.writeValue(msg_writer, .{ .uri = uri, .version = version });
        try cbor.writeValue(msg_writer, "contentChanges");
        try cbor.writeArrayHeader(msg_writer, edits_count);
        _ = try msg_writer.write(edits_cb.items);

        lsp.send_notification_raw("textDocument/didChange", msg.items) catch return error.LspFailed;
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

pub const SendGotoRequestError = (LspError || ClientError || InvalidMessageError || GetLineOfFileError || cbor.Error);

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
                    try self_.project.send_reference_list(self_.from.ref(), locations, self_.name);
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

fn navigate_to_location_link(from: tp.pid_ref, location_link: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = location_link;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var value: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
            targetUri = value;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetRange = try read_range(range);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetSelectionRange = try read_range(range);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (targetUri == null or targetRange == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, targetUri.?[0..7], "file://")) return error.InvalidTargetURI;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_path = std.Uri.percentDecodeBackwards(&file_path_buf, targetUri.?[7..]);
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    if (targetSelectionRange) |sel| {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                targetSelectionRange.?.start.line + 1,
                targetSelectionRange.?.start.character + 1,
                sel.start.line,
                sel.start.character,
                sel.end.line,
                sel.end.character,
            },
        } }) catch return error.ClientFailed;
    } else {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                targetRange.?.start.line + 1,
                targetRange.?.start.character + 1,
            },
        } }) catch return error.ClientFailed;
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
                try self_.project.send_reference_list(self_.from.ref(), locations, self_.name);
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

fn send_reference_list(self: *Self, to: tp.pid_ref, locations: []const u8, name: []const u8) (ClientError || InvalidMessageError || GetLineOfFileError || cbor.Error)!void {
    defer to.send(.{ "REF", "done" }) catch {};
    var iter = locations;
    var len = try cbor.decodeArrayHeader(&iter);
    const count = len;
    while (len > 0) : (len -= 1) {
        var location: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&location))) {
            try send_reference(to, location, name);
        } else return error.InvalidMessageField;
    }
    self.logger_lsp.print("found {d} references", .{count});
}

fn send_reference(to: tp.pid_ref, location: []const u8, name: []const u8) (ClientError || InvalidMessageError || GetLineOfFileError || cbor.Error)!void {
    const allocator = std.heap.c_allocator;
    var iter = location;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var value: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
            targetUri = value;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetRange = try read_range(range);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetSelectionRange = try read_range(range);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (targetUri == null or targetRange == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, targetUri.?[0..7], "file://")) return error.InvalidTargetURI;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_path = std.Uri.percentDecodeBackwards(&file_path_buf, targetUri.?[7..]);
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    const line = try get_line_of_file(allocator, file_path, targetRange.?.start.line);
    defer allocator.free(line);
    const file_path_ = if (file_path.len > name.len and std.mem.eql(u8, name, file_path[0..name.len]))
        file_path[name.len + 1 ..]
    else
        file_path;
    to.send(.{
        "REF",
        file_path_,
        targetRange.?.start.line + 1,
        targetRange.?.start.character,
        targetRange.?.end.line + 1,
        targetRange.?.end.character,
        line,
    }) catch return error.ClientFailed;
}

pub fn completion(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspOrClientError || InvalidMessageError || cbor.Error)!void {
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

        pub fn receive(self_: @This(), response: tp.message) !void {
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

fn send_completion_list(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var items: []const u8 = "";
    var is_incomplete: bool = false;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "items")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&items)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "isIncomplete")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&is_incomplete)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return send_completion_items(to, file_path, row, col, items, is_incomplete) catch error.ClientFailed;
}

fn send_completion_items(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, items: []const u8, is_incomplete: bool) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = items;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var item: []const u8 = "";
    while (len > 0) : (len -= 1) {
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&item)))) return error.InvalidMessageField;
        send_completion_item(to, file_path, row, col, item, if (len > 1) true else is_incomplete) catch return error.ClientFailed;
    }
}

fn send_completion_item(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, item: []const u8, is_incomplete: bool) (ClientError || InvalidMessageError || cbor.Error)!void {
    var label: []const u8 = "";
    var label_detail: []const u8 = "";
    var label_description: []const u8 = "";
    var kind: usize = 0;
    var detail: []const u8 = "";
    var documentation: []const u8 = "";
    var documentation_kind: []const u8 = "";
    var sortText: []const u8 = "";
    var insertTextFormat: usize = 0;
    var textEdit_newText: []const u8 = "";
    var textEdit_insert: ?Range = null;
    var textEdit_replace: ?Range = null;

    var iter = item;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "label")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&label)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "labelDetails")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
                if (std.mem.eql(u8, field_name, "detail")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_detail)))) return error.InvalidMessageField;
                } else if (std.mem.eql(u8, field_name, "description")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_description)))) return error.InvalidMessageField;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "detail")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&detail)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "documentation")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
                if (std.mem.eql(u8, field_name, "kind")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&documentation_kind)))) return error.InvalidMessageField;
                } else if (std.mem.eql(u8, field_name, "value")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&documentation)))) return error.InvalidMessageField;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "sortText")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&sortText)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "insertTextFormat")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&insertTextFormat)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "textEdit")) {
            // var textEdit: []const u8 = ""; // { "newText": "wait_expired(${1:timeout_ns: isize})", "insert": Range, "replace": Range },
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
                if (std.mem.eql(u8, field_name, "newText")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&textEdit_newText)))) return error.InvalidMessageField;
                } else if (std.mem.eql(u8, field_name, "insert")) {
                    var range_: []const u8 = undefined;
                    if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
                    textEdit_insert = try read_range(range_);
                } else if (std.mem.eql(u8, field_name, "replace")) {
                    var range_: []const u8 = undefined;
                    if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
                    textEdit_replace = try read_range(range_);
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const insert = textEdit_insert orelse return error.InvalidMessageField;
    const replace = textEdit_replace orelse return error.InvalidMessageField;
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
            insertTextFormat,
            textEdit_newText,
            insert.start.line,
            insert.start.character,
            insert.end.line,
            insert.end.character,
            replace.start.line,
            replace.start.character,
            replace.end.line,
            replace.end.character,
        },
    }) catch error.ClientFailed;
}

const Rename = struct {
    uri: []const u8,
    new_text: []const u8,
    range: Range,
};

pub fn rename_symbol(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspOrClientError || GetLineOfFileError || InvalidMessageError || cbor.Error)!void {
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
            var renames = std.ArrayList(Rename).init(allocator);
            defer renames.deinit();

            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
                    try decode_rename_symbol_map(result, &renames);
                    // write the renames message manually since there doesn't appear to be an array helper
                    var msg_buf = std.ArrayList(u8).init(allocator);
                    defer msg_buf.deinit();
                    const w = msg_buf.writer();
                    try cbor.writeArrayHeader(w, 3);
                    try cbor.writeValue(w, "cmd");
                    try cbor.writeValue(w, "rename_symbol_item");
                    try cbor.writeArrayHeader(w, renames.items.len);
                    for (renames.items) |rename| {
                        if (!std.mem.eql(u8, rename.uri[0..7], "file://")) return error.InvalidTargetURI;
                        var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        var file_path_ = std.Uri.percentDecodeBackwards(&file_path_buf, rename.uri[7..]);
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
                    self_.from.send_raw(.{ .buf = msg_buf.items }) catch return error.ClientFailed;
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
fn decode_rename_symbol_map(result: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
    var changes: []const u8 = "";
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "changes")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidMessageField;
            try decode_rename_symbol_changes(changes, renames);
            return;
        } else if (std.mem.eql(u8, field_name, "documentChanges")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidMessageField;
            try decode_rename_symbol_doc_changes(changes, renames);
            return;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return error.ClientFailed;
}

fn decode_rename_symbol_changes(changes: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = changes;
    var files_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
    while (files_len > 0) : (files_len -= 1) {
        var file_uri: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidMessage;
        try decode_rename_symbol_item(file_uri, &iter, renames);
    }
}

fn decode_rename_symbol_doc_changes(changes: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = changes;
    var changes_len = cbor.decodeArrayHeader(&iter) catch return error.InvalidMessage;
    while (changes_len > 0) : (changes_len -= 1) {
        var dc_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
        var file_uri: []const u8 = "";
        while (dc_fields_len > 0) : (dc_fields_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
            if (std.mem.eql(u8, field_name, "textDocument")) {
                var td_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
                while (td_fields_len > 0) : (td_fields_len -= 1) {
                    var td_field_name: []const u8 = undefined;
                    if (!(try cbor.matchString(&iter, &td_field_name))) return error.InvalidMessage;
                    if (std.mem.eql(u8, td_field_name, "uri")) {
                        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidMessage;
                    } else try cbor.skipValue(&iter); // skip "version": 1
                }
            } else if (std.mem.eql(u8, field_name, "edits")) {
                if (file_uri.len == 0) return error.InvalidMessage;
                try decode_rename_symbol_item(file_uri, &iter, renames);
            }
        }
    }
}

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit
fn decode_rename_symbol_item(file_uri: []const u8, iter: *[]const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var text_edits_len = cbor.decodeArrayHeader(iter) catch return error.InvalidMessage;
    while (text_edits_len > 0) : (text_edits_len -= 1) {
        var m_range: ?Range = null;
        var new_text: []const u8 = "";
        var edits_len = cbor.decodeMapHeader(iter) catch return error.InvalidMessage;
        while (edits_len > 0) : (edits_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(iter, &field_name))) return error.InvalidMessage;
            if (std.mem.eql(u8, field_name, "range")) {
                var range: []const u8 = undefined;
                if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
                m_range = try read_range(range);
            } else if (std.mem.eql(u8, field_name, "newText")) {
                if (!(try cbor.matchString(iter, &new_text))) return error.InvalidMessageField;
            } else {
                try cbor.skipValue(iter);
            }
        }

        const range = m_range orelse return error.InvalidMessageField;
        try renames.append(.{ .uri = file_uri, .range = range, .new_text = new_text });
    }
}

pub fn hover(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspOrClientError || InvalidMessageError || cbor.Error)!void {
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

fn send_hover(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var contents: []const u8 = "";
    var range: ?Range = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "contents")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&contents)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (contents.len > 0)
        return send_contents(to, "hover", file_path, row, col, contents, range);
}

fn send_contents(
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    result: []const u8,
    range: ?Range,
) !void {
    var iter = result;
    var kind: []const u8 = "plaintext";
    var value: []const u8 = "";
    if (try cbor.matchValue(&iter, cbor.extract(&value)))
        return send_content_msg(to, tag, file_path, row, col, kind, value, range);

    var is_list = true;
    var len = cbor.decodeArrayHeader(&iter) catch blk: {
        is_list = false;
        iter = result;
        break :blk cbor.decodeMapHeader(&iter) catch return;
    };

    if (is_list) {
        var content = std.ArrayList(u8).init(std.heap.c_allocator);
        defer content.deinit();
        while (len > 0) : (len -= 1) {
            if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                try content.appendSlice(value);
                if (len > 1) try content.appendSlice("\n");
            }
        }
        return send_content_msg(to, tag, file_path, row, col, kind, content.items, range);
    }

    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "value")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return send_content_msg(to, tag, file_path, row, col, kind, value, range);
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
) ClientError!void {
    const r = range orelse Range{
        .start = .{ .line = row, .character = col },
        .end = .{ .line = row, .character = col },
    };
    to.send(.{ tag, file_path, kind, content, r.start.line, r.start.character, r.end.line, r.end.character }) catch return error.ClientFailed;
}

fn send_content_msg_empty(to: tp.pid_ref, tag: []const u8, file_path: []const u8, row: usize, col: usize) ClientError!void {
    return send_content_msg(to, tag, file_path, row, col, "plaintext", "", null);
}

pub fn publish_diagnostics(self: *Self, to: tp.pid_ref, params_cb: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var uri: ?[]const u8 = null;
    var diagnostics: []const u8 = &.{};
    var iter = params_cb;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&uri)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "diagnostics")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostics)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }

    if (uri == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, uri.?[0..7], "file://")) return error.InvalidTargetURI;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.Uri.percentDecodeBackwards(&file_path_buf, uri.?[7..]);

    try self.send_clear_diagnostics(to, file_path);

    iter = diagnostics;
    len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic))) {
            try self.send_diagnostic(to, file_path, diagnostic);
        } else return error.InvalidMessageField;
    }
}

fn send_diagnostic(_: *Self, to: tp.pid_ref, file_path: []const u8, diagnostic: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var source: []const u8 = "unknown";
    var code: []const u8 = "none";
    var message: []const u8 = "empty";
    var severity: i64 = 1;
    var range: ?Range = null;
    var iter = diagnostic;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "source") or std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&source)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "code")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&code)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "severity")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&severity)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (range == null) return error.InvalidMessageField;
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
    } }) catch return error.ClientFailed;
}

fn send_clear_diagnostics(_: *Self, to: tp.pid_ref, file_path: []const u8) ClientError!void {
    to.send(.{ "cmd", "clear_diagnostics", .{file_path} }) catch return error.ClientFailed;
}

const Range = struct { start: Position, end: Position };
fn read_range(range: []const u8) !Range {
    var iter = range;
    var start: ?Position = null;
    var end: ?Position = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "start")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidMessageField;
            start = try read_position(position);
        } else if (std.mem.eql(u8, field_name, "end")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidMessageField;
            end = try read_position(position);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (start == null or end == null) return error.InvalidMessageField;
    return .{ .start = start.?, .end = end.? };
}

const Position = struct { line: usize, character: usize };
fn read_position(position: []const u8) !Position {
    var iter = position;
    var line: ?usize = 0;
    var character: ?usize = 0;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "line")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&line)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "character")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&character)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (line == null or character == null) return error.InvalidMessageField;
    return .{ .line = line.?, .character = character.? };
}

pub fn show_message(self: *Self, _: tp.pid_ref, params_cb: []const u8) !void {
    var type_: i32 = 0;
    var message: ?[]const u8 = null;
    var iter = params_cb;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "type")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&type_)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const msg = message orelse return;
    if (type_ <= 2)
        self.logger_lsp.err_msg("lsp", msg)
    else
        self.logger_lsp.print("{s}", .{msg});
}

pub fn register_capability(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) ClientError!void {
    _ = params_cb;
    return LSP.send_response(self.allocator, from, cbor_id, null) catch error.ClientFailed;
}

pub fn workDoneProgress_create(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) ClientError!void {
    _ = params_cb;
    return LSP.send_response(self.allocator, from, cbor_id, null) catch error.ClientFailed;
}

pub fn unsupported_lsp_request(self: *Self, from: tp.pid_ref, cbor_id: []const u8, method: []const u8) ClientError!void {
    return LSP.send_error_response(self.allocator, from, cbor_id, LSP.ErrorCode.MethodNotFound, method) catch error.ClientFailed;
}

fn send_lsp_init_request(self: *Self, lsp: *const LSP, project_path: []const u8, project_basename: []const u8, project_uri: []const u8, language_server: []const u8) !void {
    const handler: struct {
        language_server: []const u8,
        lsp: LSP,
        project: *Self,

        pub fn deinit(self_: *@This()) void {
            self_.lsp.pid.deinit();
            std.heap.c_allocator.free(self_.language_server);
        }

        pub fn receive(self_: @This(), _: tp.message) !void {
            self_.lsp.send_notification("initialized", .{}) catch return error.LspFailed;
            if (self_.lsp.pid.expired()) return error.LspFailed;
            self_.project.logger_lsp.print("initialized LSP: {s}", .{fmt_lsp_name_func(self_.language_server)});
        }
    } = .{
        .language_server = try std.heap.c_allocator.dupe(u8, language_server),
        .lsp = .{
            .allocator = lsp.allocator,
            .pid = lsp.pid.clone(),
        },
        .project = self,
    };

    try lsp.send_request(self.allocator, "initialize", .{
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
            .version = "0.0.1",
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
                .diagnostic = .{
                    .dynamicRegistration = true,
                    .relatedDocumentSupport = false,
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

fn fmt_lsp_name_func(bytes: []const u8) std.fmt.Formatter(format_lsp_name_func) {
    return .{ .data = bytes };
}

fn format_lsp_name_func(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
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

pub const GetLineOfFileError = (OutOfMemoryError || std.fs.File.OpenError || std.fs.File.Reader.Error);

fn get_line_of_file(allocator: std.mem.Allocator, file_path: []const u8, line_: usize) GetLineOfFileError![]const u8 {
    const line = line_ + 1;
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    const read_size = try file.reader().readAll(buf);
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
    self.walker = walk_tree.start(self.allocator, self.name) catch blk: {
        self.state.walk_tree = .failed;
        break :blk null;
    };
}

pub fn process_git(self: *Self, parent: tp.pid_ref, m: tp.message) (OutOfMemoryError || error{Exit})!void {
    var value: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (try m.match(.{ tp.any, tp.any, "workspace_path", tp.null_ })) {
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
    } else if (try m.match(.{ tp.any, tp.any, "current_branch", tp.null_ })) {
        self.state.current_branch = .done;
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "current_branch", tp.extract(&value) })) {
        if (self.branch) |p| self.allocator.free(p);
        self.branch = try self.allocator.dupe(u8, value);
        self.state.current_branch = .done;
        try self.loaded(parent);
    } else if (try m.match(.{ tp.any, tp.any, "workspace_files", tp.extract(&path) })) {
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const stat = std.fs.cwd().statFile(path) catch return;
        const file_type: []const u8, const file_icon: []const u8, const file_color: u24 = guess_file_type(path);
        (try self.pending.addOne(self.allocator)).* = .{
            .path = try self.allocator.dupe(u8, path),
            .type = file_type,
            .icon = file_icon,
            .color = file_color,
            .mtime = stat.mtime,
        };
    } else if (try m.match(.{ tp.any, tp.any, "workspace_files", tp.null_ })) {
        self.state.workspace_files = .done;
        try self.loaded(parent);
    } else {
        self.logger_git.err("git", tp.unexpected(m));
    }
}
