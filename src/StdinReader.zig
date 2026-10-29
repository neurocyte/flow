const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");

const ScriptExecutor = @import("ScriptExecutor.zig");

const log = std.log.scoped(.stdin);

const module_name = @typeName(@This());
const chunk_size = 16 * 1024;

pub const Input = enum { pipe, file };

pub fn detect(io: std.Io) ?Input {
    if (builtin.os.tag == .windows) return null;
    const stat = std.Io.File.stdin().stat(io) catch return null;
    return switch (stat.kind) {
        .named_pipe => .pipe,
        .file => .file,
        else => null,
    };
}

pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, env: ?tp.env, target: tp.pid_ref, input: Input, create_args: tp.message, script: ?ScriptExecutor.Script, then: ?tp.message) !void {
    const args = try Process.Args.init(allocator, target, input, create_args, script, then);
    errdefer args.deinit();
    const pid = try ctx.spawn_link(args, Process.start, module_name, eh, env);
    pid.deinit();
}

const Process = struct {
    allocator: std.mem.Allocator,
    target: tp.pid,
    input: Input,
    script: ?ScriptExecutor.Script,
    then: ?[]const u8,
    fd_watcher: ?tp.file_descriptor = null,
    buffer_ref: ?[]const u8 = null,
    next_id: u64 = 1,
    read_buf: [chunk_size]u8 = undefined,
    args_buf: [chunk_size + 64]u8 = undefined,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        target: tp.pid,
        input: Input,
        create_args: []const u8,
        script: ?ScriptExecutor.Script,
        then: ?[]const u8,

        fn init(allocator: std.mem.Allocator, target: tp.pid_ref, input: Input, create_args: tp.message, script: ?ScriptExecutor.Script, then: ?tp.message) !Args {
            errdefer if (script) |s| s.deinit();
            const create_args_owned = try allocator.dupe(u8, create_args.buf);
            errdefer allocator.free(create_args_owned);
            const then_owned = if (then) |m| try allocator.dupe(u8, m.buf) else null;
            return .{
                .allocator = allocator,
                .target = target.clone(),
                .input = input,
                .create_args = create_args_owned,
                .script = script,
                .then = then_owned,
            };
        }

        fn deinit(self: Args) void {
            self.target.deinit();
            self.allocator.free(self.create_args);
            if (self.script) |s| s.deinit();
            if (self.then) |then| self.allocator.free(then);
        }
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| {
            log.err("start failed: {t}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn init(args: Args) !void {
        defer args.allocator.free(args.create_args);
        const self = args.allocator.create(@This()) catch |e| {
            args.target.deinit();
            if (args.script) |s| s.deinit();
            if (args.then) |then| args.allocator.free(then);
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .target = args.target,
            .input = args.input,
            .script = args.script,
            .then = args.then,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();
        _ = tp.set_trap(true);
        try self.target.link();
        try self.send_command("create_buffer", .{ .bytes = args.create_args });
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.fd_watcher) |fd_watcher| fd_watcher.deinit();
        if (self.buffer_ref) |buffer_ref| self.allocator.free(buffer_ref);
        self.target.deinit();
        if (self.script) |s| s.deinit();
        if (self.then) |then| self.allocator.free(then);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| {
            self.send_then();
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var id: u64 = 0;
        var buffer_ref: cbor.Raw = .empty;
        var exit_msg: cbor.Raw = .empty;
        var reason: []const u8 = "";
        var err_code: i64 = 0;
        var err_msg: []const u8 = "";

        if (try m.match(.{ "reply", 1, .{ "buffer", "hidden", tp.more } }) or
            try m.match(.{ "reply", 1, .{ "buffer", "deleted", tp.more } }))
        {
            self.close_stdin();
            return self.finish();
        } else if (try m.match(.{ "reply", tp.extract(&id), .{ "buffer", tp.extract(&buffer_ref) } })) {
            if (id != 1 or self.buffer_ref != null) return;
            self.buffer_ref = try self.allocator.dupe(u8, buffer_ref.bytes);
            try self.buffer_created();
            return self.read_next();
        } else if (try m.match(.{ "reply", tp.extract(&id), "ok" })) {
            // create_buffer may be acked more than once if it waits for loads, so it starts on the buffer reply
            if (id == 1 or id != self.next_id - 1) return;
            return self.read_next();
        } else if (try m.match(.{ "reply", tp.extract(&id), .{ "error", tp.extract(&exit_msg) } })) {
            if (id != 1 and id != self.next_id - 1) return;
            var buf: [256]u8 = undefined;
            if (!try cbor.match(exit_msg.bytes, .{ "exit", cbor.extract(&reason), cbor.more }))
                reason = (tp.message{ .buf = exit_msg.bytes }).to_json(&buf) catch "(unknown)";
            log.err("{s} failed: {s}", .{ if (id == 1) "create_buffer" else "append", reason });
            return self.finish();
        } else if (try m.match(.{ "fd", "stdin", "read_ready" })) {
            return self.read_chunk();
        } else if (try m.match(.{ "fd", "stdin", "read_error", tp.extract(&err_code), tp.extract(&err_msg) })) {
            log.err("read failed: {s}", .{err_msg});
            return self.finish();
        } else if (try m.match(.{ "exit", tp.more })) {
            if (from.instance_id() == self.target.instance_id()) return tp.exit_normal();
        }
    }

    fn buffer_created(self: *@This()) !void {
        const script = self.script orelse return;
        self.script = null;
        const then = self.then;
        self.then = null;
        defer if (then) |m| self.allocator.free(m);
        try ScriptExecutor.create(self.allocator, self.target.ref(), script, if (then) |m| .{ .buf = m } else null);
    }

    fn read_next(self: *@This()) !void {
        if (builtin.os.tag == .windows) return self.finish(); // TODO: read stdin with tp.file_stream
        switch (self.input) {
            .file => return self.read_chunk(),
            .pipe => {
                if (self.fd_watcher == null)
                    self.fd_watcher = try tp.file_descriptor.init("stdin", std.posix.STDIN_FILENO);
                try self.fd_watcher.?.wait_read();
            },
        }
    }

    fn read_chunk(self: *@This()) !void {
        const n = switch (builtin.os.tag) {
            .windows => return self.finish(),
            else => std.posix.read(std.posix.STDIN_FILENO, &self.read_buf) catch |e| {
                log.err("read failed: {t}", .{e});
                return self.finish();
            },
        };
        if (n == 0) return self.finish();
        try self.send_command("shell_execute_stream_output", .{ .bytes = cbor.fmt(&self.args_buf, .{ cbor.Raw{ .bytes = self.buffer_ref.? }, self.read_buf[0..n] }) });
    }

    fn send_command(self: *@This(), name: []const u8, args: cbor.Raw) !void {
        const id = self.next_id;
        self.next_id += 1;
        try self.target.send(.{ "cmd", name, args, .{ "reply", tp.self_pid().instance_id(), id } });
    }

    fn close_stdin(self: *@This()) void {
        if (self.fd_watcher) |fd_watcher| fd_watcher.deinit();
        self.fd_watcher = null;
        if (builtin.os.tag == .windows) return;
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (null_fd < 0) return;
        _ = std.c.dup2(null_fd, std.posix.STDIN_FILENO);
        _ = std.c.close(null_fd);
    }

    fn finish(self: *@This()) error{Exit} {
        self.send_then();
        return tp.exit_normal();
    }

    fn send_then(self: *@This()) void {
        const then = self.then orelse return;
        self.then = null;
        defer self.allocator.free(then);
        self.target.send_raw(.{ .buf = then }) catch {};
    }
};
