//! Crash handling

const std = @import("std");
const builtin = @import("builtin");
const root = @import("soft_root").root;
const thespian = @import("thespian");

const Sink = enum { tty, file };

/// Cleanup hook. Must be signal-handler safe.
pub const Cleanup = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub const CleanupHandle = enum(usize) { _ };

/// Maximum number of cleanup hooks.
const max_cleanups = 4;

/// Install a cleanup hook, run before a crash report. Hooks are run in
/// reverse install order.
pub fn add_cleanup(c: Cleanup) CleanupHandle {
    if (cleanups_len >= max_cleanups) @panic("crash: too many cleanup hooks");
    const handle = cleanups_len;
    cleanups[handle] = c;
    cleanups_len += 1;
    return @fromBackingInt(@intCast(handle));
}

/// Remove a previously installed cleanup hook.
pub fn remove_cleanup(handle_: CleanupHandle) void {
    const handle: usize = @backingInt(handle_);
    if (handle >= cleanups.len) return;
    cleanups[handle] = null;
    while (cleanups_len > 0 and cleanups[cleanups_len - 1] == null)
        cleanups_len -= 1;
}

var sink: Sink = .tty;
var cleanups: [max_cleanups]?Cleanup = @splat(null);
var cleanups_len: usize = 0;
var jit_debugger: bool = false;
var in_progress: std.atomic.Value(bool) = .init(false);
var restart_executable: ?[*:0]const u8 = null;
var restart_args: []const [:0]const u8 = &.{};
var restart_environ: Environ = undefined;
var restart_command_line: ?[:0]u16 = null;
var restart_started: i64 = 0;

pub const Environ = if (builtin.os.tag == .windows) void else [*:null]const ?[*:0]const u8;

/// short runs do not restart to avoid crash loops
const restart_min_uptime_s = 3;

pub fn crash_in_progress() bool {
    return in_progress.load(.acquire);
}

pub fn set_jit_debugger(enabled: bool) void {
    jit_debugger = enabled;
}

/// Restart after a crash
/// `executable` and `args` must outlive the process
pub fn set_restart_on_crash(allocator: std.mem.Allocator, executable: [:0]const u8, args: []const [:0]const u8, environ: Environ) !void {
    if (builtin.os.tag == .windows)
        restart_command_line = try windows_command_line(allocator, executable, args);
    restart_executable = executable.ptr;
    restart_args = args;
    restart_environ = environ;
    restart_started = monotonic_seconds();
}

fn windows_command_line(allocator: std.mem.Allocator, executable: []const u8, args: []const [:0]const u8) ![:0]u16 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try log_file_path(&path_buf);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.print(allocator, "\"{s}\" --restore-session --exec show_crash_dialog", .{executable});
    for (args) |arg| try append_windows_arg(allocator, &line, arg);
    try append_windows_arg(allocator, &line, log_path);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, line.items);
}

fn append_windows_arg(allocator: std.mem.Allocator, line: *std.ArrayList(u8), arg: []const u8) !void {
    try line.append(allocator, ' ');
    const needs_quotes = for (arg) |c| {
        if (c <= ' ' or c == '"') break true;
    } else arg.len == 0;
    if (!needs_quotes) return line.appendSlice(allocator, arg);
    try line.append(allocator, '"');
    var backslashes: usize = 0;
    for (arg) |c| switch (c) {
        '\\' => backslashes += 1,
        '"' => {
            try line.appendNTimes(allocator, '\\', backslashes * 2 + 1);
            try line.append(allocator, '"');
            backslashes = 0;
        },
        else => {
            try line.appendNTimes(allocator, '\\', backslashes);
            try line.append(allocator, c);
            backslashes = 0;
        },
    };
    try line.appendNTimes(allocator, '\\', backslashes * 2);
    try line.append(allocator, '"');
}

/// Install crash handler
pub fn install() void {
    sink = if (std.Io.File.stderr().isTty(root.get_io()) catch false) .tty else .file;
    if (sink == .file) _ = root.get_state_dir() catch {}; // warm the cached path
    if (!std.debug.have_segfault_handling_support) return;
    switch (builtin.os.tag) {
        .windows => std.debug.attachSegfaultHandler(),
        else => install_posix(),
    }
}

