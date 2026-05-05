const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("Pty.zig");
const Terminal = @import("Terminal.zig");

const posix = std.posix;

argv: []const []const u8,

working_directory: ?[]const u8,

// Set after spawn()
pid: ?std.posix.pid_t = null,

env_map: *const std.process.Environ.Map,

pty: Pty,

pub fn spawn(self: *Command, allocator: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const envp = try createEnvironFromMap(arena, self.env_map);

    const fork_ret = std.c.fork();
    if (fork_ret < 0) return error.ForkFailed;
    const pid: posix.pid_t = @intCast(fork_ret);
    if (pid == 0) {
        // we are the child
        _ = std.c.setsid();

        // set the controlling terminal
        // Linux takes a pointer-sized arg (non-zero = steal); macOS/FreeBSD take a plain int 0.
        // TIOCSCTTY: make the tty the controlling terminal for this process.
        // Linux exposes it via posix.T.IOCSCTTY; on macOS/FreeBSD it's a raw constant.
        const TIOCSCTTY: c_int = switch (builtin.os.tag) {
            .linux => @bitCast(@as(u32, posix.T.IOCSCTTY)),
            else => @bitCast(@as(u32, 0x20007461)), // from <sys/ttycom.h>: _IOW('t', 97, int)
        };
        // Linux takes a pointer argument (non-zero = steal); macOS/FreeBSD ignore it.
        const tiocsctty_arg: usize = switch (builtin.os.tag) {
            .linux => blk: {
                var u: c_uint = 0;
                break :blk @intFromPtr(&u);
            },
            else => 0,
        };
        if (posix.system.ioctl(self.pty.tty.handle, TIOCSCTTY, tiocsctty_arg) != 0) std.c.exit(1);

        // set up io
        _ = std.c.dup2(self.pty.tty.handle, posix.STDIN_FILENO);
        _ = std.c.dup2(self.pty.tty.handle, posix.STDOUT_FILENO);
        _ = std.c.dup2(self.pty.tty.handle, posix.STDERR_FILENO);

        _ = std.c.close(self.pty.tty.handle);
        if (self.pty.pty.handle > 2) _ = std.c.close(self.pty.pty.handle);

        // Close all fds > 2 so the child cannot access the parent's
        // terminal or other inherited file descriptors.
        const rlim = posix.getrlimit(.NOFILE) catch posix.rlimit{ .cur = 1024, .max = 1024 };
        var fd: posix.fd_t = 3;
        while (fd < @as(posix.fd_t, @intCast(rlim.cur))) : (fd += 1) {
            safe_close(fd);
        }

        if (self.working_directory) |wd| {
            const wd_z = arena.dupeZ(u8, wd) catch std.c.exit(1);
            _ = std.c.chdir(wd_z.ptr);
        }

        // exec
        _ = posix.system.execve(argv_buf.ptr[0].?, argv_buf.ptr, @ptrCast(envp.ptr));

        std.c.exit(127);
    }

    // we are the parent
    self.pid = @intCast(pid);
}

fn safe_close(fd: posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        return std.os.windows.CloseHandle(fd);
    }
    if (builtin.os.tag == .wasi and !builtin.link_libc) {
        _ = std.os.wasi.fd_close(fd);
        return;
    }
    _ = std.c.close(fd);
}

pub fn kill(self: *Command) void {
    if (self.pid) |pid|
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
}

/// Non-blocking check: if the child has already exited, reap it and return the
/// exit code. Returns null if the child is still running. Safe to call repeatedly.
pub fn try_wait(self: *Command) ?u8 {
    const pid = self.pid orelse return null;
    var status: c_int = 0;
    const wpid = std.c.waitpid(pid, &status, @intCast(posix.W.NOHANG));
    if (wpid == 0) return null; // still running
    self.pid = null;
    const us: u32 = @bitCast(status);
    if (posix.W.IFEXITED(us))
        return posix.W.EXITSTATUS(us);
    if (posix.W.IFSIGNALED(us))
        return @truncate(@intFromEnum(posix.W.TERMSIG(us)));
    return 0;
}

/// Reap the child process. Must be called after the pty EOF has been seen,
/// so the child is guaranteed to have already exited. Uses WNOHANG in a loop
/// to handle any remaining state. Returns the exit code (0-255).
pub fn wait(self: *Command) u8 {
    const pid = self.pid orelse return 0;
    self.pid = null;
    while (true) {
        var status: c_int = 0;
        const wpid = std.c.waitpid(pid, &status, @intCast(posix.W.NOHANG));
        if (wpid != 0) {
            const us: u32 = @bitCast(status);
            if (posix.W.IFEXITED(us))
                return posix.W.EXITSTATUS(us);
            return 0;
        }
        // pid == 0 means not yet exited — yield and retry
        std.Thread.yield() catch {};
    }
}

/// Creates a null-deliminated environment variable block in the format expected by POSIX, from a
/// hash map plus options.
fn createEnvironFromMap(
    arena: std.mem.Allocator,
    map: *const std.process.Environ.Map,
) ![:null]?[*:0]u8 {
    const envp_count: usize = map.count();

    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);
    var i: usize = 0;

    {
        var it = map.iterator();
        while (it.next()) |pair| {
            envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ pair.key_ptr.*, pair.value_ptr.* }, 0);
            i += 1;
        }
    }

    std.debug.assert(i == envp_count);
    return envp_buf;
}
