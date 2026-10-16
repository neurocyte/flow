const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const remote = @import("remote");
const common = @import("common");
const RcServer = @import("RcServer");
const RcClient = @import("RcClient");

test {
    std.testing.refAllDecls(RcServer);
    std.testing.refAllDecls(RcClient);
}

const ServerTest = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    server: RcServer,
    connector: ?tp.pid = null,
    client_conn: ?tp.pid = null,
    answered: bool = false,
    receiver: tp.Receiver(*@This()),

    const Args = struct { allocator: std.mem.Allocator, path: [:0]const u8 };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .path = args.path,
            .server = try RcServer.create(args.allocator, args.path),
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        try self.server.pid.?.send(.{"sync"});
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.client_conn) |p| p.deinit();
        if (self.connector) |p| p.deinit();
        self.server.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var conn_id: tp.piid = .empty;
        var args: cbor.Raw = .empty;
        var reply_piid: tp.piid = .empty;
        var reply_id: u64 = 0;

        if (self.server.pid) |server| if (from.instance_id() == server.instance_id() and try m.match(.{ "exit", tp.more })) {
            if (!self.answered) return tp.exit("server exited before the request was answered");
            if (!try m.match(.{ "exit", "normal" })) return tp.exit("server treated an injected connection as real");
            return tp.exit("success");
        };

        if (try m.match(.{"synced"})) {
            self.connector = try remote.endpoint.unx.connect(self.allocator, self.path, .file, tp.self_pid().clone());
        } else if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            self.client_conn = tp.pid.from_id(conn_id) orelse return tp.unexpected(m);
            const my_id = remote.protocol.lpiid.fromInt(tp.self_pid().instance_id().toInt());
            try self.client_conn.?.send(.{ "send", my_id, common.service_name, .{ "connected", tp.self_pid().instance_id() } });
            try self.client_conn.?.send(.{ "send", my_id, common.service_name, .{"shutdown"} });
            try self.client_conn.?.send(.{ "send", my_id, common.service_name, .{ "request", 7, "navigate", .{ .file = "foo.zig", .line = 3 } } });
        } else if (try m.match(.{ "cmd", "navigate", tp.extract(&args), .{ "reply", tp.extract(&reply_piid), tp.extract(&reply_id) } })) {
            try expect_navigate_args(args);
            if (reply_id != 7) return tp.unexpected(m);
            try send_reply(reply_piid, reply_id, "ok");
        } else if (try m.match(.{ "reply", 7, "ok" })) {
            self.answered = true;
            try self.server.pid.?.send(.{"shutdown"});
        } else if (try m.match(.{ "exit", "normal" })) {
            return;
        } else {
            return tp.unexpected(m);
        }
    }
};

test "rc_server: request is relayed to the parent and remote control messages are ignored" {
    const allocator = std.testing.allocator;
    std.testing.log_level = .err;

    var ctx = try tp.context.init(allocator, .{});
    defer ctx.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/flow_rc_test_{d}.sock", .{std.c.getpid()}, 0);

    var success = false;
    var exit_handler = tp.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            ok.* = std.mem.eql(u8, status, "success");
        }
    }.handle);

    _ = try ctx.spawn_link(ServerTest.Args{ .allocator = allocator, .path = path }, ServerTest.start, "rc_server_test", &exit_handler, null);
    ctx.run();

    try std.testing.expect(success);
    try std.testing.expect(!socket_file_exists(path));
}

fn expect_navigate_args(args: cbor.Raw) !void {
    var expected_buf: [64]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buf);
    try cbor.writeValue(&expected, .{ .file = "foo.zig", .line = 3 });
    if (!std.mem.eql(u8, expected.buffered(), args.bytes)) return error.UnexpectedNavigateArgs;
}

fn expect_tracked_navigate_args(args: cbor.Raw) !void {
    var expected_buf: [64]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buf);
    try cbor.writeValue(&expected, .{ .file = "foo.zig", .line = 3, .track = RcClient.Track.full });
    if (!std.mem.eql(u8, expected.buffered(), args.bytes)) return error.UnexpectedNavigateArgs;
}

fn send_reply(piid: tp.piid, id: u64, payload: anytype) !void {
    const pid = tp.pid.from_id(piid) orelse return error.ReplyTargetGone;
    defer pid.deinit();
    try pid.send(.{ "reply", id, payload });
}

fn socket_file_exists(path: [:0]const u8) bool {
    return std.c.access(path, 0) == 0;
}

