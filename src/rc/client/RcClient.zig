const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const remote = @import("remote");
const common = @import("common");

const log = std.log.scoped(.client);

pid: ?tp.pid,

const module_name = @typeName(@This());
pub const Error = error{ OutOfMemory, ThespianSpawnFailed };

pub fn create(allocator: std.mem.Allocator, path: []const u8) Error!@This() {
    const args = try Process.Args.init(allocator, path);
    errdefer args.deinit();
    return .{ .pid = try tp.spawn_link(allocator, args, Process.start, module_name) };
}

pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, env: ?tp.env, path: []const u8) !@This() {
    const args = try Process.Args.init(allocator, path);
    errdefer args.deinit();
    return .{ .pid = try ctx.spawn_link(args, Process.start, module_name, eh, env) };
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

pub fn disconnect(self: *const @This()) tp.result {
    const pid = self.pid orelse return tp.exit_error(error.Shutdown, null);
    return pid.send(.{"disconnect"});
}

pub fn navigate(self: *const @This(), args: anytype) tp.result {
    return self.request("navigate", args);
}

pub fn request(self: *const @This(), cmd: []const u8, args: anytype) tp.result {
    const pid = self.pid orelse return tp.exit_error(error.Shutdown, null);
    return pid.send(.{ "request", cmd, args });
}

const Process = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    connector: ?tp.pid = null,
    connection: ?tp.pid = null,
    server: ?tp.pid = null,
    disconnecting: bool = false,
    pending: std.ArrayList([]const u8) = .empty,
    next_request_id: u64 = 1,
    outstanding: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    failed: usize = 0,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        path: [:0]const u8,

        fn init(allocator: std.mem.Allocator, path: []const u8) Error!Args {
            return .{ .allocator = allocator, .path = try allocator.dupeSentinel(u8, path, 0) };
        }

        fn deinit(self: Args) void {
            self.allocator.free(self.path);
        }
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| {
            log.err("start failed on {s}: {t}", .{ args.path, e });
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn init(args: Args) !void {
        const self = args.allocator.create(@This()) catch |e| {
            args.deinit();
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .path = args.path,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);
        self.connector = try remote.endpoint.unx.connect(self.allocator, self.path, .file, tp.self_pid().clone());
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        for (self.pending.items) |msg| self.allocator.free(msg);
        self.pending.deinit(self.allocator);
        var it = self.outstanding.valueIterator();
        while (it.next()) |cmd| self.allocator.free(cmd.*);
        self.outstanding.deinit(self.allocator);
        if (self.server) |p| p.deinit();
        if (self.connection) |p| p.deinit();
        if (self.connector) |p| p.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var conn_id: tp.piid = .empty;
        var reason: []const u8 = "";
        var server_version: []const u8 = "";
        var args: cbor.Raw = .empty;
        var cmd: []const u8 = "";
        var request_id: u64 = 0;

        if (try m.match(.{ "request", tp.extract(&cmd), tp.extract(&args) })) {
            try self.send_request(cmd, args);
        } else if (try m.match(.{ "cmd", "navigate", tp.extract(&args) })) {
            try self.send_request("navigate", args);
        } else if (try m.match(.{ "reply", tp.extract(&request_id), tp.extract(&args) })) {
            return self.handle_reply(request_id, args);
        } else if (try m.match(.{ "cmd", tp.extract(&cmd), tp.more })) {
            log.debug("ignoring unsupported command: {s}", .{cmd});
        } else if (try m.match(.{ "A", tp.more })) {
            log.debug("ignoring unsupported selection request", .{});
        } else if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            try self.connected(conn_id);
        } else if (try m.match(.{ "hello", tp.extract(&server_version) })) {
            try self.hello(from, server_version);
        } else if (try m.match(.{"disconnect"})) {
            self.disconnecting = true;
            return self.disconnect_when_done();
        } else if (try m.match(.{"shutdown"})) {
            self.shutdown();
            return self.exit_done();
        } else if (try m.match(.{ "exit", tp.extract(&reason) }) or try m.match(.{ "exit", tp.extract(&reason), tp.more })) {
            return self.handle_exit(from, reason);
        } else {
            var buf: [256]u8 = undefined;
            log.warn("ignoring unexpected message: {s}", .{m.to_json(&buf) catch "(too large)"});
        }
    }

    fn connected(self: *@This(), conn_id: tp.piid) !void {
        const conn = tp.pid.from_id(conn_id) orelse return tp.exit("connection_lost");
        self.connection = conn;
        try conn.link();
        const self_id: remote.protocol.lpiid = .fromInt(tp.self_pid().instance_id().toInt());
        try conn.send(.{ "send", self_id, common.service_name, .{ "hello", common.build_version } });
    }

    fn hello(self: *@This(), from: tp.pid_ref, server_version: []const u8) !void {
        if (self.server != null) return;
        const server = from.clone();
        self.server = server;
        log.info("connected to {s}: {s}", .{ self.path, server_version });
        for (self.pending.items) |msg| try server.send_raw(.{ .buf = msg });
        for (self.pending.items) |msg| self.allocator.free(msg);
        self.pending.clearRetainingCapacity();
        return self.disconnect_when_done();
    }

    fn send_request(self: *@This(), cmd: []const u8, args: cbor.Raw) !void {
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        const cmd_owned = try self.allocator.dupe(u8, cmd);
        errdefer self.allocator.free(cmd_owned);
        try self.outstanding.put(self.allocator, request_id, cmd_owned);
        const m = tp.message.fmt(.{ "request", request_id, cmd, args });
        if (self.server) |server| return server.send_raw(m);
        const msg = try self.allocator.dupe(u8, m.buf);
        errdefer self.allocator.free(msg);
        return self.pending.append(self.allocator, msg);
    }

    fn handle_reply(self: *@This(), request_id: u64, payload: cbor.Raw) !void {
        const entry = self.outstanding.fetchRemove(request_id) orelse {
            log.info("reply {d}: {f}", .{ request_id, tp.message{ .buf = payload.bytes } });
            return;
        };
        const cmd = entry.value;
        defer self.allocator.free(cmd);
        var exit_msg: cbor.Raw = .empty;
        var reason: []const u8 = "";
        if (try cbor.match(payload.bytes, "ok")) {
            log.debug("{s}: ok", .{cmd});
        } else if (try cbor.match(payload.bytes, .{ "error", cbor.extract(&exit_msg) })) {
            self.failed += 1;
            if (try cbor.match(exit_msg.bytes, .{ "exit", cbor.extract(&reason), cbor.more }))
                log.err("{s} failed: {s}", .{ cmd, reason })
            else
                log.err("{s} failed: {f}", .{ cmd, tp.message{ .buf = exit_msg.bytes } });
        } else {
            log.info("{s}: {f}", .{ cmd, tp.message{ .buf = payload.bytes } });
        }
        return self.disconnect_when_done();
    }

    fn disconnect_when_done(self: *@This()) !void {
        if (!self.disconnecting or self.server == null or self.outstanding.count() > 0) return;
        self.shutdown();
        return self.exit_done();
    }

    fn exit_done(self: *@This()) error{Exit} {
        if (self.failed > 0) return tp.exit_fmt("{d} remote request(s) failed", .{self.failed});
        return tp.exit_normal();
    }

    fn handle_exit(self: *@This(), from: tp.pid_ref, reason: []const u8) !void {
        const id = from.instance_id();
        if (self.connector) |connector| if (id == connector.instance_id()) {
            connector.deinit();
            self.connector = null;
            if (std.mem.eql(u8, reason, "normal")) return;
            return tp.exit_fmt("connect to {s} failed: {s}", .{ self.path, reason });
        };
        if (self.connection) |connection| if (id == connection.instance_id()) {
            connection.deinit();
            self.connection = null;
            if (std.mem.eql(u8, reason, "peer_closed")) return self.exit_done();
            return tp.exit(reason);
        };
    }

    fn shutdown(self: *@This()) void {
        if (self.connection) |connection| connection.send(.{ "exit", "shutdown" }) catch {};
        if (self.connector) |connector| connector.send(.{"cancel"}) catch {};
    }
};