fn install_posix() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handle_crash_posix },
        .mask = std.posix.sigemptyset(),
        // RESETHAND: abort() from inside the handler must not re-enter it
        .flags = (std.posix.SA.SIGINFO | std.posix.SA.RESTART | std.posix.SA.RESETHAND),
    };
    std.posix.sigaction(std.posix.SIG.SEGV, &act, null);
    std.posix.sigaction(std.posix.SIG.BUS, &act, null);
    std.posix.sigaction(std.posix.SIG.ABRT, &act, null);
    std.posix.sigaction(std.posix.SIG.FPE, &act, null);
    std.posix.sigaction(std.posix.SIG.ILL, &act, null);
}

/// Root panic handler
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    const addr = ret_addr orelse @returnAddress();
    if (!in_progress.swap(true, .acq_rel)) {
        run_cleanup();
        if (sink == .file or restart_executable != null)
            write_crash_log_file("panic", msg, .{ .first_address = addr });
    }
    return std.debug.defaultPanic(msg, addr);
}

/// Hardware-fault handler
pub fn handle_segfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
    if (!in_progress.swap(true, .acq_rel)) {
        run_cleanup();
        report_fault(name, addr, ctx);
    }
    std.process.abort();
}

/// POSIX signal handler
fn handle_crash_posix(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    if (in_progress.swap(true, .acq_rel)) std.c.abort();
    run_cleanup();

    const name = switch (sig) {
        .SEGV => "Segmentation fault",
        .ILL => "Illegal instruction",
        .BUS => "Bus error",
        .FPE => "Arithmetic exception",
        .ABRT => "Aborted",
        else => "Crash",
    };
    const addr = fault_address(info);
    var native = std.debug.cpu_context.fromPosixSignalContext(ctx_ptr);
    const ctx: ?std.debug.CpuContextPtr = if (native) |*n| n else null;

    report_fault(name, addr, ctx);

    if (builtin.os.tag == .linux and jit_debugger)
        thespian.sighdl_debugger(@intCast(@backingInt(sig)), @ptrCast(@constCast(info)), ctx_ptr);

    std.c.abort();
}

fn fault_address(info: *const std.posix.siginfo_t) ?usize {
    return switch (builtin.os.tag) {
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .freebsd, .macos => @intFromPtr(info.addr),
        .netbsd => @intFromPtr(info.info.reason.fault.addr),
        .openbsd => @intFromPtr(info.data.fault.addr),
        .illumos => @intFromPtr(info.reason.fault.addr),
        else => null,
    };
}

fn run_cleanup() void {
    var i = cleanups_len;
    while (i > 0) {
        i -= 1;
        const c = cleanups[i];
        cleanups[i] = null;
        if (c) |cb| cb.func(cb.ctx);
    }
    cleanups_len = 0;
}

fn report_fault(name: []const u8, addr: ?usize, ctx: ?std.debug.CpuContextPtr) void {
    const unwind: std.debug.StackUnwindOptions = .{
        .first_address = if (ctx == null) addr else null,
        .context = ctx,
        .allow_unsafe_unwind = true,
    };
    var buf: [64]u8 = undefined;
    const msg = if (addr) |a|
        std.fmt.bufPrint(&buf, "at address 0x{x}", .{a}) catch ""
    else
        "";
    if (sink == .tty) {
        const term = std.debug.lockStderr(&.{}).terminal();
        defer std.debug.unlockStderr();
        write_report(term, name, msg, unwind);
    }
    if (sink == .file or restart_executable != null)
        write_crash_log_file(name, msg, unwind);
}

pub fn log_file_path(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{c}crash.log", .{ try root.get_state_dir(), std.fs.path.sep });
}

fn write_crash_log_file(kind: []const u8, msg: []const u8, unwind: std.debug.StackUnwindOptions) void {
    if (builtin.os.tag == .windows) {
        var note: [256]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&note, "flow crashed: {s}{s}{s} (see crash.log)\n", .{
            kind,
            if (msg.len > 0) ": " else "",
            msg,
        }, 0)) |z| OutputDebugStringA(z.ptr) else |_| {}
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = log_file_path(&path_buf) catch return;
    write_crash_log_to_path(path, kind, msg, unwind);
    restart_after_crash(path);
}

