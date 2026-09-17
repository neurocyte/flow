const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const Buffer = @import("Buffer");
const FileStore = @import("FileStore");

const Self = @This();

pub const Kind = FileStore.ProbeKind;

pub const Info = struct {
    kind: Kind,
    binary: bool,

    pub fn is_text_file(self: Info) bool {
        return self.kind == .file and !self.binary;
    }
};

pub const Request = struct {
    file: ?cbor.Raw = null,
    dir: ?cbor.Raw = null,
    other: ?cbor.Raw = null,
};

const cache_ttl_us = 5 * std.time.us_per_s;

allocator: std.mem.Allocator,
cache: std.StringHashMapUnmanaged(Entry) = .empty,
pending: std.StringHashMapUnmanaged(Pending) = .empty,
by_id: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
groups: std.AutoHashMapUnmanaged(usize, Group) = .empty,
next_id: usize = 1,

const Entry = struct {
    info: Info,
    at: std.Io.Timestamp,
};

const Pending = struct {
    id: usize,
    started: bool,
    requests: std.ArrayList(Request) = .empty,
    groups: std.ArrayList(usize) = .empty,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        for (self.requests.items) |request| free_request(allocator, request);
        self.requests.deinit(allocator);
        self.groups.deinit(allocator);
    }
};

const Group = struct {
    remaining: usize,
    then: ?cbor.Raw,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var cache = self.cache.iterator();
    while (cache.next()) |kv| self.allocator.free(kv.key_ptr.*);
    self.cache.deinit(self.allocator);
    var pending = self.pending.iterator();
    while (pending.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
        kv.value_ptr.deinit(self.allocator);
    }
    self.pending.deinit(self.allocator);
    self.by_id.deinit(self.allocator);
    var groups = self.groups.valueIterator();
    while (groups.next()) |group| if (group.then) |then| self.allocator.free(then.bytes);
    self.groups.deinit(self.allocator);
}

pub fn get(self: *Self, io: std.Io, file_path: []const u8) ?Info {
    const entry = self.cache.get(file_path) orelse return null;
    if (entry.at.durationTo(.now(io, .awake)).toMicroseconds() > cache_ttl_us) return null;
    return entry.info;
}

pub fn probe(self: *Self, manager: *Buffer.Manager, io: std.Io, file_path: []const u8, request: Request) void {
    if (self.get(io, file_path)) |info| return self.send_request(info, request);
    const owned = self.own_request(request) catch return;
    const pending = self.add_pending(manager, file_path) catch return free_request(self.allocator, owned);
    pending.requests.append(self.allocator, owned) catch free_request(self.allocator, owned);
}

pub fn probe_async(self: *Self, manager: *Buffer.Manager, io: std.Io, file_path: []const u8) void {
    if (self.get(io, file_path)) |_| return;
    _ = self.add_pending(manager, file_path) catch return;
}

pub fn probe_all(self: *Self, manager: *Buffer.Manager, io: std.Io, paths: []const []const u8, then: ?cbor.Raw) void {
    const group_id = self.new_id();
    const owned: ?cbor.Raw = if (then) |t| .{ .bytes = self.allocator.dupe(u8, t.bytes) catch return } else null;
    self.groups.put(self.allocator, group_id, .{ .remaining = 1, .then = owned }) catch {
        if (owned) |t| self.allocator.free(t.bytes);
        return;
    };
    for (paths) |file_path| {
        if (self.get(io, file_path)) |_| continue;
        const pending = self.add_pending(manager, file_path) catch continue;
        pending.groups.append(self.allocator, group_id) catch continue;
        if (self.groups.getPtr(group_id)) |group| group.remaining += 1;
    }
    self.finish_group_member(group_id);
}

