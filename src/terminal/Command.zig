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

env_map: *const std.process.EnvMap,

pty: Pty,

pub fn spawn(self: *Command, allocator: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const envp = try createEnvironFromMap(arena, self.env_map);

    const pid = try std.posix.fork();
    if (pid == 0) {
        // we are the child
        _ = std.posix.setsid() catch {};

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
        if (posix.system.ioctl(self.pty.tty.handle, TIOCSCTTY, tiocsctty_arg) != 0) return error.IoctlError;

        // set up io
        try posix.dup2(self.pty.tty.handle, std.posix.STDIN_FILENO);
        try posix.dup2(self.pty.tty.handle, std.posix.STDOUT_FILENO);
        try posix.dup2(self.pty.tty.handle, std.posix.STDERR_FILENO);

        self.pty.tty.close();
        if (self.pty.pty.handle > 2) self.pty.pty.close();

        if (self.working_directory) |wd| {
            try std.posix.chdir(wd);
        }

        // exec
        const err = std.posix.execvpeZ(argv_buf.ptr[0].?, argv_buf.ptr, envp);
        _ = err catch {};
    }

    // we are the parent
    self.pid = @intCast(pid);
}

pub fn kill(self: *Command) void {
    if (self.pid) |pid|
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
}

/// Non-blocking check: if the child has already exited, reap it and return the
/// exit code. Returns null if the child is still running. Safe to call repeatedly.
pub fn try_wait(self: *Command) ?u8 {
    const pid = self.pid orelse return null;
    const result = std.posix.waitpid(pid, std.posix.W.NOHANG);
    if (result.pid == 0) return null; // still running
    self.pid = null;
    if (std.posix.W.IFEXITED(result.status))
        return std.posix.W.EXITSTATUS(result.status);
    if (std.posix.W.IFSIGNALED(result.status))
        return @truncate(std.posix.W.TERMSIG(result.status));
    return 0;
}

/// Reap the child process. Must be called after the pty EOF has been seen,
/// so the child is guaranteed to have already exited. Uses WNOHANG in a loop
/// to handle any remaining state. Returns the exit code (0-255).
pub fn wait(self: *Command) u8 {
    const pid = self.pid orelse return 0;
    self.pid = null;
    while (true) {
        const result = std.posix.waitpid(pid, std.posix.W.NOHANG);
        if (result.pid != 0) {
            if (std.posix.W.IFEXITED(result.status))
                return std.posix.W.EXITSTATUS(result.status);
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
    map: *const std.process.EnvMap,
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
