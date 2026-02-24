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
pub const Error = error{
    InvalidShellArg0,
    OutOfMemory,
    Exit,
    ThespianSpawnFailed,
    Closed,
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    InvalidFloatType,
    InvalidArrayType,
    InvalidPIntType,
    JsonIncompatibleType,
    NotAnObject,
    BadArrayAllocExtract,
    InvalidMapType,
    InvalidUnion,
    WriteFailed,
};

pub const OutputHandler = fn (context: usize, parent: tp.pid_ref, arg0: []const u8, output: []const u8) void;
pub const ExitHandler = fn (context: usize, parent: tp.pid_ref, arg0: []const u8, err_msg: []const u8, exit_code: i64) void;

pub const Handlers = struct {
    context: usize = 0,
    out: *const OutputHandler,
    err: ?*const OutputHandler = null,
    exit: *const ExitHandler = log_exit_handler,
    log_execute: bool = true,
    line_buffered: bool = true,
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
    defer logger.deinit();
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line_| if (line_.len > 0) {
        const line = if (line_[line_.len - 1] == '\r') line_[0 .. line_.len - 1] else line_;
        logger.print("{s}", .{line});
    };
}

pub fn log_err_handler(context: usize, parent: tp.pid_ref, arg0: []const u8, output: []const u8) void {
    _ = context;
    _ = parent;
    const logger = log.logger(@typeName(Self));
    defer logger.deinit();
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line_| if (line_.len > 0) {
        const line = if (line_[line_.len - 1] == '\r') line_[0 .. line_.len - 1] else line_;
        logger.print_err(arg0, "{s}", .{line});
    };
}

