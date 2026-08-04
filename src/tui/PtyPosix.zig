const std = @import("std");
const tp = @import("thespian");
const Terminal = @import("Terminal");

pub const Parser = Terminal.Parser;

const Receiver = tp.Receiver(*@This());

allocator: std.mem.Allocator,
vt: *Terminal,
fd: tp.file_descriptor,
pty_fd: std.posix.fd_t,
parser: Parser,
receiver: Receiver,
parent: tp.pid,
err_code: i64 = 0,
sigchld: ?tp.signal = null,

pub fn spawn(allocator: std.mem.Allocator, vt: *Terminal) !tp.pid {
    const self = try allocator.create(@This());
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .vt = vt,
        .fd = undefined,
        .pty_fd = vt.ptyFd(),
        .parser = .{ .buf = try .initCapacity(allocator, 128) },
        .receiver = Receiver.init(pty_receive, dtor, self),
        .parent = tp.self_pid().clone(),
    };
    return tp.spawn_link(allocator, self, start, "pty_actor");
}

fn dtor(self: *@This()) void {
    self.fd.deinit();
    self.parser.buf.deinit();
    self.parent.deinit();
    self.allocator.destroy(self);
}

fn deinit(self: *@This()) void {
    std.log.debug("terminal: pty actor deinit (pid={?})", .{self.vt.cmd.pid});
    if (self.sigchld) |s| s.deinit();
}

fn start(self: *@This()) tp.result {
    errdefer self.deinit();
    self.fd = tp.file_descriptor.init("pty", self.pty_fd) catch |e| {
        std.log.debug("terminal: pty fd init failed: {}", .{e});
        return tp.exit_error(e, @errorReturnTrace());
    };
    self.fd.wait_read() catch |e| {
        std.log.debug("terminal: pty initial wait_read failed: {}", .{e});
        return tp.exit_error(e, @errorReturnTrace());
    };
    self.sigchld = tp.signal.init(@intFromEnum(std.posix.SIG.CHLD), tp.message.fmt(.{"sigchld"})) catch |e| {
        std.log.debug("terminal: SIGCHLD signal init failed: {}", .{e});
        return tp.exit_error(e, @errorReturnTrace());
    };
    tp.receive(&self.receiver);
}

fn pty_process_terminal_event(ctx: *Terminal.Event.HandlerContext, event: Terminal.Event) error{TerminalHandlerFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    return self.send_event(event) catch error.TerminalHandlerFailed;
}

fn send_event(self: *@This(), event: Terminal.Event) error{TerminalHandlerFailed}!void {
    self.parent.send(.{ "VT", event }) catch return error.TerminalHandlerFailed;
}

fn send_event_result(self: *@This(), event: Terminal.Event) tp.result {
    self.parent.send(.{ "VT", event }) catch return tp.exit_error(error.TerminalHandlerFailed, @errorReturnTrace());
}

fn pty_receive(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
    errdefer self.deinit();

    if (try m.match(.{ "fd", "pty", "read_ready" })) {
        self.read_and_process() catch |e| return switch (e) {
            error.Terminated => {
                std.log.debug("terminal: pty exiting: read loop terminated (process exited)", .{});
                return tp.exit_normal();
            },
            error.InputOutput => {
                std.log.debug("terminal: pty exiting: EIO on read (process exited)", .{});
                return tp.exit_normal();
            },
            error.TerminalHandlerFailed => {
                std.log.debug("terminal: pty exiting: send to parent failed", .{});
                return tp.exit_normal();
            },
            error.Unexpected => {
                std.log.debug("terminal: pty exiting: unexpected error (see preceding log)", .{});
                return tp.exit_normal();
            },
        };
    } else if (try m.match(.{ "fd", "pty", "read_error", tp.extract(&self.err_code), tp.more })) {
        // thespian fires read_error when the pty fd signals an error condition
        // Treat it the same as EIO: reap the child and signal exit.
        const code = self.vt.cmd.wait();
        std.log.debug("terminal: read_error from fd (err={d}), process exited with code={d}", .{ self.err_code, code });
        try self.send_event_result(.{ .exited = code });
        return tp.exit_normal();
    } else if (try m.match(.{"sigchld"})) {
        // SIGCHLD fires when any child exits. Check if it's our child.
        if (self.vt.cmd.try_wait()) |code| {
            std.log.debug("terminal: child exited (SIGCHLD) with code={d}", .{code});
            try self.send_event_result(.{ .exited = code });
            return tp.exit_normal();
        }
        // Not our child (or already reaped) - re-arm the signal and continue.
        if (self.sigchld) |s| s.deinit();
        self.sigchld = tp.signal.init(@intFromEnum(std.posix.SIG.CHLD), tp.message.fmt(.{"sigchld"})) catch null;
    } else if (try m.match(.{"quit"})) {
        std.log.debug("terminal: pty exiting: received quit", .{});
        return tp.exit_normal();
    } else {
        std.log.debug("terminal: pty exiting: unexpected message", .{});
        return tp.unexpected(m);
    }
}

