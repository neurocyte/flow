const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const file_watcher = @import("file_watcher");
const root = @import("soft_root").root;

pid: tp.pid,

const Self = @This();
const module_name = @typeName(Self);

pub const EventType = file_watcher.EventType;
pub const ObjectType = file_watcher.ObjectType;

pub const Error = error{FileStoreSendFailed};
pub const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

pub const max_chunk_size = 16 * 1024;
pub const default_chunk_size = max_chunk_size;
pub const default_window = max_window;
pub const max_window = 1024;
const read_quantum = 8;
const max_streams_per_client = 64;

pub const ProbeKind = enum { none, file, dir };

pub const StreamOptions = struct {
    chunk_size: usize = default_chunk_size,
    window: usize = default_window,
};

pub const WriteOptions = struct {
    retain_symlinks: bool = true,
    stream: StreamOptions = .{},
};

pub fn spawn() SpawnError!tp.pid {
    return Process.create();
}

pub fn deinit(self: *Self) void {
    self.pid.deinit();
}

pub fn watch(self: *const Self, abs_path: []const u8) Error!void {
    return self.send(.{ "watch", abs_path });
}

pub fn unwatch(self: *const Self, abs_path: []const u8) Error!void {
    return self.send(.{ "unwatch", abs_path });
}

/// replies with {"FS", "probed", id, path, kind, binary}
pub fn probe(self: *const Self, id: usize, abs_path: []const u8) Error!void {
    return self.send(.{ "probe", id, abs_path });
}

fn send(self: *const Self, message: anytype) Error!void {
    return self.pid.send(message) catch error.FileStoreSendFailed;
}

pub fn reply_id(m: tp.message) ?usize {
    var id: usize = 0;
    return if (m.match(.{ "FS", tp.string, tp.extract(&id), tp.more }) catch false) id else null;
}

const eol = '\n';

pub const GetLineOfFileError = error{OutOfMemory} ||
    std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.ReadPositionalError;

pub fn get_line_of_file(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, line: usize) GetLineOfFileError![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    const read_size = try file.readPositionalAll(io, buf, 0);

    var current: usize = 0;
    var start: usize = 0;
    for (buf[0..read_size], 0..) |c, i| {
        if (c != eol) continue;
        if (current == line) return allocator.dupe(u8, buf[start..i]);
        current += 1;
        start = i + 1;
    }
    if (current == line) return allocator.dupe(u8, buf[start..read_size]);
    return allocator.dupe(u8, "");
}

fn clamp_chunk_size(n: usize) usize {
    return std.math.clamp(n, 1, max_chunk_size);
}

fn clamp_window(n: usize) usize {
    return std.math.clamp(n, 1, max_window);
}

fn ack_interval(window: usize) usize {
    return @max(1, window / 2);
}

const perf_log = std.log.scoped(.file_store);

fn us_since(io: std.Io, t: std.Io.Timestamp) i64 {
    return t.durationTo(.now(io, .awake)).toMicroseconds();
}

fn to_ms(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

fn ns_to_ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn is_below(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
}

pub const FileOwner = struct { uid: std.Io.File.Uid, gid: std.Io.File.Gid };

pub fn get_file_owner(file: std.Io.File) ?FileOwner {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true, .GID = true }, &stx);
            if (linux.errno(rc) != .SUCCESS or !stx.mask.UID or !stx.mask.GID) return null;
            return .{ .uid = stx.uid, .gid = stx.gid };
        },
        .macos, .freebsd => {
            var st: std.c.Stat = undefined;
            if (std.c.fstat(file.handle, &st) != 0) return null;
            return .{ .uid = st.uid, .gid = st.gid };
        },
        else => return null,
    }
}

pub const ReceiveError = Error || error{ OutOfMemory, FileStoreStreamFailed, FileStoreProtocolError };

pub const StreamResult = enum { pending, done };