pub fn receive(self: *Self, io: std.Io, m: tp.message) bool {
    var id: usize = 0;
    var path: []const u8 = undefined;
    var kind: Kind = undefined;
    var binary: bool = false;
    if (!(m.match(.{ "FS", "probed", tp.extract(&id), tp.extract(&path), tp.extract(&kind), tp.extract(&binary) }) catch false))
        return false;
    const key = self.by_id.get(id) orelse return true;
    _ = self.by_id.remove(id);
    var kv = self.pending.fetchRemove(key) orelse return true;
    defer self.allocator.free(kv.key);
    defer kv.value.deinit(self.allocator);
    const info: Info = .{ .kind = kind, .binary = binary };
    self.store(io, kv.key, info);
    for (kv.value.requests.items) |request| self.send_request(info, request);
    for (kv.value.groups.items) |group_id| self.finish_group_member(group_id);
    return true;
}

pub fn clear(self: *Self) void {
    var it = self.cache.iterator();
    while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
    self.cache.clearRetainingCapacity();
}

pub fn invalidate(self: *Self, file_path: []const u8) void {
    const kv = self.cache.fetchRemove(file_path) orelse return;
    self.allocator.free(kv.key);
}

pub fn start_queued(self: *Self, manager: *Buffer.Manager) void {
    var it = self.pending.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.started) continue;
        kv.value_ptr.started = start(manager, kv.value_ptr.id, kv.key_ptr.*);
    }
}

fn add_pending(self: *Self, manager: *Buffer.Manager, file_path: []const u8) error{OutOfMemory}!*Pending {
    if (self.pending.getPtr(file_path)) |pending| return pending;
    const owned_path = try self.allocator.dupe(u8, file_path);
    errdefer self.allocator.free(owned_path);
    const id = self.new_id();
    try self.by_id.put(self.allocator, id, owned_path);
    errdefer _ = self.by_id.remove(id);
    try self.pending.put(self.allocator, owned_path, .{ .id = id, .started = start(manager, id, file_path) });
    return self.pending.getPtr(owned_path).?;
}

fn start(manager: *Buffer.Manager, id: usize, file_path: []const u8) bool {
    manager.probe(id, file_path) catch |e| {
        if (e != error.FileStoreNotReady) log.err("probe {s} failed: {t}", .{ file_path, e });
        return false;
    };
    return true;
}

fn new_id(self: *Self) usize {
    defer self.next_id += 1;
    return self.next_id;
}

fn store(self: *Self, io: std.Io, file_path: []const u8, info: Info) void {
    const gop = self.cache.getOrPut(self.allocator, file_path) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = self.allocator.dupe(u8, file_path) catch {
            _ = self.cache.remove(file_path);
            return;
        };
    }
    gop.value_ptr.* = .{ .info = info, .at = .now(io, .awake) };
}

fn send_request(_: *Self, info: Info, request: Request) void {
    const message = switch (info.kind) {
        .file => if (info.binary) request.other else request.file,
        .dir => request.dir,
        .none => request.other,
    } orelse return;
    tp.self_pid().send_raw(.{ .buf = message.bytes }) catch {};
}

fn finish_group_member(self: *Self, group_id: usize) void {
    const group = self.groups.getPtr(group_id) orelse return;
    group.remaining -|= 1;
    if (group.remaining > 0) return;
    const kv = self.groups.fetchRemove(group_id) orelse return;
    const then = kv.value.then orelse return;
    defer self.allocator.free(then.bytes);
    tp.self_pid().send_raw(.{ .buf = then.bytes }) catch {};
}

fn own_request(self: *Self, request: Request) error{OutOfMemory}!Request {
    var owned: Request = .{};
    errdefer free_request(self.allocator, owned);
    if (request.file) |m| owned.file = .{ .bytes = try self.allocator.dupe(u8, m.bytes) };
    if (request.dir) |m| owned.dir = .{ .bytes = try self.allocator.dupe(u8, m.bytes) };
    if (request.other) |m| owned.other = .{ .bytes = try self.allocator.dupe(u8, m.bytes) };
    return owned;
}

fn free_request(allocator: std.mem.Allocator, request: Request) void {
    if (request.file) |m| allocator.free(m.bytes);
    if (request.dir) |m| allocator.free(m.bytes);
    if (request.other) |m| allocator.free(m.bytes);
}

const log = std.log.scoped(.file_probe);
