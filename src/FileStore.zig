const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const file_watcher = @import("file_watcher");

pid: tp.pid,

const Self = @This();
const module_name = @typeName(Self);

pub const EventType = file_watcher.EventType;
pub const ObjectType = file_watcher.ObjectType;

pub const Error = error{FileStoreSendFailed};
pub const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

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

fn send(self: *const Self, message: anytype) Error!void {
    return self.pid.send(message) catch error.FileStoreSendFailed;
}

fn is_below(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
}

const Process = struct {
    allocator: std.mem.Allocator,
    logger: log.Logger,
    receiver: Receiver,
    watcher: ?file_watcher.Owned = null,
    files: std.StringHashMapUnmanaged(File) = .empty,
    dirs: std.StringHashMapUnmanaged(usize) = .empty,

    const Receiver = tp.Receiver(*@This());

    const File = struct {
        subscribers: std.AutoHashMapUnmanaged(tp.piid, usize) = .empty,
    };

    fn create() SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .logger = log.logger(module_name),
            .receiver = .init(receive, dtor, self),
        };
        return tp.spawn_link(allocator, self, @This().start, module_name);
    }

    fn dtor(self: *@This()) void {
        if (self.watcher) |*watcher| watcher.deinit();
        var files = self.files.iterator();
        while (files.next()) |p| {
            self.allocator.free(p.key_ptr.*);
            p.value_ptr.subscribers.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
        var dirs = self.dirs.keyIterator();
        while (dirs.next()) |dir| self.allocator.free(dir.*);
        self.dirs.deinit(self.allocator);
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

        if (try cbor.match(m.buf, .{ "FSW", "change", tp.extract(&path), tp.extract(&event_type), tp.extract(&object_type) })) {
            self.handle_change(path, event_type, object_type);
        } else if (try cbor.match(m.buf, .{ "FSW", "rename", tp.extract(&from_path), tp.extract(&path), tp.extract(&object_type) })) {
            self.handle_rename(from_path, path, object_type);
        } else if (try cbor.match(m.buf, .{ "watch", tp.extract(&path) })) {
            self.watch(from.instance_id(), path) catch |e| self.logger.err("watch", e);
        } else if (try cbor.match(m.buf, .{ "unwatch", tp.extract(&path) })) {
            self.unwatch(from.instance_id(), path);
        } else if (try cbor.match(m.buf, .{ "client", tp.extract(&client) })) {
            self.add_client(client);
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", "normal" })) {
            return;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            return error.ExitNormal;
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn add_client(self: *@This(), client: tp.piid) void {
        const pid = tp.pid.from_id(client) orelse return;
        defer pid.deinit();
        pid.send(.{ "FS", "ready" }) catch |e| self.logger.err("client", e);
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
        if (self.files.getPtr(path)) |file|
            expired = self.notify(file, null, .{ "FS", "change", path, event_type, object_type });

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
            if (self.notify(file, from_file, message)) expired = true;
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