fn restart_after_crash(log_path: []const u8) void {
    const executable = restart_executable orelse return;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{log_path}, 0) catch return;
    const uptime = monotonic_seconds() - restart_started;
    if (uptime < restart_min_uptime_s)
        return report_no_restart(path, "crashed {d}s after start, restarting needs {d}s", .{ uptime, restart_min_uptime_s });
    if (builtin.os.tag == .windows) return restart_windows(path, executable);
    // the crashing signal is blocked in its handler and the mask survives execve
    const all = std.posix.sigfillset();
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &all, null);
    set_close_on_exec_all();
    const head = [_][*:0]const u8{ executable, "--restore-session", "--exec", "show_crash_dialog" };
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    if (head.len + restart_args.len + 1 > argv.len)
        return report_no_restart(path, "too many arguments", .{});
    var argc: usize = 0;
    for (head) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    for (restart_args) |arg| {
        argv[argc] = arg.ptr;
        argc += 1;
    }
    argv[argc] = path.ptr;
    const ret = std.c.execve(executable, &argv, restart_environ);
    report_no_restart(path, "executing {s} failed: E{t}", .{ executable, std.posix.errno(ret) });
}

fn restart_windows(log_path: [:0]const u8, executable: [*:0]const u8) void {
    const windows = std.os.windows;
    const command_line = restart_command_line orelse return;
    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    var process_info: windows.PROCESS.INFORMATION = undefined;
    if (!windows.kernel32.CreateProcessW(null, command_line.ptr, null, null, .FALSE, .{}, null, null, &startup_info, &process_info).toBool())
        return report_no_restart(log_path, "starting {s} failed: error {d}", .{ executable, @backingInt(windows.GetLastError()) });
    windows.ntdll.RtlExitUserProcess(3);
}

fn report_no_restart(log_path: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "flow did not restart after the crash: " ++ fmt ++ "\n", args) catch return;
    if (builtin.os.tag == .windows) return append_crash_log_windows(log_path, msg);
    _ = std.c.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
    const fd = std.c.open(log_path, .{ .ACCMODE = .WRONLY, .APPEND = true });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, msg.ptr, msg.len);
}

fn set_close_on_exec_all() void {
    const limit = std.posix.getrlimit(.NOFILE) catch return;
    const max: std.posix.fd_t = @intCast(@min(limit.cur, 1 << 16));
    var fd: std.posix.fd_t = 3;
    while (fd < max) : (fd += 1) {
        const flags = std.c.fcntl(fd, std.posix.F.GETFD);
        if (flags >= 0) _ = std.c.fcntl(fd, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC);
    }
}

fn append_crash_log_windows(log_path: []const u8, msg: []const u8) void {
    var note_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&note_buf, "{s}", .{msg}, 0)) |note| OutputDebugStringA(note.ptr) else |_| {}
    const io = root.get_io();
    const file = std.Io.Dir.openFileAbsolute(io, log_path, .{ .mode = .write_only }) catch return;
    defer file.close(io);
    const end = file.length(io) catch return;
    var writer = file.writer(io, &.{});
    writer.seekTo(end) catch return;
    writer.interface.writeAll(msg) catch {};
}

fn monotonic_seconds() i64 {
    if (builtin.os.tag == .windows) return @intCast(GetTickCount64() / std.time.ms_per_s);
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

fn write_crash_log_to_path(path: []const u8, kind: []const u8, msg: []const u8, unwind: std.debug.StackUnwindOptions) void {
    const io = root.get_io();
    const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    defer fw.interface.flush() catch {};
    write_report(.{ .writer = &fw.interface, .mode = .no_color }, kind, msg, unwind);
}

fn write_report(term: std.Io.Terminal, kind: []const u8, msg: []const u8, unwind: std.debug.StackUnwindOptions) void {
    const w = term.writer;
    w.print("flow {s} crashed: {s}", .{ root.version, kind }) catch {};
    if (msg.len > 0) w.print(": {s}", .{msg}) catch {};
    w.writeByte('\n') catch {};
    std.debug.writeCurrentStackTrace(unwind, term) catch {};
}

extern "kernel32" fn OutputDebugStringA(lpOutputString: [*:0]const u8) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