fn copy_error_name(buf: []u8, name: []const u8) []const u8 {
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

pub const ReadStream = struct {
    allocator: std.mem.Allocator,
    id: usize,
    ack_interval: usize,
    exists: bool = false,
    content: std.ArrayList(u8) = .empty,
    next_seq: usize = 0,
    acked: usize = 0,
    error_buf: [64]u8 = undefined,
    error_name: []const u8 = "",

    pub fn start(store: *const Self, allocator: std.mem.Allocator, id: usize, abs_path: []const u8, options: StreamOptions) Error!ReadStream {
        const window = clamp_window(options.window);
        try store.send(.{ "read", id, abs_path, clamp_chunk_size(options.chunk_size), window });
        return .{ .allocator = allocator, .id = id, .ack_interval = ack_interval(window) };
    }

    pub fn receive(self: *ReadStream, store: *const Self, m: tp.message) ReceiveError!StreamResult {
        var id: usize = 0;
        var path: []const u8 = undefined;
        var size: u64 = 0;
        var seq: usize = 0;
        var bytes: cbor.Bytes = .empty;
        var op: []const u8 = undefined;
        var name: []const u8 = undefined;
        if (m.match(.{ "FS", "read_chunk", tp.extract(&id), tp.extract(&seq), tp.extract(&bytes) }) catch false) {
            if (id != self.id) return .pending;
            if (seq != self.next_seq) return error.FileStoreProtocolError;
            try self.content.appendSlice(self.allocator, bytes.data);
            self.next_seq += 1;
            if (self.next_seq - self.acked >= self.ack_interval) {
                try store.send(.{ "read_ack", self.id, self.next_seq - 1 });
                self.acked = self.next_seq;
            }
        } else if (m.match(.{ "FS", "read_begin", tp.extract(&id), tp.extract(&path), tp.extract(&self.exists), tp.extract(&size) }) catch false) {
            if (id != self.id) return .pending;
            try self.content.ensureTotalCapacity(self.allocator, @intCast(size));
        } else if (m.match(.{ "FS", "read_done", tp.extract(&id) }) catch false) {
            if (id == self.id) return .done;
        } else if (m.match(.{ "FS", "error", tp.extract(&id), tp.extract(&op), tp.extract(&name) }) catch false) {
            if (id != self.id) return .pending;
            self.error_name = copy_error_name(&self.error_buf, name);
            return error.FileStoreStreamFailed;
        }
        return .pending;
    }

    pub fn cancel(self: *ReadStream, store: *const Self) void {
        store.send(.{ "read_cancel", self.id }) catch {};
    }

    pub fn take_content(self: *ReadStream) error{OutOfMemory}![]u8 {
        return self.content.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *ReadStream) void {
        self.content.deinit(self.allocator);
    }
};

pub const WriteStream = struct {
    allocator: std.mem.Allocator,
    id: usize,
    content: []const u8,
    chunk_size: usize,
    window: usize,
    offset: usize = 0,
    next_seq: usize = 0,
    acked: usize = 0,
    committed: bool = false,
    error_buf: [64]u8 = undefined,
    error_name: []const u8 = "",

    pub fn start(store: *const Self, allocator: std.mem.Allocator, id: usize, abs_path: []const u8, content: []const u8, options: WriteOptions) (Error || error{OutOfMemory})!WriteStream {
        var self: WriteStream = .{
            .allocator = allocator,
            .id = id,
            .content = try allocator.dupe(u8, content),
            .chunk_size = clamp_chunk_size(options.stream.chunk_size),
            .window = clamp_window(options.stream.window),
        };
        errdefer allocator.free(self.content);
        try store.send(.{ "write_begin", id, abs_path, @as(u64, self.content.len), options.retain_symlinks, self.window });
        try self.pump(store);
        return self;
    }

    fn pump(self: *WriteStream, store: *const Self) Error!void {
        const text = self.content;
        while (self.offset < text.len and self.next_seq - self.acked < self.window) {
            const n = @min(self.chunk_size, text.len - self.offset);
            try store.send(.{ "write_chunk", self.id, self.next_seq, cbor.Bytes.init(text[self.offset..][0..n]) });
            self.offset += n;
            self.next_seq += 1;
        }
        if (self.offset == text.len and !self.committed) {
            try store.send(.{ "write_commit", self.id });
            self.committed = true;
        }
    }

    pub fn receive(self: *WriteStream, store: *const Self, m: tp.message) ReceiveError!StreamResult {
        var id: usize = 0;
        var seq: usize = 0;
        var path: []const u8 = undefined;
        var op: []const u8 = undefined;
        var name: []const u8 = undefined;
        if (m.match(.{ "FS", "write_ack", tp.extract(&id), tp.extract(&seq) }) catch false) {
            if (id != self.id) return .pending;
            self.acked = @max(self.acked, seq + 1);
            try self.pump(store);
        } else if (m.match(.{ "FS", "write_done", tp.extract(&id), tp.extract(&path) }) catch false) {
            if (id == self.id) return .done;
        } else if (m.match(.{ "FS", "error", tp.extract(&id), tp.extract(&op), tp.extract(&name) }) catch false) {
            if (id != self.id) return .pending;
            self.error_name = copy_error_name(&self.error_buf, name);
            return error.FileStoreStreamFailed;
        }
        return .pending;
    }

    pub fn abort(self: *WriteStream, store: *const Self) void {
        store.send(.{ "write_abort", self.id }) catch {};
    }

    pub fn deinit(self: *WriteStream) void {
        self.allocator.free(self.content);
    }
};

const Fingerprint = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: i96,

    fn of(stat: std.Io.File.Stat) Fingerprint {
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds };
    }

    fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime;
    }
};

