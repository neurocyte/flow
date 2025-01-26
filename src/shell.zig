const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");

pid: ?tp.pid,
stdin_behavior: std.process.Child.StdIo,

const Self = @This();
const module_name = @typeName(Self);
pub const max_chunk_size = tp.subprocess.max_chunk_size;
pub const Writer = std.io.Writer(*Self, Error, write);
pub const BufferedWriter = std.io.BufferedWriter(max_chunk_size, Writer);
pub const Error = error{ InvalidShellArg0, OutOfMemory, Exit, ThespianSpawnFailed, Closed };

pub const OutputHandler = fn (context: usize, parent: tp.pid_ref, arg0: []const u8, output: []const u8) void;
pub const ExitHandler = fn (context: usize, parent: tp.pid_ref, arg0: []const u8, err_msg: []const u8, exit_code: i64) void;

pub const Handlers = struct {
    context: usize = 0,
    out: *const OutputHandler,
    err: ?*const OutputHandler = null,
    exit: *const ExitHandler = log_exit_handler,
};

pub fn execute(allocator: std.mem.Allocator, argv: tp.message, handlers: Handlers) Error!void {
    const stdin_behavior = .Close;
    var pid = try Process.create(allocator, argv, stdin_behavior, handlers);
    pid.deinit();
}

pub fn execute_pipe(allocator: std.mem.Allocator, argv: tp.message, output_handler: ?OutputHandler, exit_handler: ?ExitHandler) Error!Self {
    const stdin_behavior = .Pipe;
    return .{ .pid = try Process.create(allocator, argv, stdin_behavior, output_handler, exit_handler), .stdin_behavior = stdin_behavior };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        if (self.stdin_behavior == .Pipe)
            pid.send(.{"close"}) catch {};
        self.pid = null;
        pid.deinit();
    }
}

pub fn write(self: *Self, bytes: []const u8) !usize {
    try self.input(bytes);
    return bytes.len;
}

pub fn input(self: *const Self, bytes: []const u8) !void {
    const pid = self.pid orelse return error.Closed;
    var remaining = bytes;
    while (remaining.len > 0)
        remaining = loop: {
            if (remaining.len > max_chunk_size) {
                try pid.send(.{ "input", remaining[0..max_chunk_size] });
                break :loop remaining[max_chunk_size..];
            } else {
                try pid.send(.{ "input", remaining });
                break :loop &[_]u8{};
            }
        };
}

pub fn close(self: *Self) void {
    self.deinit();
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}

pub fn bufferedWriter(self: *Self) BufferedWriter {
    return .{ .unbuffered_writer = self.writer() };
}

pub fn log_handler(context: usize, parent: tp.pid_ref, arg0: []const u8, output: []const u8) void {
    _ = context;
    _ = parent;
    _ = arg0;
    const logger = log.logger(@typeName(Self));
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| if (line.len > 0) logger.print("{s}", .{line});
}

pub fn log_err_handler(context: usize, parent: tp.pid_ref, arg0: []const u8, output: []const u8) void {
    _ = context;
    _ = parent;
    const logger = log.logger(@typeName(Self));
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| logger.print_err(arg0, "{s}", .{line});
}

pub fn log_exit_handler(context: usize, parent: tp.pid_ref, arg0: []const u8, err_msg: []const u8, exit_code: i64) void {
    _ = context;
    _ = parent;
    const logger = log.logger(@typeName(Self));
    if (exit_code > 0) {
        logger.print_err(arg0, "'{s}' terminated {s} exitcode: {d}", .{ arg0, err_msg, exit_code });
    } else {
        logger.print("'{s}' exited", .{arg0});
    }
}

pub fn log_exit_err_handler(context: usize, parent: tp.pid_ref, arg0: []const u8, err_msg: []const u8, exit_code: i64) void {
    _ = context;
    _ = parent;
    const logger = log.logger(@typeName(Self));
    if (exit_code > 0) {
        logger.print_err(arg0, "'{s}' terminated {s} exitcode: {d}", .{ arg0, err_msg, exit_code });
    }
}

