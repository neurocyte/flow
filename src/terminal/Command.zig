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
        _ = std.os.linux.setsid();

        // set the controlling terminal
        var u: c_uint = std.posix.STDIN_FILENO;
        if (posix.system.ioctl(self.pty.tty, posix.T.IOCSCTTY, @intFromPtr(&u)) != 0) return error.IoctlError;

        // set up io
        try posix.dup2(self.pty.tty, std.posix.STDIN_FILENO);
        try posix.dup2(self.pty.tty, std.posix.STDOUT_FILENO);
        try posix.dup2(self.pty.tty, std.posix.STDERR_FILENO);

        posix.close(self.pty.tty);
        if (self.pty.pty > 2) posix.close(self.pty.pty);

        if (self.working_directory) |wd| {
            try std.posix.chdir(wd);
        }

        // exec
        const err = std.posix.execvpeZ(argv_buf.ptr[0].?, argv_buf.ptr, envp);
        _ = err catch {};
    }

    // we are the parent
    self.pid = @intCast(pid);

    if (!Terminal.global_sigchild_installed) {
        Terminal.global_sigchild_installed = true;
        var act = posix.Sigaction{
            .handler = .{ .handler = handleSigChild },
            .mask = switch (builtin.os.tag) {
                .macos => 0,
                .linux => posix.empty_sigset,
                else => @compileError("os not supported"),
            },
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.CHLD, &act, null);
    }

    return;
}

fn handleSigChild(_: c_int) callconv(.C) void {
    const result = std.posix.waitpid(-1, 0);

    Terminal.global_vt_mutex.lock();
    defer Terminal.global_vt_mutex.unlock();
    if (Terminal.global_vts) |vts| {
        var vt = vts.get(result.pid) orelse return;
        vt.event_queue.push(.exited);
    }
}

pub fn kill(self: *Command) void {
    if (self.pid) |pid| {
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        self.pid = null;
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
            envp_buf[i] = try std.fmt.allocPrintZ(arena, "{s}={s}", .{ pair.key_ptr.*, pair.value_ptr.* });
            i += 1;
        }
    }

    std.debug.assert(i == envp_count);
    return envp_buf;
}