const Process = struct {
    allocator: std.mem.Allocator,
    logger: log.Logger,
    receiver: Receiver,
    parent: tp.pid,
    watcher: ?file_watcher.Owned = null,
    files: std.StringHashMapUnmanaged(File) = .empty,
    dirs: std.StringHashMapUnmanaged(usize) = .empty,
    clients: std.AutoHashMapUnmanaged(tp.piid, usize) = .empty,
    streams: std.AutoHashMapUnmanaged(StreamKey, Stream) = .empty,
    own_writes: std.StringHashMapUnmanaged(Fingerprint) = .empty,

    const Receiver = tp.Receiver(*@This());

    const File = struct {
        subscribers: std.AutoHashMapUnmanaged(tp.piid, usize) = .empty,
    };

    const StreamKey = struct { client: tp.piid, id: usize };

    const Stream = union(enum) {
        read: ReadState,
        write: WriteState,

        fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
            const io = root.get_io();
            switch (self.*) {
                .read => |*s| {
                    s.file.close(io);
                    s.client.deinit();
                    allocator.free(s.path);
                },
                .write => |*s| {
                    s.atomic.deinit(io);
                    s.client.deinit();
                    allocator.free(s.path);
                    allocator.free(s.target);
                },
            }
        }
    };

    const ReadState = struct {
        client: tp.pid,
        path: []const u8,
        file: std.Io.File,
        size: u64,
        offset: u64 = 0,
        next_seq: usize = 0,
        acked: usize = 0,
        chunk_size: usize,
        window: usize,
        fingerprint: Fingerprint,
        continue_pending: bool = false,
        started: std.Io.Timestamp,
        read_ns: i96 = 0,
    };

    const WriteState = struct {
        client: tp.pid,
        path: []const u8,
        target: []const u8, // symlink resolved
        atomic: std.Io.File.Atomic,
        size: u64,
        received: u64 = 0,
        next_seq: usize = 0,
        acked: usize = 0,
        ack_interval: usize,
        orig: ?Orig,
        started: std.Io.Timestamp,
        begin_us: i64,
        write_ns: i96 = 0,
    };

    const Orig = struct { permissions: std.Io.File.Permissions, owner: ?FileOwner };

    fn create() SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .logger = log.logger(module_name),
            .receiver = .init(receive, dtor, self),
            .parent = tp.self_pid().clone(),
        };
        return tp.spawn_link(allocator, self, @This().start, module_name);
    }

    fn dtor(self: *@This()) void {
        if (self.watcher) |*watcher| watcher.deinit();
        var streams = self.streams.valueIterator();
        while (streams.next()) |stream| stream.deinit(self.allocator);
        self.streams.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        var own_writes = self.own_writes.keyIterator();
        while (own_writes.next()) |path| self.allocator.free(path.*);
        self.own_writes.deinit(self.allocator);
        var files = self.files.iterator();
        while (files.next()) |p| {
            self.allocator.free(p.key_ptr.*);
            p.value_ptr.subscribers.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
        var dirs = self.dirs.keyIterator();
        while (dirs.next()) |dir| self.allocator.free(dir.*);
        self.dirs.deinit(self.allocator);
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *@This()) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            else => {
                const err = tp.exit_error(e, @errorReturnTrace());
                self.logger.err("receive", err);
            },
        };
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        var path: []const u8 = undefined;
        var from_path: []const u8 = undefined;
        var event_type: EventType = undefined;
        var object_type: ObjectType = undefined;
        var client: tp.piid = undefined;
        var id: usize = 0;
        var seq: usize = 0;
        var chunk_size: usize = 0;
        var window: usize = 0;
        var size: u64 = 0;
        var retain_symlinks: bool = true;
        var bytes: cbor.Bytes = .empty;

        if (try cbor.match(m.buf, .{ "write_chunk", tp.extract(&id), tp.extract(&seq), tp.extract(&bytes) })) {
            self.write_chunk(.{ .client = from.instance_id(), .id = id }, seq, bytes.data);
        } else if (try cbor.match(m.buf, .{ "read_ack", tp.extract(&id), tp.extract(&seq) })) {
            self.read_ack(.{ .client = from.instance_id(), .id = id }, seq);
        } else if (try cbor.match(m.buf, .{ "read_continue", tp.extract(&client), tp.extract(&id) })) {
            self.read_continue(.{ .client = client, .id = id });
        } else if (try cbor.match(m.buf, .{ "FSW", "change", tp.extract(&path), tp.extract(&event_type), tp.extract(&object_type) })) {
            self.handle_change(path, event_type, object_type);
        } else if (try cbor.match(m.buf, .{ "FSW", "rename", tp.extract(&from_path), tp.extract(&path), tp.extract(&object_type) })) {
            self.handle_rename(from_path, path, object_type);
        } else if (try cbor.match(m.buf, .{ "read", tp.extract(&id), tp.extract(&path), tp.extract(&chunk_size), tp.extract(&window) })) {
            self.read_begin(from, id, path, chunk_size, window);
        } else if (try cbor.match(m.buf, .{ "read_cancel", tp.extract(&id) })) {
            self.remove_stream(.{ .client = from.instance_id(), .id = id });
        } else if (try cbor.match(m.buf, .{ "write_begin", tp.extract(&id), tp.extract(&path), tp.extract(&size), tp.extract(&retain_symlinks), tp.extract(&window) })) {
            self.write_begin(from, id, path, size, retain_symlinks, window);
        } else if (try cbor.match(m.buf, .{ "write_commit", tp.extract(&id) })) {
            self.write_commit(.{ .client = from.instance_id(), .id = id });
        } else if (try cbor.match(m.buf, .{ "write_abort", tp.extract(&id) })) {
            self.remove_stream(.{ .client = from.instance_id(), .id = id });
        } else if (try cbor.match(m.buf, .{ "probe", tp.extract(&id), tp.extract(&path) })) {
            probe_path(from, id, path);
        } else if (try cbor.match(m.buf, .{ "watch", tp.extract(&path) })) {
            if (self.ensure_client(from))
                self.watch(from.instance_id(), path) catch |e| self.logger.err("watch", e);
        } else if (try cbor.match(m.buf, .{ "unwatch", tp.extract(&path) })) {
            self.unwatch(from.instance_id(), path);
        } else if (try cbor.match(m.buf, .{ "client", tp.extract(&client) })) {
            self.add_client(client);
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            return self.handle_exit(from, m);
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn handle_exit(self: *@This(), from: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        const piid = from.instance_id();
        if (self.clients.contains(piid))
            return self.client_exited(piid);
        if (self.watcher) |*watcher| if (watcher.pid.instance_id() == piid) {
            watcher.pid.deinit();
            self.watcher = null;
            if (!try cbor.match(m.buf, .{ "exit", "normal" }))
                self.logger.print_err("file_store", "file watcher exited: {f}", .{m});
            return;
        };
        if (self.parent.instance_id() == piid)
            return error.ExitNormal;
        if (try cbor.match(m.buf, .{ "exit", "normal" }))
            return;
        return error.ExitNormal;
    }

    fn ensure_client(self: *@This(), client: tp.pid_ref) bool {
        const piid = client.instance_id();
        if (self.clients.contains(piid)) return true;
        client.link() catch {
            self.logger.print_err("file_store", "failed to link client", .{});
            return false;
        };
        self.clients.put(self.allocator, piid, 0) catch return false;
        return true;
    }

    fn add_client(self: *@This(), client: tp.piid) void {
        const pid = tp.pid.from_id(client) orelse return;
        defer pid.deinit();
        if (!self.ensure_client(pid.ref())) return;
        pid.send(.{ "FS", "ready" }) catch |e| self.logger.err("client", e);
    }

    fn client_exited(self: *@This(), client: tp.piid) void {
        var keys: std.ArrayList(StreamKey) = .empty;
        defer keys.deinit(self.allocator);
        var streams = self.streams.keyIterator();
        while (streams.next()) |key| if (key.client == client)
            keys.append(self.allocator, key.*) catch {};
        for (keys.items) |key| self.remove_stream(key);

        var released: std.ArrayList([]const u8) = .empty;
        defer released.deinit(self.allocator);
        var files = self.files.iterator();
        while (files.next()) |p| {
            if (!p.value_ptr.subscribers.remove(client)) continue;
            if (p.value_ptr.subscribers.count() == 0)
                released.append(self.allocator, p.key_ptr.*) catch {};
        }
        for (released.items) |path| self.release_file(path);

        _ = self.clients.remove(client);
    }

    fn add_stream(self: *@This(), key: StreamKey, stream: Stream) error{ OutOfMemory, TooManyStreams, DuplicateStreamId }!void {
        const count = self.clients.getPtr(key.client) orelse return error.OutOfMemory;
        if (count.* >= max_streams_per_client) return error.TooManyStreams;
        const gop = try self.streams.getOrPut(self.allocator, key);
        if (gop.found_existing) return error.DuplicateStreamId;
        gop.value_ptr.* = stream;
        count.* += 1;
    }

    fn remove_stream(self: *@This(), key: StreamKey) void {
        var kv = self.streams.fetchRemove(key) orelse return;
        kv.value.deinit(self.allocator);
        if (self.clients.getPtr(key.client)) |count| count.* -|= 1;
    }

    fn send_error(to: tp.pid_ref, id: usize, op: []const u8, name: []const u8) void {
        to.send(.{ "FS", "error", id, op, name }) catch {};
    }

    fn fail_stream(self: *@This(), key: StreamKey, op: []const u8, name: []const u8) void {
        const stream = self.streams.getPtr(key) orelse return;
        const client = switch (stream.*) {
            .read => |*s| s.client.ref(),
            .write => |*s| s.client.ref(),
        };
        send_error(client, key.id, op, name);
        self.remove_stream(key);
    }

    fn read_begin(self: *@This(), from: tp.pid_ref, id: usize, path: []const u8, chunk_size: usize, window: usize) void {
        if (!self.ensure_client(from)) return send_error(from, id, "read", "ClientLinkFailed");
        const io = root.get_io();
        const started: std.Io.Timestamp = .now(io, .awake);
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => {
                from.send(.{ "FS", "read_begin", id, path, false, @as(u64, 0) }) catch {};
                from.send(.{ "FS", "read_done", id }) catch {};
                return;
            },
            else => return send_error(from, id, "read", @errorName(e)),
        };
        const stat = file.stat(io) catch |e| {
            file.close(io);
            return send_error(from, id, "read", @errorName(e));
        };
        if (stat.kind == .directory) {
            file.close(io);
            return send_error(from, id, "read", "IsDir");
        }
        const owned_path = self.allocator.dupe(u8, path) catch {
            file.close(io);
            return send_error(from, id, "read", "OutOfMemory");
        };
        const key: StreamKey = .{ .client = from.instance_id(), .id = id };
        self.add_stream(key, .{ .read = .{
            .client = from.clone(),
            .path = owned_path,
            .file = file,
            .size = stat.size,
            .chunk_size = clamp_chunk_size(chunk_size),
            .window = clamp_window(window),
            .fingerprint = .of(stat),
            .started = started,
        } }) catch |e| {
            file.close(io);
            self.allocator.free(owned_path);
            return send_error(from, id, "read", @errorName(e));
        };
        from.send(.{ "FS", "read_begin", id, path, true, stat.size }) catch {};
        self.read_pump(key);
    }

    fn read_ack(self: *@This(), key: StreamKey, seq: usize) void {
        const stream = self.streams.getPtr(key) orelse return;
        switch (stream.*) {
            .read => |*s| s.acked = @max(s.acked, seq + 1),
            else => return,
        }
        self.read_pump(key);
    }

    fn read_continue(self: *@This(), key: StreamKey) void {
        const stream = self.streams.getPtr(key) orelse return;
        switch (stream.*) {
            .read => |*s| s.continue_pending = false,
            else => return,
        }
        self.read_pump(key);
    }

    fn read_pump(self: *@This(), key: StreamKey) void {
        const io = root.get_io();
        const stream = self.streams.getPtr(key) orelse return;
        const s = switch (stream.*) {
            .read => |*s| s,
            else => return,
        };
        var buf: [max_chunk_size]u8 = undefined;
        var sent: usize = 0;
        while (true) {
            if (s.offset >= s.size) return self.read_finish(key);
            if (s.next_seq - s.acked >= s.window) return;
            if (sent >= read_quantum) {
                if (!s.continue_pending) {
                    s.continue_pending = true;
                    tp.self_pid().send(.{ "read_continue", key.client, key.id }) catch {};
                }
                return;
            }
            const n: usize = @intCast(@min(@as(u64, s.chunk_size), s.size - s.offset));
            const read_started: std.Io.Timestamp = .now(io, .awake);
            const got = s.file.readPositionalAll(io, buf[0..n], s.offset) catch |e|
                return self.fail_stream(key, "read", @errorName(e));
            s.read_ns += read_started.durationTo(.now(io, .awake)).nanoseconds;
            if (got != n) return self.fail_stream(key, "read", "FileChangedDuringRead");
            s.client.send(.{ "FS", "read_chunk", key.id, s.next_seq, cbor.Bytes.init(buf[0..got]) }) catch {};
            s.offset += got;
            s.next_seq += 1;
            sent += 1;
        }
    }

    fn read_finish(self: *@This(), key: StreamKey) void {
        const stream = self.streams.getPtr(key) orelse return;
        const s = switch (stream.*) {
            .read => |*s| s,
            else => return,
        };
        const stat = s.file.stat(root.get_io()) catch |e| return self.fail_stream(key, "read", @errorName(e));
        if (!Fingerprint.of(stat).eql(s.fingerprint))
            return self.fail_stream(key, "read", "FileChangedDuringRead");
        perf_log.info("read {s} total {d:.3}ms bytes {d} chunks {d} [read {d:.3}]", .{
            s.path,
            to_ms(us_since(root.get_io(), s.started)),
            s.size,
            s.next_seq,
            ns_to_ms(s.read_ns),
        });
        s.client.send(.{ "FS", "read_done", key.id }) catch {};
        self.remove_stream(key);
    }

    fn write_begin(self: *@This(), from: tp.pid_ref, id: usize, path: []const u8, size: u64, retain_symlinks: bool, window: usize) void {
        if (!self.ensure_client(from)) return send_error(from, id, "write", "ClientLinkFailed");
        const io = root.get_io();
        const started: std.Io.Timestamp = .now(io, .awake);
        const owned_path = self.allocator.dupe(u8, path) catch return send_error(from, id, "write", "OutOfMemory");
        const target = self.resolve_symlink(io, path, retain_symlinks) catch {
            self.allocator.free(owned_path);
            return send_error(from, id, "write", "OutOfMemory");
        };
        const orig = read_orig(io, target);
        var atomic = std.Io.Dir.cwd().createFileAtomic(io, target, .{ .replace = true, .make_path = true }) catch |e| {
            self.allocator.free(owned_path);
            self.allocator.free(target);
            return send_error(from, id, "write", @errorName(e));
        };
        const key: StreamKey = .{ .client = from.instance_id(), .id = id };
        self.add_stream(key, .{ .write = .{
            .client = from.clone(),
            .path = owned_path,
            .target = target,
            .atomic = atomic,
            .size = size,
            .ack_interval = ack_interval(clamp_window(window)),
            .orig = orig,
            .started = started,
            .begin_us = us_since(io, started),
        } }) catch |e| {
            atomic.deinit(io);
            self.allocator.free(owned_path);
            self.allocator.free(target);
            return send_error(from, id, "write", @errorName(e));
        };
    }

    fn resolve_symlink(self: *@This(), io: std.Io, path: []const u8, retain_symlinks: bool) error{OutOfMemory}![]const u8 {
        if (!retain_symlinks) return self.allocator.dupe(u8, path);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.cwd().readLink(io, path, &buf) catch return self.allocator.dupe(u8, path);
        const link = buf[0..len];
        if (std.fs.path.isAbsolute(link)) return self.allocator.dupe(u8, link);
        const dir = std.fs.path.dirname(path) orelse return self.allocator.dupe(u8, link);
        return std.fs.path.join(self.allocator, &.{ dir, link });
    }

    fn read_orig(io: std.Io, target: []const u8) ?Orig {
        if (builtin.os.tag == .windows) return null;
        const f = std.Io.Dir.cwd().openFile(io, target, .{}) catch return null;
        defer f.close(io);
        const stat = f.stat(io) catch return null;
        return .{ .permissions = stat.permissions, .owner = get_file_owner(f) };
    }

    fn write_chunk(self: *@This(), key: StreamKey, seq: usize, data: []const u8) void {
        const stream = self.streams.getPtr(key) orelse return;
        const s = switch (stream.*) {
            .write => |*s| s,
            else => return,
        };
        if (seq != s.next_seq) return self.fail_stream(key, "write", "OutOfOrderChunk");
        if (s.received + data.len > s.size) return self.fail_stream(key, "write", "SizeMismatch");
        const io = root.get_io();
        const write_started: std.Io.Timestamp = .now(io, .awake);
        s.atomic.file.writePositionalAll(io, data, s.received) catch |e|
            return self.fail_stream(key, "write", @errorName(e));
        s.write_ns += write_started.durationTo(.now(io, .awake)).nanoseconds;
        s.received += data.len;
        s.next_seq += 1;
        if (s.next_seq - s.acked >= s.ack_interval) {
            s.client.send(.{ "FS", "write_ack", key.id, s.next_seq - 1 }) catch {};
            s.acked = s.next_seq;
        }
    }

    fn write_commit(self: *@This(), key: StreamKey) void {
        const io = root.get_io();
        const stream = self.streams.getPtr(key) orelse return;
        const s = switch (stream.*) {
            .write => |*s| s,
            else => return,
        };
        if (s.received != s.size) return self.fail_stream(key, "write", "SizeMismatch");
        const commit_started: std.Io.Timestamp = .now(io, .awake);
        if (s.orig) |orig| {
            if (orig.owner) |owner| s.atomic.file.setOwner(io, owner.uid, owner.gid) catch {};
            s.atomic.file.setPermissions(io, orig.permissions) catch {};
        }
        s.atomic.replace(io) catch |e| return self.fail_stream(key, "write", @errorName(e));
        self.record_own_write(s.path);
        perf_log.info("write {s} total {d:.3}ms bytes {d} [begin {d:.3} write {d:.3} commit {d:.3}]", .{
            s.path,
            to_ms(us_since(io, s.started)),
            s.size,
            to_ms(s.begin_us),
            ns_to_ms(s.write_ns),
            to_ms(us_since(io, commit_started)),
        });
        s.client.send(.{ "FS", "write_done", key.id, s.path }) catch {};
        self.remove_stream(key);
    }

    fn probe_path(from: tp.pid_ref, id: usize, path: []const u8) void {
        const io = root.get_io();
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            from.send(.{ "FS", "probed", id, path, ProbeKind.none, false }) catch {};
            return;
        };
        const kind: ProbeKind = if (stat.kind == .directory) .dir else .file;
        const binary = kind == .file and is_binary_file(io, path);
        from.send(.{ "FS", "probed", id, path, kind, binary }) catch {};
    }

    /// sniff the first 1k of `path` for a NUL
    fn is_binary_file(io: std.Io, path: []const u8) bool {
        var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return false;
        return std.mem.indexOfScalar(u8, buf[0..n], 0) != null;
    }

    fn record_own_write(self: *@This(), path: []const u8) void {
        if (!self.files.contains(path)) return;
        const stat = std.Io.Dir.cwd().statFile(root.get_io(), path, .{}) catch return;
        const gop = self.own_writes.getOrPut(self.allocator, path) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch {
                self.own_writes.removeByPtr(gop.key_ptr);
                return;
            };
        }
        gop.value_ptr.* = .of(stat);
    }

    fn is_own_write(self: *@This(), path: []const u8) bool {
        const fingerprint = self.own_writes.get(path) orelse return false;
        if (std.Io.Dir.cwd().statFile(root.get_io(), path, .{})) |stat| {
            if (Fingerprint.of(stat).eql(fingerprint)) return true;
        } else |_| {}
        self.forget_own_write(path);
        return false;
    }

    fn forget_own_write(self: *@This(), path: []const u8) void {
        const kv = self.own_writes.fetchRemove(path) orelse return;
        self.allocator.free(kv.key);
    }

    fn watch(self: *@This(), subscriber: tp.piid, path: []const u8) error{OutOfMemory}!void {
        if (!self.files.contains(path)) {
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try self.files.put(self.allocator, owned, .{});
            self.acquire_dir(owned);
        }
        const file = self.files.getPtr(path).?;
        const count = try file.subscribers.getOrPut(self.allocator, subscriber);
        if (!count.found_existing) count.value_ptr.* = 0;
        count.value_ptr.* += 1;
    }

    fn unwatch(self: *@This(), subscriber: tp.piid, path: []const u8) void {
        const file = self.files.getPtr(path) orelse return;
        const count = file.subscribers.getPtr(subscriber) orelse return;
        count.* -= 1;
        if (count.* == 0) _ = file.subscribers.remove(subscriber);
        if (file.subscribers.count() == 0) self.release_file(path);
    }

    fn release_file(self: *@This(), path: []const u8) void {
        self.forget_own_write(path);
        var kv = self.files.fetchRemove(path) orelse return;
        kv.value.subscribers.deinit(self.allocator);
        self.release_dir(kv.key);
        self.allocator.free(kv.key);
    }

    fn acquire_dir(self: *@This(), file_path: []const u8) void {
        const dir = std.fs.path.dirname(file_path) orelse return;
        const gop = self.dirs.getOrPut(self.allocator, dir) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, dir) catch {
                self.dirs.removeByPtr(gop.key_ptr);
                return;
            };
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* == 1) if (self.get_watcher()) |watcher|
            watcher.watch(gop.key_ptr.*) catch |e| self.logger.err("watch", e);
    }

    fn release_dir(self: *@This(), file_path: []const u8) void {
        const dir = std.fs.path.dirname(file_path) orelse return;
        const count = self.dirs.getPtr(dir) orelse return;
        count.* -= 1;
        if (count.* > 0) return;
        const kv = self.dirs.fetchRemove(dir) orelse return;
        defer self.allocator.free(kv.key);
        if (self.watcher) |watcher| watcher.unwatch(kv.key) catch |e| self.logger.err("unwatch", e);
    }

    fn get_watcher(self: *@This()) ?*file_watcher.Owned {
        if (self.watcher == null) {
            if (!tp.env.get().is("enable_file_watcher")) return null;
            self.watcher = file_watcher.Owned.init(.file_store) catch |e| {
                self.logger.err("file_watcher", e);
                return null;
            };
        }
        return &self.watcher.?;
    }

    fn handle_change(self: *@This(), path: []const u8, event_type: EventType, object_type: ObjectType) void {
        if (event_type == .closed) return;
        var expired = false;
        if (self.files.getPtr(path)) |file| {
            if (!self.is_own_write(path))
                expired = self.notify(file, null, .{ "FS", "change", path, event_type, object_type });
        }

        if (object_type != .file and event_type == .deleted) {
            var it = self.files.iterator();
            while (it.next()) |p| {
                if (!is_below(p.key_ptr.*, path)) continue;
                if (self.notify(p.value_ptr, null, .{ "FS", "change", p.key_ptr.*, EventType.deleted, ObjectType.file }))
                    expired = true;
            }
        }
        if (expired) self.prune_expired();
    }

    fn handle_rename(self: *@This(), from_path: []const u8, to_path: []const u8, object_type: ObjectType) void {
        var expired = false;
        const message = .{ "FS", "rename", from_path, to_path, object_type };
        const from_file = self.files.getPtr(from_path);
        if (from_file) |file|
            expired = self.notify(file, null, message);

        if (self.files.getPtr(to_path)) |file| {
            if (!self.is_own_write(to_path))
                if (self.notify(file, from_file, message)) {
                    expired = true;
                };
        }

        if (object_type != .file) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            var it = self.files.iterator();
            while (it.next()) |p| {
                if (!is_below(p.key_ptr.*, from_path)) continue;
                const new_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ to_path, p.key_ptr.*[from_path.len..] }) catch continue;
                if (self.notify(p.value_ptr, null, .{ "FS", "rename", p.key_ptr.*, new_path, ObjectType.file }))
                    expired = true;
            }
        }
        if (expired) self.prune_expired();
    }

    fn notify(self: *@This(), file: *const File, skip: ?*const File, message: anytype) bool {
        var expired = false;
        var it = file.subscribers.keyIterator();
        while (it.next()) |subscriber| {
            if (skip) |s| if (s.subscribers.contains(subscriber.*)) continue;
            const pid = tp.pid.from_id(subscriber.*) orelse {
                expired = true;
                continue;
            };
            defer pid.deinit();
            pid.send(message) catch |e| self.logger.err("notify", e);
        }
        return expired;
    }

    fn prune_expired(self: *@This()) void {
        var expired: std.ArrayList(tp.piid) = .empty;
        defer expired.deinit(self.allocator);
        var released: std.ArrayList([]const u8) = .empty;
        defer released.deinit(self.allocator);
        var files = self.files.iterator();
        while (files.next()) |p| {
            expired.clearRetainingCapacity();
            var it = p.value_ptr.subscribers.keyIterator();
            while (it.next()) |subscriber| {
                const pid = tp.pid.from_id(subscriber.*) orelse {
                    expired.append(self.allocator, subscriber.*) catch return;
                    continue;
                };
                pid.deinit();
            }
            for (expired.items) |subscriber| _ = p.value_ptr.subscribers.remove(subscriber);
            if (p.value_ptr.subscribers.count() == 0)
                released.append(self.allocator, p.key_ptr.*) catch return;
        }
        for (released.items) |path| self.release_file(path);
    }
};

test {
    _ = @import("FileStore_test.zig");
}
