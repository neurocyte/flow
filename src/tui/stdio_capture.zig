//! Capture a process's stdout/stderr and forward each line to std.log.

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const posix = std.posix;
const system = posix.system;

pub const Stream = enum(usize) {
    stdout = 0,
    stderr = 1,

    fn target_fd(self: Stream) posix.fd_t {
        return switch (self) {
            .stdout => posix.STDOUT_FILENO,
            .stderr => posix.STDERR_FILENO,
        };
    }

    fn emit(self: Stream, line: []const u8) void {
        if (is_error(line)) switch (self) {
            .stdout => std.log.scoped(.stdout).err("{s}", .{line}),
            .stderr => std.log.scoped(.stderr).err("{s}", .{line}),
        } else switch (self) {
            .stdout => std.log.scoped(.stdout).info("{s}", .{line}),
            .stderr => std.log.scoped(.stderr).info("{s}", .{line}),
        }
    }
};

const error_markers = [_][]const u8{
    "error",    "fatal",     "panic",    "abort",  "assert",
    "critical", "exception", "segfault", "denied",
};

fn is_error(line: []const u8) bool {
    for (error_markers) |marker|
        if (std.ascii.findIgnoreCase(line, marker) != null) return true;
    return false;
}

const max_chunk = 4096;
const max_line = 8192;

const O_NONBLOCK: c_int = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

fn check(rc: anytype) error{Syscall}!@TypeOf(rc) {
    return if (posix.errno(rc) != .SUCCESS) error.Syscall else rc;
}

const Redirect = struct {
    target: posix.fd_t = -1,
    saved: posix.fd_t = -1,
};
var redirects = [_]?Redirect{ null, null };

fn redirect(stream: Stream) *?Redirect {
    return &redirects[@intFromEnum(stream)];
}

/// Restore every redirected fd to its original. Async-signal-safe.
pub fn restore_all() void {
    for (&redirects) |*r_| if (r_.*) |*r| {
        _ = system.dup2(r.saved, r.target);
    };
}

fn restore(stream: Stream) void {
    const r = if (redirect(stream).*) |*r_| r_ else return;
    _ = system.dup2(r.saved, r.target);
    _ = system.close(r.saved);
    redirect(stream).* = null;
}

fn install_redirect(stream: Stream) !posix.fd_t {
    const target = stream.target_fd();

    const saved: posix.fd_t = @intCast(try check(system.fcntl(target, posix.F.DUPFD_CLOEXEC, @as(c_int, 0))));
    errdefer _ = system.close(saved);

    // No portable atomic pipe2(CLOEXEC): macOS lacks it, so use pipe() and
    // set the flags explicitly.
    var fds: [2]posix.fd_t = undefined;
    _ = try check(system.pipe(&fds));
    errdefer {
        _ = system.close(fds[0]);
        _ = system.close(fds[1]);
    }

    // Both ends close-on-exec; read end non-blocking, write end blocking.
    _ = try check(system.fcntl(fds[0], posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)));
    _ = try check(system.fcntl(fds[1], posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)));
    const fl = try check(system.fcntl(fds[0], posix.F.GETFL, @as(c_int, 0)));
    _ = try check(system.fcntl(fds[0], posix.F.SETFL, fl | O_NONBLOCK));

    _ = try check(system.dup2(fds[1], target));
    _ = system.close(fds[1]); // `target` now owns the write end
    redirect(stream).* = .{ .target = target, .saved = saved };
    return fds[0];
}

/// Redirect `stream` to std.log via an actor. (spawns linked)
pub fn start(allocator: std.mem.Allocator, stream: Stream) !tp.pid {
    if (redirect(stream).*) |_| return error.AlreadyActive;

    const read_fd = try install_redirect(stream);
    errdefer restore(stream);
    errdefer _ = system.close(read_fd);

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
    read_fd: posix.fd_t,
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
            const n = posix.read(self.read_fd, &buf) catch |e| switch (e) {
                error.WouldBlock => return, // drained
                else => return error.Read,
            };
            if (n == 0) return error.Closed; // EOF
            try self.consume(buf[0..n]);
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
        _ = system.close(self.read_fd);
        self.line.deinit(self.allocator);
        self.allocator.free(self.tag);
        self.allocator.destroy(self);
    }
};

test "redirect roundtrip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const stream: Stream = .stdout;
    const target = stream.target_fd();
    const marker = "STDIO_CAPTURE_ROUNDTRIP_a1b2c3";
    const payload = marker ++ "\n";

    const read_fd = try install_redirect(stream);
    defer _ = system.close(read_fd);
    defer restore(stream);

    var off: usize = 0;
    while (off < payload.len) {
        const n = system.write(target, payload.ptr + off, payload.len - off);
        off += @intCast(try check(n));
    }

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(read_fd, buf[total..]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return e,
        };
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], marker) != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], marker) != null);
}
