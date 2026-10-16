const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const remote = @import("remote");
const common = @import("common");

const log = std.log.scoped(.server);

pid: ?tp.pid,

const module_name = @typeName(@This());
pub const Error = error{ OutOfMemory, ThespianSpawnFailed };

pub fn create(allocator: std.mem.Allocator, path: []const u8) Error!@This() {
    return .{ .pid = try Process.create(allocator, path) };
}

pub fn deinit(self: *@This()) void {
    if (self.pid) |pid| {
        self.pid = null;
        pid.deinit();
    }
}

pub fn shutdown(self: *@This()) void {
    if (self.pid) |pid| {
        pid.send(.{"shutdown"}) catch {};
        self.deinit();
    }
}

const Process = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    path: [:0]const u8,
    listener: ?tp.pid = null,
    listening: bool = false,
    sync_waiters: std.ArrayList(tp.pid) = .empty,
    connections: std.ArrayList(tp.pid) = .empty,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        parent: tp.pid,
        path: [:0]const u8,
    };

    fn create(allocator: std.mem.Allocator, path: []const u8) Error!tp.pid {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(path_z);
        const parent = tp.self_pid().clone();
        errdefer parent.deinit();
        return tp.spawn_link(allocator, Args{
            .allocator = allocator,
            .parent = parent,
            .path = path_z,
        }, start, module_name);
    }

    fn start(args: Args) tp.result {
        return init(args) catch |e| {
            log.err("start failed on {s}: {t}", .{ args.path, e });
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn init(args: Args) !void {
        const self = args.allocator.create(@This()) catch |e| {
            args.parent.deinit();
            args.allocator.free(args.path);
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .parent = args.parent,
            .path = args.path,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);
        tp.env.get().proc_set(common.service_name, tp.self_pid().ref());
        self.listener = try remote.endpoint.unx.listen(self.allocator, self.path, .file, tp.self_pid().clone());
        try self.listener.?.send(.{ "get", "path" });
        log.info("listening on {s}", .{self.path});
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        for (self.connections.items) |conn| conn.deinit();
        self.connections.deinit(self.allocator);
        for (self.sync_waiters.items) |waiter| waiter.deinit();
        self.sync_waiters.deinit(self.allocator);
        if (self.listener) |p| p.deinit();
        self.parent.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var conn_id: tp.piid = .empty;
        var args: cbor.Raw = .empty;
        var reason: []const u8 = "";
        var client_version: []const u8 = "";
        var request_id: u64 = 0;
        var cmd: []const u8 = "";

        if (try m.match(.{ "hello", tp.extract(&client_version) })) {
            log.info("client connected: {s}", .{client_version});
            try from.send(.{ "hello", common.build_version });
        } else if (try m.match(.{ "request", tp.extract(&request_id), tp.extract(&cmd), tp.extract(&args) })) {
            try self.parent.send(.{ "cmd", cmd, args, .{ "reply", from.instance_id(), request_id } });
        } else if (self.is_listener(from) and try m.match(.{ "connected", tp.extract(&conn_id) })) {
            const conn = tp.pid.from_id(conn_id) orelse return;
            errdefer conn.deinit();
            try conn.link();
            try self.connections.append(self.allocator, conn);
        } else if (self.is_listener(from) and try m.match(.{ "path", tp.any })) {
            self.listening = true;
            for (self.sync_waiters.items) |waiter| {
                waiter.send(.{"synced"}) catch {};
                waiter.deinit();
            }
            self.sync_waiters.clearRetainingCapacity();
        } else if (self.is_parent(from) and try m.match(.{"sync"})) {
            if (self.listening) return from.send(.{"synced"});
            try self.sync_waiters.append(self.allocator, from.clone());
        } else if (try m.match(.{"shutdown"})) {
            self.shutdown();
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", tp.extract(&reason) }) or try m.match(.{ "exit", tp.extract(&reason), tp.more })) {
            return self.handle_exit(from, reason);
        } else {
            var buf: [256]u8 = undefined;
            log.warn("ignoring unexpected message: {s}", .{m.to_json(&buf) catch "(too large)"});
        }
    }

    fn is_listener(self: *const @This(), from: tp.pid_ref) bool {
        const listener = self.listener orelse return false;
        return from.instance_id() == listener.instance_id();
    }

    fn is_parent(self: *const @This(), from: tp.pid_ref) bool {
        return from.instance_id() == self.parent.instance_id();
    }

    fn handle_exit(self: *@This(), from: tp.pid_ref, reason: []const u8) !void {
        const id = from.instance_id();
        if (id == self.parent.instance_id()) {
            self.shutdown();
            return tp.exit_normal();
        }
        if (self.listener) |listener| if (id == listener.instance_id()) {
            log.err("listener on {s} exited: {s}", .{ self.path, reason });
            self.shutdown();
            return tp.exit(reason);
        };
        for (self.connections.items, 0..) |conn, i| if (id == conn.instance_id()) {
            conn.deinit();
            _ = self.connections.swapRemove(i);
            return;
        };
    }

    fn shutdown(self: *@This()) void {
        for (self.connections.items) |conn| conn.send(.{ "exit", "shutdown" }) catch {};
        if (self.listener) |listener| listener.send(.{"close"}) catch {};
    }
};
