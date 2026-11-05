const std = @import("std");
const bin_path = @import("bin_path");
const posix = std.posix;

const timeout_ms = 2000;
const begin_marker = "__FLOW_LOGIN_ENVIRONMENT__";
const command = "/usr/bin/printf " ++ begin_marker ++ "; exec /usr/bin/env -0";
const done_marker = "FLOW_LOGIN_ENVIRONMENT";
const skip = [_][]const u8{ "_", "PWD", "OLDPWD", "SHLVL", "TERM", done_marker };

/// re-exec with the login shell environment
pub fn exec(init: std.process.Init) void {
    const env = init.environ_map;
    if (env.get(done_marker)) |_| {
        _ = env.swapRemove(done_marker);
        return;
    }
    const arena = init.arena.allocator();
    const shell = arena.dupeSentinel(u8, env.get("SHELL") orelse blk: {
        const pw = std.c.getpwuid(std.c.geteuid()) orelse return;
        break :blk std.mem.span(pw.shell orelse return);
    }, 0) catch return;
    var login_env = (read(init.io, arena, env, shell) catch return) orelse return;
    login_env.put(done_marker, "1") catch return;
    const envp = login_env.createPosixBlock(arena, .{}) catch return;
    const executable = bin_path.resolve_executable(init.gpa, std.mem.span(init.minimal.args.vector[0]));
    _ = std.c.execve(executable, @ptrCast(init.minimal.args.vector), envp.slice.ptr);
}

fn read(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, shell: [:0]const u8) !?std.process.Environ.Map {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const output = try run_shell(io, arena, env, shell) orelse return null;
    const start = std.mem.lastIndexOf(u8, output, begin_marker) orelse return null;

    var result = try env.clone(allocator);
    errdefer result.deinit();
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, output[start + begin_marker.len ..], 0);
    while (it.next()) |entry| {
        const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..sep];
        if (key.len == 0 or is_skipped(key)) continue;
        try result.put(key, entry[sep + 1 ..]);
        count += 1;
    }
    if (count == 0) {
        result.deinit();
        return null;
    }
    return result;
}

fn is_skipped(key: []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, key, s)) return true;
    return false;
}

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const anyopaque) c_int;

/// run in a pty to get the interactive shell startup env
fn run_shell(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, shell: [:0]const u8) !?[]const u8 {
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-l", "-i", "-c", command };
    const envp = try env.createPosixBlock(arena, .{});

    var master: c_int = undefined;
    var slave: c_int = undefined;
    if (openpty(&master, &slave, null, null, null) != 0) return null;
    defer _ = std.c.close(master);

    const fork_ret = std.c.fork();
    if (fork_ret < 0) {
        _ = std.c.close(slave);
        return null;
    }
    const pid: posix.pid_t = @intCast(fork_ret);
    if (pid == 0) {
        _ = std.c.setsid();
        _ = std.c.dup2(slave, posix.STDIN_FILENO);
        _ = std.c.dup2(slave, posix.STDOUT_FILENO);
        _ = std.c.dup2(slave, posix.STDERR_FILENO);
        _ = std.c.close(slave);
        _ = std.c.close(master);
        var termios: std.c.termios = undefined;
        if (std.c.tcgetattr(posix.STDOUT_FILENO, &termios) == 0) {
            termios.oflag.OPOST = false;
            _ = std.c.tcsetattr(posix.STDOUT_FILENO, .NOW, &termios);
        }
        _ = std.c.execve(shell.ptr, &argv, envp.slice.ptr);
        std.c._exit(127);
    }
    _ = std.c.close(slave);

    var output: std.ArrayList(u8) = .empty;
    const deadline = std.Io.Clock.now(.awake, io).toMilliseconds() + timeout_ms;
    var status: c_int = 0;
    var exited = false;
    while (true) {
        const now = std.Io.Clock.now(.awake, io).toMilliseconds();
        if (now >= deadline) {
            _ = std.c.kill(-pid, .KILL);
            while (std.c.waitpid(pid, &status, 0) < 0 and std.posix.errno(-1) == .INTR) {}
            return null;
        }
        var fds = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.IN, .revents = 0 }};
        const wait: i32 = if (exited) 0 else @intCast(@min(deadline - now, 20));
        const ready = posix.poll(&fds, wait) catch 0;
        if (ready > 0) {
            var buf: [4096]u8 = undefined;
            const n = std.c.read(master, &buf, buf.len);
            if (n > 0) {
                try output.appendSlice(arena, buf[0..@intCast(n)]);
                continue;
            }
            if (exited) break;
        } else if (exited) break;
        if (!exited and std.c.waitpid(pid, &status, posix.W.NOHANG) == pid) exited = true;
    }
    const us: u32 = @bitCast(status);
    if (!posix.W.IFEXITED(us) or posix.W.EXITSTATUS(us) != 0) return null;
    return output.items;
}