const Process = struct {
    allocator: std.mem.Allocator,
    arg0: [:0]const u8,
    argv: tp.message,
    receiver: Receiver,
    sp: ?tp.subprocess = null,
    parent: tp.pid,
    logger: log.Logger,
    stdin_behavior: std.process.Child.StdIo,
    handlers: Handlers,

    const Receiver = tp.Receiver(*Process);

    pub fn create(allocator: std.mem.Allocator, argv_: tp.message, stdin_behavior: std.process.Child.StdIo, handlers: Handlers) Error!tp.pid {
        const argv = try argv_.clone(allocator);
        var arg0_: []const u8 = "";
        if (!try argv.match(.{ tp.extract(&arg0_), tp.more })) {
            allocator.free(argv.buf);
            return error.InvalidShellArg0;
        }
        const self = try allocator.create(Process);
        self.* = .{
            .allocator = allocator,
            .argv = argv,
            .arg0 = try allocator.dupeZ(u8, arg0_),
            .receiver = Receiver.init(receive, self),
            .parent = tp.self_pid().clone(),
            .logger = log.logger(@typeName(Self)),
            .stdin_behavior = stdin_behavior,
            .handlers = handlers,
        };
        return tp.spawn_link(self.allocator, self, Process.start, self.arg0);
    }

    fn deinit(self: *Process) void {
        if (self.sp) |*sp| sp.deinit();
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.free(self.arg0);
        self.allocator.free(self.argv.buf);
        self.close() catch {};
        self.allocator.destroy(self);
    }

    fn close(self: *Process) tp.result {
        if (self.sp) |*sp| {
            defer self.sp = null;
            try sp.close();
        }
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        _ = tp.set_trap(true);
        var buf: [1024]u8 = undefined;
        const json = self.argv.to_json(&buf) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.logger.print("shell: execute {s}", .{json});
        self.sp = tp.subprocess.init(self.allocator, self.argv, module_name, self.stdin_behavior) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var bytes: []u8 = "";

        if (try m.match(.{ "input", tp.extract(&bytes) })) {
            const sp = self.sp orelse return tp.exit_error(error.Closed, null);
            try sp.send(bytes);
        } else if (try m.match(.{"close"})) {
            try self.close();
        } else if (try m.match(.{ module_name, "stdout", tp.extract(&bytes) })) {
            self.handlers.out(self.handlers.context, self.parent.ref(), self.arg0, bytes);
        } else if (try m.match(.{ module_name, "stderr", tp.extract(&bytes) })) {
            (self.handlers.err orelse self.handlers.out)(self.handlers.context, self.parent.ref(), self.arg0, bytes);
        } else if (try m.match(.{ module_name, "term", tp.more })) {
            self.handle_terminated(m) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "exit", "normal" })) {
            return tp.exit_normal();
        } else {
            self.logger.err("receive", tp.unexpected(m));
            return tp.unexpected(m);
        }
    }

    fn handle_terminated(self: *Process, m: tp.message) !void {
        var err_msg: []const u8 = undefined;
        var exit_code: i64 = undefined;
        if (try m.match(.{ tp.any, tp.any, "exited", 0 })) {
            self.handlers.exit(self.handlers.context, self.parent.ref(), self.arg0, "exited", 0);
        } else if (try m.match(.{ tp.any, tp.any, "error.FileNotFound", 1 })) {
            self.logger.print_err(self.arg0, "'{s}' executable not found", .{self.arg0});
        } else if (try m.match(.{ tp.any, tp.any, tp.extract(&err_msg), tp.extract(&exit_code) })) {
            self.handlers.exit(self.handlers.context, self.parent.ref(), self.arg0, err_msg, exit_code);
        }
    }
};