fn read_and_process(self: *@This()) error{ Terminated, InputOutput, TerminalHandlerFailed, Unexpected }!void {
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = std.posix.read(self.vt.ptyFd(), &buf) catch |e| switch (e) {
            error.WouldBlock => {
                // No more data right now. On Linux, a clean child exit may not
                // generate a readable event on the pty master - it just starts
                // returning EIO. Poll for exit here before sleeping in wait_read.
                // On macOS/FreeBSD the pty master raises EIO directly, so the
                // try_wait check here is just an extra safety net.
                if (self.vt.cmd.try_wait()) |code| {
                    std.log.debug("terminal: child exited (detected via try_wait) with code={d}", .{code});
                    try self.send_event(.{ .exited = code });
                    return error.InputOutput;
                }
                break;
            },
            error.InputOutput => {
                const code = self.vt.cmd.wait();
                std.log.debug("terminal: read EIO, process exited with code={d}", .{code});
                try self.send_event(.{ .exited = code });
                return error.InputOutput;
            },
            error.SystemResources,
            error.IsDir,
            error.ConnectionResetByPeer,
            error.NotOpenForReading,
            error.SocketUnconnected,
            error.Canceled,
            error.AccessDenied,
            error.LockViolation,
            error.Unexpected,
            => {
                std.log.debug("terminal: read unexpected error: {} (pid={?})", .{ e, self.vt.cmd.pid });
                return error.Unexpected;
            },
        };
        if (n == 0) {
            const code = self.vt.cmd.wait();
            std.log.debug("terminal: read returned 0 bytes (EOF), process exited with code={d}", .{code});
            try self.send_event(.{ .exited = code });
            return error.Terminated;
        }

        switch (self.vt.processOutput(&self.parser, buf[0..n], self, pty_process_terminal_event) catch |e| switch (e) {
            error.WriteFailed,
            error.ReadFailed,
            error.OutOfMemory,
            error.Canceled,
            error.TerminalHandlerFailed,
            => {
                std.log.debug("terminal: processOutput error: {} (pid={?})", .{ e, self.vt.cmd.pid });
                return error.Unexpected;
            },
        }) {
            .exited => {
                std.log.debug("terminal: processOutput returned .exited (process EOF)", .{});
                return error.Terminated;
            },
            .running => {},
        }
    }

    // Check for child exit once more before sleeping in wait_read.
    // A clean exit with no final output will never make the pty fd readable,
    // so we must detect it here rather than waiting forever.
    if (self.vt.cmd.try_wait()) |code| {
        std.log.debug("terminal: child exited (pre-wait_read check) with code={d}", .{code});
        try self.send_event(.{ .exited = code });
        return error.InputOutput;
    }

    self.fd.wait_read() catch |e| switch (e) {
        error.ThespianFileDescriptorWaitReadFailed => {
            std.log.debug("terminal: wait_read failed: {} (pid={?})", .{ e, self.vt.cmd.pid });
            return error.Unexpected;
        },
    };
}
