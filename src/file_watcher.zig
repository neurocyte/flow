const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const nightwatch = @import("nightwatch");
const gitignore = @import("gitignore");
const builtin = @import("builtin");
const root = @import("soft_root").root;

pid: tp.pid_ref,

const Self = @This();
const module_name = @typeName(Self);

pub const EventType = nightwatch.EventType;
pub const ObjectType = nightwatch.ObjectType;

const Watcher = if (builtin.os.tag == .linux)
    nightwatch.Create(.polling)
else
    nightwatch.Default;

const limit_hint = if (builtin.os.tag == .linux)
    "; raise fs.inotify.max_user_watches"
else
    "; raise the open file limit";

pub const Error = error{
    FileWatcherSendFailed,
    ThespianSpawnFailed,
    OutOfMemory,
};
const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

var ulimit_bumped: std.atomic.Value(bool) = .init(false);

pub const Instance = struct {
    name: [:0]const u8,
    tag: [:0]const u8,
    filtered: bool = false,

    pub fn watch(self: Instance, path: []const u8) Error!void {
        return self.send(.{ "watch", path });
    }

    pub fn unwatch(self: Instance, path: []const u8) Error!void {
        return self.send(.{ "unwatch", path });
    }

    pub fn ignore_changed(self: Instance, root_path: []const u8, rel_dir: []const u8) Error!void {
        return self.send(.{ "ignore_changed", root_path, rel_dir });
    }

    pub fn start(self: Instance) SpawnError!void {
        _ = try self.get();
    }

    pub fn shutdown(self: Instance) void {
        const pid = tp.env.get().proc(self.name);
        if (pid.expired()) return;
        pid.send(.{"shutdown"}) catch {};
    }

    fn get(self: Instance) SpawnError!Self {
        const pid = tp.env.get().proc(self.name);
        return if (pid.expired()) self.create() else .{ .pid = pid };
    }

    fn send(self: Instance, message: anytype) Error!void {
        return (try self.get()).pid.send(message) catch error.FileWatcherSendFailed;
    }

    fn create(self: Instance) SpawnError!Self {
        const pid = try Process.create(self);
        defer pid.deinit();
        tp.env.get().proc_set(self.name, pid.ref());
        return .{ .pid = tp.env.get().proc(self.name) };
    }
};

pub const default: Instance = .{ .name = module_name, .tag = "FW", .filtered = true };

pub fn watch(path: []const u8) Error!void {
    return default.watch(path);
}

pub fn unwatch(path: []const u8) Error!void {
    return default.unwatch(path);
}

pub fn start() SpawnError!void {
    return default.start();
}

pub fn shutdown() void {
    default.shutdown();
}

const Root = struct {
    path: []const u8,
    matcher: *gitignore.Matcher,
    mutex: std.Io.Mutex = .init,
};

