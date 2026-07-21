//! Capture a process's stdout/stderr and forward each line to std.log.

const std = @import("std");
const tp = @import("thespian");
const linux = std.os.linux;

pub const Stream = enum(usize) {
    stdout = 0,
    stderr = 1,

    fn target_fd(self: Stream) i32 {
        return switch (self) {
            .stdout => linux.STDOUT_FILENO,
            .stderr => linux.STDERR_FILENO,
        };
    }

    fn emit(self: Stream, line: []const u8) void {
        switch (self) {
            .stdout => std.log.scoped(.stdout).info("{s}", .{line}),
            .stderr => std.log.scoped(.stderr).err("{s}", .{line}),
        }
    }
};

const max_chunk = 4096;
const max_line = 8192;

fn errno(rc: usize) linux.E {
    const signed: isize = @bitCast(rc);
    return if (signed < 0) @enumFromInt(@as(u16, @intCast(-signed))) else .SUCCESS;
}

fn sys(rc: usize) error{Syscall}!usize {
    return switch (errno(rc)) {
        .SUCCESS => rc,
        else => error.Syscall,
    };
}

const Redirect = struct {
    target: i32 = -1,
    saved: i32 = -1,
};
var redirects = [_]?Redirect{ null, null };

fn redirect(stream: Stream) *?Redirect {
    return &redirects[@intFromEnum(stream)];
}

/// Restore every redirected fd to its original. Async-signal-safe.
pub fn restore_all() void {
    for (&redirects) |*r_| if (r_.*) |*r| {
        _ = linux.dup2(r.saved, r.target);
    };
}

fn restore(stream: Stream) void {
    const r = if (redirect(stream).*) |*r_| r_ else return;
    _ = linux.dup2(r.saved, r.target);
    _ = linux.close(r.saved);
    redirect(stream).* = null;
}

fn install_redirect(stream: Stream) !i32 {
    const target = stream.target_fd();

    const saved: i32 = @intCast(try sys(linux.fcntl(target, linux.F.DUPFD_CLOEXEC, 0)));
    errdefer _ = linux.close(saved);

    var fds: [2]i32 = undefined;
    _ = try sys(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    errdefer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }

    // Read end non-blocking. Write end blocking.
    const fl = try sys(linux.fcntl(fds[0], linux.F.GETFL, 0));
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = try sys(linux.fcntl(fds[0], linux.F.SETFL, fl | @as(usize, nonblock)));

    _ = try sys(linux.dup2(fds[1], target));
    _ = linux.close(fds[1]); // `target` now owns the write end
    redirect(stream).* = .{ .target = target, .saved = saved };
    return fds[0];
}

/// Redirect `stream` to std.log via an actor. (spawns linked)
pub fn start(allocator: std.mem.Allocator, stream: Stream) !tp.pid {
    if (redirect(stream).*) |_| return error.AlreadyActive;

    const read_fd = try install_redirect(stream);
    errdefer restore(stream);
    errdefer _ = linux.close(read_fd);

    const self = try allocator.create(Reader);
    errdefer allocator.destroy(self);
    const tag = try allocator.dupeZ(u8, @tagName(stream));
    errdefer allocator.free(tag);
    self.* = .{
        .allocator = allocator,
        .stream = stream,
        .read_fd = read_fd,
        .tag = tag,
        .receiver = Reader.Receiver.init(Reader.receive, Reader.deinit, self),
    };
    return tp.spawn_link(allocator, self, Reader.start, tag);
}

const Reader = struct {
    allocator: std.mem.Allocator,
    stream: Stream,
    read_fd: i32,
    tag: [:0]const u8,
    fd: ?tp.file_descriptor = null,
    line: std.ArrayList(u8) = .empty,
    receiver: Receiver,

    const Receiver = tp.Receiver(*Reader);

    fn start(self: *Reader) tp.result {
        errdefer self.deinit();
        self.fd = tp.file_descriptor.init(self.tag, self.read_fd) catch |e|
            return tp.exit_error(e, @errorReturnTrace());
        if (self.fd) |fd| fd.wait_read() catch |e|
            return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn receive(self: *Reader, _: tp.pid_ref, m: tp.message) tp.result {
        var err: i64 = 0;
        var err_msg: []const u8 = "";
        if (try m.match(.{ "fd", tp.any, "read_ready" })) {
            self.dispatch() catch |e| switch (e) {
                error.Closed => return tp.exit_normal(),
                else => return tp.exit_error(e, @errorReturnTrace()),
            };
            if (self.fd) |fd| fd.wait_read() catch |e|
                return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "fd", tp.any, "read_error", tp.extract(&err), tp.extract(&err_msg) })) {
            return tp.exit_normal();
        } else if (try m.match(.{"term"})) {
            return tp.exit_normal();
        }
    }

    fn dispatch(self: *Reader) !void {
        var buf: [max_chunk]u8 = undefined;
        while (true) {
            const rc = linux.read(self.read_fd, &buf, buf.len);
            switch (errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.Closed; // EOF
                    try self.consume(buf[0..rc]);
                },
                .AGAIN => return,
                .INTR => {},
                else => return error.Read,
            }
        }
    }

    fn consume(self: *Reader, bytes: []const u8) !void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try self.push(rest[0..nl], true);
            rest = rest[nl + 1 ..];
        }
        if (rest.len > 0) try self.push(rest, false);
    }

    fn push(self: *Reader, seg: []const u8, complete: bool) !void {
        if (self.line.items.len == 0 and complete) {
            self.stream.emit(trim(seg));
            return;
        }
        if (self.line.items.len + seg.len > max_line) {
            // pathological line: flush what we have rather than grow unbounded
            if (self.line.items.len > 0) {
                self.stream.emit(trim(self.line.items));
                self.line.clearRetainingCapacity();
            }
            if (seg.len > max_line) {
                self.stream.emit(trim(seg[0..max_line]));
                return;
            }
        }
        try self.line.appendSlice(self.allocator, seg);
        if (complete) {
            self.stream.emit(trim(self.line.items));
            self.line.clearRetainingCapacity();
        }
    }

    fn trim(line: []const u8) []const u8 {
        return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    }

    fn deinit(self: *Reader) void {
        if (self.fd) |fd| fd.deinit();
        restore(self.stream);
        _ = linux.close(self.read_fd);
        self.line.deinit(self.allocator);
        self.allocator.free(self.tag);
        self.allocator.destroy(self);
    }
};
