const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const remote = @import("remote");
const common = @import("common");

const module_name = @typeName(@This());

pub const timeout_ms = 250;

pub const Result = struct {
    path: [:0]const u8,
    state: State = .not_responding,
    version: []const u8 = "",
    pid: i64 = 0,
    projects: []const []const u8 = &.{},
    reason: []const u8 = "",

    pub const State = enum { not_responding, live, failed };

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        for (self.projects) |project| allocator.free(project);
        allocator.free(self.projects);
        allocator.free(self.reason);
        self.* = .{ .path = self.path };
    }
};

/// probe every server in results at once and fill in the results before exiting
/// results must stay valid and untouched until the probe exits
pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, results: []Result) !void {
    const pid = try ctx.spawn_link(Prober.Args{ .allocator = allocator, .results = results }, Prober.start, module_name, eh, null);
    pid.deinit();
}

const Prober = struct {
    allocator: std.mem.Allocator,
    results: []Result,
    children: []?tp.pid,
    remaining: usize,
    timer: ?tp.timeout = null,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        results: []Result,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const children = try args.allocator.alloc(?tp.pid, args.results.len);
        @memset(children, null);
        const self = args.allocator.create(@This()) catch |e| {
            args.allocator.free(children);
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .results = args.results,
            .children = children,
            .remaining = args.results.len,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);
        if (self.remaining == 0) return tp.exit_normal();
        for (self.results, 0..) |result, i|
            self.children[i] = try Connection.spawn(self.allocator, result.path, i);
        self.timer = try tp.timeout.init_ms(timeout_ms, tp.message.fmt(.{"timeout"}));
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.timer) |*timer| {
            timer.cancel() catch {};
            timer.deinit();
        }
        for (self.children) |child| if (child) |pid| {
            pid.send(.{"shutdown"}) catch {};
            pid.deinit();
        };
        self.allocator.free(self.children);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var index: usize = 0;
        var version: []const u8 = "";
        var pid: i64 = 0;
        var project: []const u8 = "";
        var background: cbor.Raw = .empty;
        var reason: []const u8 = "";

        if (try m.match(.{ "probe", tp.extract(&index), "live", tp.extract(&version), tp.extract(&pid), tp.extract(&project), tp.extract(&background) })) {
            const result = self.pending(index) orelse return;
            result.version = try self.allocator.dupe(u8, version);
            result.projects = try self.dupe_projects(project, background);
            result.pid = pid;
            result.state = .live;
            return self.done(index);
        } else if (try m.match(.{ "probe", tp.extract(&index), "failed", tp.extract(&reason) })) {
            return self.failed(index, reason);
        } else if (try m.match(.{"timeout"})) {
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", tp.extract(&reason), tp.more })) {
            if (std.mem.eql(u8, reason, "normal")) return;
            for (self.children, 0..) |child, i| if (child) |p| if (p.instance_id() == from.instance_id())
                return self.failed(i, reason);
        }
    }

    fn dupe_projects(self: *@This(), project: []const u8, background: cbor.Raw) ![]const []const u8 {
        var projects: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (projects.items) |p| self.allocator.free(p);
            projects.deinit(self.allocator);
        }
        if (project.len > 0) try projects.append(self.allocator, try self.allocator.dupe(u8, project));
        var iter = background.bytes;
        var count = try cbor.decodeArrayHeader(&iter);
        while (count > 0) : (count -= 1) {
            var project_directory: []const u8 = undefined;
            if (!try cbor.matchValue(&iter, cbor.extract(&project_directory))) return error.InvalidInstanceInfo;
            try projects.append(self.allocator, try self.allocator.dupe(u8, project_directory));
        }
        return projects.toOwnedSlice(self.allocator);
    }

    fn pending(self: *@This(), index: usize) ?*Result {
        if (index >= self.results.len or self.children[index] == null) return null;
        return &self.results[index];
    }

    fn failed(self: *@This(), index: usize, reason: []const u8) !void {
        const result = self.pending(index) orelse return;
        result.reason = try self.allocator.dupe(u8, reason);
        result.state = .failed;
        return self.done(index);
    }

    fn done(self: *@This(), index: usize) !void {
        if (self.children[index]) |pid| pid.deinit();
        self.children[index] = null;
        self.remaining -= 1;
        if (self.remaining == 0) return tp.exit_normal();
    }
};