pub fn log_exit_handler(context: usize, parent: tp.pid_ref, arg0: []const u8, err_msg: []const u8, exit_code: i64) void {
    _ = context;
    _ = parent;
    const logger = log.logger(@typeName(Self));
    defer logger.deinit();
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
    defer logger.deinit();
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
    stdout_line_buffer: std.ArrayListUnmanaged(u8) = .empty,
    stderr_line_buffer: std.ArrayListUnmanaged(u8) = .empty,

    const Receiver = tp.Receiver(*Process);

    pub fn create(allocator: std.mem.Allocator, argv_: tp.message, stdin_behavior: std.process.Child.StdIo, handlers: Handlers) Error!tp.pid {
        var arg0: []const u8 = "";
        const argv = if (try argv_.match(.{tp.extract(&arg0)}))
            try parse_arg0_to_argv(allocator, &arg0)
        else if (try argv_.match(.{ tp.extract(&arg0), tp.more }))
            try argv_.clone(allocator)
        else
            return error.InvalidShellArg0;

        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .argv = argv,
            .arg0 = try allocator.dupeZ(u8, arg0),
            .receiver = Receiver.init(receive, self),
            .parent = tp.self_pid().clone(),
            .logger = log.logger(@typeName(Self)),
            .stdin_behavior = stdin_behavior,
            .handlers = handlers,
        };
        return tp.spawn_link(self.allocator, self, Process.start, self.arg0);
    }

    fn deinit(self: *Process) void {
        if (self.sp) |*sp| {
            defer self.sp = null;
            sp.deinit();
        }
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.free(self.arg0);
        self.allocator.free(self.argv.buf);
        self.stdout_line_buffer.deinit(self.allocator);
        self.stderr_line_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn close(self: *Process) void {
        defer self.sp = null;
        if (self.sp) |*sp| sp.close() catch {};
    }

    fn term(self: *Process) void {
        defer self.sp = null;
        if (self.sp) |*sp| sp.term() catch {};
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        _ = tp.set_trap(true);
        var buf: [1024]u8 = undefined;
        const json = self.argv.to_json(&buf) catch |e| return tp.exit_error(e, @errorReturnTrace());
        if (self.handlers.log_execute)
            self.logger.print("execute {s}", .{json});
        self.sp = tp.subprocess.init(self.allocator, self.argv, module_name, self.stdin_behavior) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var bytes: []const u8 = "";

        if (try m.match(.{ "input", tp.extract(&bytes) })) {
            const sp = self.sp orelse return tp.exit_error(error.Closed, null);
            try sp.send(bytes);
        } else if (try m.match(.{"close"})) {
            self.close();
        } else if (try m.match(.{ module_name, "stdout", tp.extract(&bytes) })) {
            self.handle_stdout(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ module_name, "stderr", tp.extract(&bytes) })) {
            self.handle_stderr(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ module_name, "term", tp.more })) {
            defer self.sp = null;
            self.handle_terminated(m) catch |e| return tp.exit_error(e, @errorReturnTrace());
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", "normal" })) {
            self.term();
            return tp.exit_normal();
        } else {
            self.logger.err("receive", tp.unexpected(m));
            return tp.unexpected(m);
        }
    }

    fn handle_stdout(self: *Process, bytes: []const u8) error{OutOfMemory}!void {
        return if (!self.handlers.line_buffered)
            self.handlers.out(self.handlers.context, self.parent.ref(), self.arg0, bytes)
        else
            self.handle_buffered_output(self.handlers.out, &self.stdout_line_buffer, bytes);
    }

    fn handle_stderr(self: *Process, bytes: []const u8) error{OutOfMemory}!void {
        const handler = self.handlers.err orelse self.handlers.out;
        return if (!self.handlers.line_buffered)
            handler(self.handlers.context, self.parent.ref(), self.arg0, bytes)
        else
            self.handle_buffered_output(handler, &self.stderr_line_buffer, bytes);
    }

    fn handle_buffered_output(self: *Process, handler: *const OutputHandler, buffer: *std.ArrayListUnmanaged(u8), bytes: []const u8) error{OutOfMemory}!void {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        var have_nl = false;
        var prev = it.first();
        while (it.next()) |next| {
            have_nl = true;
            try buffer.appendSlice(self.allocator, prev);
            try buffer.append(self.allocator, '\n');
            prev = next;
        }
        if (have_nl) {
            handler(self.handlers.context, self.parent.ref(), self.arg0, buffer.items);
            buffer.clearRetainingCapacity();
        }
        try buffer.appendSlice(self.allocator, prev);
    }

    fn flush_stdout(self: *Process) void {
        self.flush_buffer(self.handlers.out, &self.stdout_line_buffer);
    }

    fn flush_stderr(self: *Process) void {
        self.flush_buffer(self.handlers.err orelse self.handlers.out, &self.stderr_line_buffer);
    }

    fn flush_buffer(self: *Process, handler: *const OutputHandler, buffer: *std.ArrayListUnmanaged(u8)) void {
        if (!self.handlers.line_buffered) return;
        if (buffer.items.len > 0) handler(self.handlers.context, self.parent.ref(), self.arg0, buffer.items);
        buffer.clearRetainingCapacity();
    }

    fn handle_terminated(self: *Process, m: tp.message) !void {
        var err_msg: []const u8 = undefined;
        var exit_code: i64 = undefined;
        self.flush_stdout();
        self.flush_stderr();
        if (try m.match(.{ tp.any, tp.any, "exited", 0 })) {
            self.handlers.exit(self.handlers.context, self.parent.ref(), self.arg0, "exited", 0);
        } else if (try m.match(.{ tp.any, tp.any, "error.FileNotFound", 1 })) {
            self.logger.print_err(self.arg0, "'{s}' executable not found", .{self.arg0});
        } else if (try m.match(.{ tp.any, tp.any, tp.extract(&err_msg), tp.extract(&exit_code) })) {
            self.handlers.exit(self.handlers.context, self.parent.ref(), self.arg0, err_msg, exit_code);
        }
    }
};

pub fn parse_arg0_to_argv(allocator: std.mem.Allocator, arg0: *[]const u8) !tp.message {
    // this is horribly simplistic
    // TODO: add quotes parsing and workspace variables, etc.
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var it = std.mem.splitScalar(u8, arg0.*, ' ');
    while (it.next()) |arg|
        try args.append(allocator, arg);

    var msg_cb: std.Io.Writer.Allocating = .init(allocator);
    defer msg_cb.deinit();

    try cbor.writeArrayHeader(&msg_cb.writer, args.items.len);
    for (args.items) |arg|
        try cbor.writeValue(&msg_cb.writer, arg);

    _ = try cbor.match(msg_cb.written(), .{ tp.extract(arg0), tp.more });
    return .{ .buf = try msg_cb.toOwnedSlice() };
}