const ClientTest = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    scenario: Scenario,
    server: ?RcServer = null,
    client: ?RcClient = null,
    server_exited: bool = false,
    client_exited: bool = false,
    navigated: bool = false,
    receiver: tp.Receiver(*@This()),

    const Scenario = enum { relay_then_server_shutdown, client_shutdown, connect_failure, no_wait, track };

    const Args = struct { allocator: std.mem.Allocator, path: [:0]const u8, scenario: Scenario };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .path = args.path,
            .scenario = args.scenario,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        switch (args.scenario) {
            .connect_failure => self.client = try RcClient.create(args.allocator, args.path, .none),
            else => {
                self.server = try RcServer.create(args.allocator, args.path);
                try self.server.?.pid.?.send(.{"sync"});
            },
        }
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.client) |*c| c.deinit();
        if (self.server) |*s| s.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var args: cbor.Raw = .empty;
        var reason: []const u8 = "";
        var reply_piid: tp.piid = .empty;
        var reply_id: u64 = 0;

        if (try m.match(.{"synced"})) {
            self.client = try RcClient.create(self.allocator, self.path, if (self.scenario == .track) .full else .none);
            try self.client.?.navigate(.{ .file = "foo.zig", .line = 3 });
            if (self.scenario == .no_wait) try self.client.?.disconnect();
        } else if (try m.match(.{ "cmd", "navigate", tp.extract(&args), .{ "reply", tp.extract(&reply_piid), tp.extract(&reply_id) } })) {
            if (self.scenario == .track) {
                try expect_tracked_navigate_args(args);
                try send_reply(reply_piid, reply_id, "ok");
                try send_reply(reply_piid, reply_id, .{ "navigation", "complete", .{ "BUFID", 42 }, "foo.zig" });
                try send_reply(reply_piid, reply_id, .{ "buffer", "saved", .{ "BUFID", 42 }, "foo.zig" });
                try send_reply(reply_piid, reply_id, .{ "buffer", "hidden", .{ "BUFID", 42 }, "foo.zig" });
                self.navigated = true;
                return;
            }
            try expect_navigate_args(args);
            try send_reply(reply_piid, reply_id, "ok");
            self.navigated = true;
            switch (self.scenario) {
                .relay_then_server_shutdown => self.server.?.pid.?.send(.{"shutdown"}) catch {},
                .client_shutdown => self.client.?.pid.?.send(.{"shutdown"}) catch {},
                .connect_failure => return tp.unexpected(m),
                .no_wait, .track => {},
            }
        } else if (try m.match(.{ "exit", tp.extract(&reason) }) or try m.match(.{ "exit", tp.extract(&reason), tp.more })) {
            if (self.client) |c| if (c.pid) |p| if (p.instance_id() == from.instance_id()) {
                self.client_exited = true;
                const normal = std.mem.eql(u8, reason, "normal");
                switch (self.scenario) {
                    .connect_failure => return if (normal) tp.exit("connect did not fail") else tp.exit("success"),
                    .client_shutdown => {
                        if (!normal) return tp.exit("client shutdown not normal");
                        self.server.?.pid.?.send(.{"shutdown"}) catch {};
                    },
                    .relay_then_server_shutdown => if (!normal) return tp.exit("client disconnect not normal"),
                    .no_wait, .track => {
                        if (!normal) return tp.exit("client exit not normal");
                        if (!self.navigated) return tp.exit("client exited before request was delivered");
                        self.server.?.pid.?.send(.{"shutdown"}) catch {};
                    },
                }
            };
            if (self.server) |s| if (s.pid) |p| if (p.instance_id() == from.instance_id()) {
                self.server_exited = true;
                if (!std.mem.eql(u8, reason, "normal")) return tp.exit("server exit not normal");
            };
            if (self.server_exited and self.client_exited) return tp.exit("success");
        } else {
            return tp.unexpected(m);
        }
    }
};

fn run_client_test(scenario: ClientTest.Scenario) !void {
    const allocator = std.testing.allocator;

    var ctx = try tp.context.init(allocator, .{});
    defer ctx.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/flow_rc_client_test_{d}_{t}.sock", .{ std.c.getpid(), scenario }, 0);

    var status_buf: [128]u8 = undefined;
    var status: []const u8 = "";
    const Status = struct { buf: *[128]u8, out: *[]const u8 };
    var exit_handler = tp.make_exit_handler(Status{ .buf = &status_buf, .out = &status }, struct {
        fn handle(s: Status, msg: []const u8) void {
            const n = @min(msg.len, s.buf.len);
            @memcpy(s.buf[0..n], msg[0..n]);
            s.out.* = s.buf[0..n];
        }
    }.handle);

    _ = try ctx.spawn_link(ClientTest.Args{ .allocator = allocator, .path = path, .scenario = scenario }, ClientTest.start, "rc_client_test", &exit_handler, null);
    ctx.run();

    try std.testing.expectEqualStrings("success", status);
    try std.testing.expect(!socket_file_exists(path));
}

test "rc_client: navigate is relayed and server shutdown disconnects the client" {
    try run_client_test(.relay_then_server_shutdown);
}

test "rc_client: client shutdown disconnects cleanly" {
    try run_client_test(.client_shutdown);
}

test "rc_client: connect failure exits the client with an error" {
    try run_client_test(.connect_failure);
}

test "rc_client: disconnect after queued requests are delivered" {
    try run_client_test(.no_wait);
}

test "rc_client: tracked navigation ends when the buffer is hidden" {
    try run_client_test(.track);
}