/// one connection per server, so every reply belongs to exactly one probe
const Connection = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    index: usize,
    parent: tp.pid,
    connector: ?tp.pid = null,
    connection: ?tp.pid = null,
    version: []const u8 = "",
    receiver: tp.Receiver(*@This()),

    const request_id = 1;

    const Args = struct {
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        index: usize,
        parent: tp.pid,
    };

    fn spawn(allocator: std.mem.Allocator, path: [:0]const u8, index: usize) !tp.pid {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(path_z);
        const parent = tp.self_pid().clone();
        errdefer parent.deinit();
        return tp.spawn_link(allocator, Args{ .allocator = allocator, .path = path_z, .index = index, .parent = parent }, start, module_name ++ ".connection");
    }

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const self = args.allocator.create(@This()) catch |e| {
            args.allocator.free(args.path);
            args.parent.deinit();
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .path = args.path,
            .index = args.index,
            .parent = args.parent,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);
        self.connector = try remote.endpoint.unx.connect(self.allocator, self.path, .file, tp.self_pid().clone());
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.connection) |p| {
            p.send(.{ "exit", "shutdown" }) catch {};
            p.deinit();
        }
        if (self.connector) |p| {
            p.send(.{"cancel"}) catch {};
            p.deinit();
        }
        self.allocator.free(self.version);
        self.parent.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var conn_id: tp.piid = .empty;
        var version: []const u8 = "";
        var id: u64 = 0;
        var payload: cbor.Raw = .empty;
        var reason: []const u8 = "";

        if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            const conn = tp.pid.from_id(conn_id) orelse return self.report_failed("connection_lost");
            self.connection = conn;
            try conn.link();
            const self_id: remote.protocol.lpiid = .fromInt(tp.self_pid().instance_id().toInt());
            try conn.send(.{ "send", self_id, common.service_name, .{ "hello", common.build_version } });
        } else if (try m.match(.{ "hello", tp.extract(&version) })) {
            if (self.version.len > 0) return;
            self.version = try self.allocator.dupe(u8, version);
            try from.send(.{ "request", request_id, "get_instance_info", .{} });
        } else if (try m.match(.{ "reply", tp.extract(&id), tp.extract(&payload) })) {
            if (id != request_id) return;
            return self.reply(payload);
        } else if (try m.match(.{"shutdown"})) {
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", tp.extract(&reason), tp.more })) {
            return self.handle_exit(from, reason);
        }
    }

    fn reply(self: *@This(), payload: cbor.Raw) !void {
        const empty: cbor.Raw = .{ .bytes = &.{0x80} };
        var pid: i64 = 0;
        var project: []const u8 = "";
        var background: cbor.Raw = empty;
        if (try cbor.match(payload.bytes, .{ "instance_info", cbor.extract(&pid), cbor.extract(&project), cbor.extract(&background), cbor.more }) or
            try cbor.match(payload.bytes, .{ "instance_info", cbor.extract(&pid), cbor.extract(&project) }))
            return self.report_live(pid, project, background);
        // a live server without get_instance_info (an older flow) still counts as live
        return self.report_live(0, "", empty);
    }

    fn report_live(self: *@This(), pid: i64, project: []const u8, background: cbor.Raw) error{Exit} {
        self.parent.send(.{ "probe", self.index, "live", self.version, pid, project, background }) catch {};
        return tp.exit_normal();
    }

    fn report_failed(self: *@This(), reason: []const u8) error{Exit} {
        self.parent.send(.{ "probe", self.index, "failed", reason }) catch {};
        return tp.exit_normal();
    }

    fn handle_exit(self: *@This(), from: tp.pid_ref, reason: []const u8) !void {
        const id = from.instance_id();
        if (self.connector) |connector| if (id == connector.instance_id()) {
            connector.deinit();
            self.connector = null;
            if (std.mem.eql(u8, reason, "normal")) return;
            return self.report_failed(reason);
        };
        if (self.connection) |connection| if (id == connection.instance_id()) {
            connection.deinit();
            self.connection = null;
            return self.report_failed(reason);
        };
    }
};