const Process = struct {
    allocator: std.mem.Allocator,
    instance: Instance,
    parent: tp.pid,
    receiver: Receiver,
    roots: std.ArrayList(*Root) = .empty,
    nw: ?Watcher = null,
    fd_watcher: if (builtin.os.tag == .linux) ?tp.file_descriptor else void,
    handler: Watcher.Handler,

    const Receiver = tp.Receiver(*@This());

    fn create(instance: Instance) SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .instance = instance,
            .parent = tp.self_pid().clone(),
            .receiver = .init(receive, dtor, self),
            .fd_watcher = if (builtin.os.tag == .linux) null else {},
            .handler = .{ .vtable = &vtable },
        };
        return tp.spawn_link(self.allocator, self, @This().start, instance.name);
    }

    fn dtor(self: *@This()) void {
        if (builtin.os.tag == .linux) if (self.fd_watcher) |fd_watcher| fd_watcher.deinit();
        if (self.nw) |*nw| nw.deinit();
        for (self.roots.items) |r| self.free_root(r);
        self.roots.deinit(self.allocator);
        self.parent.deinit();
        self.allocator.destroy(self);
    }

    const vtable: Watcher.Handler.VTable = if (builtin.os.tag == .linux) .{
        .change = handle_change,
        .rename = handle_rename,
        .wait_readable = wait_readable,
        .should_watch = should_watch,
    } else .{
        .change = handle_change,
        .rename = handle_rename,
        .should_watch = should_watch,
    };

    fn start(self: *@This()) tp.result {
        if (builtin.os.tag != .windows) if (!ulimit_bumped.swap(true, .acq_rel)) {
            // Watches require one many fds. Bump the soft NOFILE limit to the hard limit.
            if (std.posix.getrlimit(.NOFILE)) |rl| {
                if (rl.cur < rl.max)
                    std.posix.setrlimit(.NOFILE, .{ .cur = rl.max, .max = rl.max }) catch {};
            } else |_| {}
        };

        _ = tp.set_trap(true);
        self.nw = Watcher.init(root.get_io(), self.allocator, &self.handler) catch |e|
            return tp.exit_error(e, @errorReturnTrace());
        if (builtin.os.tag == .linux) {
            self.fd_watcher = tp.file_descriptor.init(self.instance.name, self.nw.?.poll_fd()) catch |e| {
                std.log.err("file_watcher.start: {}", .{e});
                return tp.exit_error(e, @errorReturnTrace());
            };
            self.fd_watcher.?.wait_read() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        tp.receive(&self.receiver);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            else => {
                const err = tp.exit_error(e, @errorReturnTrace());
                std.log.err("file_watcher.receive: {}", .{err});
                return err;
            },
        };
    }

    fn receive_safe(self: *@This(), _: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        var path: []const u8 = undefined;
        var dir: []const u8 = undefined;
        var tag: []const u8 = undefined;
        var err_code: i64 = 0;
        var err_msg: []const u8 = undefined;

        if (try cbor.match(m.buf, .{ "fd", tp.extract(&tag), "read_ready" })) {
            if (builtin.os.tag == .linux)
                self.nw.?.handle_read_ready() catch |e| std.log.err("file_watcher handle_read_ready: {}", .{e});
        } else if (try cbor.match(m.buf, .{ "fd", tp.extract(&tag), "read_error", tp.extract(&err_code), tp.extract(&err_msg) })) {
            std.log.err("fd read error on {s}: ({d}) {s}", .{ tag, err_code, err_msg });
        } else if (try cbor.match(m.buf, .{ "watch", tp.extract(&path) })) {
            self.add_root(path);
            self.nw.?.watch(path) catch |e| switch (e) {
                error.WatchLimitReached => std.log.err(
                    "file_watcher watch: {s} -> watch limit reached after {d} watches{s}",
                    .{ path, self.nw.?.watch_count(), limit_hint },
                ),
                else => std.log.err("file_watcher watch: {s} -> {}", .{ path, e }),
            };
        } else if (try cbor.match(m.buf, .{ "unwatch", tp.extract(&path) })) {
            self.nw.?.unwatch(path) catch |e| std.log.err("file_watcher unwatch: {s} -> {}", .{ path, e });
            self.remove_root(path);
        } else if (try cbor.match(m.buf, .{ "ignore_changed", tp.extract(&path), tp.extract(&dir) })) {
            self.ignore_changed(path, dir);
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            return error.ExitNormal;
        } else {
            std.log.err("file_watcher.receive: {}", .{tp.unexpected(m)});
        }
    }

    fn should_watch(handler: *Watcher.Handler, path: []const u8, object_type: ObjectType) bool {
        const self: *@This() = @alignCast(@fieldParentPtr("handler", handler));
        const r = self.root_for(path) orelse return true;
        const rel = path[r.path.len..];
        const rel_path = std.mem.trimStart(u8, rel, "/\\");
        if (rel_path.len == 0) return true;
        if (gitignore.in_vcs_metadata_dir(rel_path)) return false;
        const dtype: gitignore.DType = switch (object_type) {
            .file => .file,
            .dir => .dir,
            .unknown => .unknown,
        };
        r.mutex.lockUncancelable(root.get_io());
        defer r.mutex.unlock(root.get_io());
        return !(r.matcher.is_ignored(root.get_io(), rel_path, dtype) catch return true);
    }

    fn root_for(self: *@This(), path: []const u8) ?*Root {
        for (self.roots.items) |r| {
            if (!std.mem.startsWith(u8, path, r.path)) continue;
            if (path.len == r.path.len) return r;
            if (path[r.path.len] == '/' or path[r.path.len] == '\\') return r;
        }
        return null;
    }

    fn add_root(self: *@This(), path: []const u8) void {
        if (!self.instance.filtered) return;
        if (tp.env.get().is("disable_gitignore")) return;
        if (self.root_for(path)) |_| return;
        const r = self.allocator.create(Root) catch return;
        const owned = self.allocator.dupe(u8, std.mem.trimEnd(u8, path, "/\\")) catch {
            self.allocator.destroy(r);
            return;
        };
        const m = gitignore.Sources.open(
            root.get_io(),
            self.allocator,
            root.get_init().environ_map,
            path,
            .{},
        ) catch |e| {
            std.log.err("file_watcher ignore rules: {s} -> {}", .{ path, e });
            self.allocator.free(owned);
            self.allocator.destroy(r);
            return;
        };
        r.* = .{ .path = owned, .matcher = m };
        self.roots.append(self.allocator, r) catch {
            self.free_root(r);
            return;
        };
    }

    fn remove_root(self: *@This(), path: []const u8) void {
        for (self.roots.items, 0..) |r, i| {
            if (!std.mem.eql(u8, r.path, std.mem.trimEnd(u8, path, "/\\"))) continue;
            self.free_root(self.roots.swapRemove(i));
            return;
        }
    }

    fn ignore_changed(self: *@This(), root_path: []const u8, rel_dir: []const u8) void {
        const r = self.root_for(root_path) orelse return;
        r.mutex.lockUncancelable(root.get_io());
        defer r.mutex.unlock(root.get_io());
        r.matcher.invalidate_dir(rel_dir);
    }

    fn free_root(self: *@This(), r: *Root) void {
        gitignore.Sources.close(root.get_io(), self.allocator, r.matcher);
        self.allocator.free(r.path);
        self.allocator.destroy(r);
    }

    fn handle_change(handler: *Watcher.Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        const self: *@This() = @alignCast(@fieldParentPtr("handler", handler));
        if (event_type == .closed) return;
        self.parent.send(.{ self.instance.tag, "change", path, event_type, object_type }) catch |e|
            std.log.err("file_watcher change: {s} -> {}", .{ path, e });
    }

    fn handle_rename(handler: *Watcher.Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        const self: *@This() = @alignCast(@fieldParentPtr("handler", handler));
        self.parent.send(.{ self.instance.tag, "rename", src_path, dst_path, object_type }) catch |e|
            std.log.err("file_watcher rename: {s} -> {}", .{ src_path, e });
    }

    fn wait_readable(handler: *Watcher.Handler) error{HandlerFailed}!Watcher.Handler.ReadableStatus {
        const self: *@This() = @alignCast(@fieldParentPtr("handler", handler));
        if (self.fd_watcher) |fd_watcher| fd_watcher.wait_read() catch |e| {
            std.log.err("file_watcher.wait_readable: {}", .{e});
            return error.HandlerFailed;
        };
        return .will_notify;
    }
};
