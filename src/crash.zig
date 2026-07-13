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

/// Set/reset the cleanup hook run before a crash report
pub fn set_cleanup(c: ?Cleanup) void {
    cleanup = c;
}

var sink: Sink = .tty;
var cleanup: ?Cleanup = null;
var jit_debugger: bool = false;
var in_progress: std.atomic.Value(bool) = .init(false);

pub fn crash_in_progress() bool {
    return in_progress.load(.acquire);
}

pub fn set_jit_debugger(enabled: bool) void {
    jit_debugger = enabled;
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
        .flags = (std.posix.SA.SIGINFO | std.posix.SA.RESTART),
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
        if (sink == .file)
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
        thespian.sighdl_debugger(@intCast(@intFromEnum(sig)), @ptrCast(@constCast(info)), ctx_ptr);

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
    const c = cleanup;
    cleanup = null;
    if (c) |cb| cb.func(cb.ctx);
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
    switch (sink) {
        .tty => {
            const term = std.debug.lockStderr(&.{}).terminal();
            defer std.debug.unlockStderr();
            write_report(term, name, msg, unwind);
        },
        .file => write_crash_log_file(name, msg, unwind),
    }
}

fn write_crash_log_file(kind: []const u8, msg: []const u8, unwind: std.debug.StackUnwindOptions) void {
    if (builtin.os.tag == .windows) {
        var note: [256]u8 = undefined;
        if (std.fmt.bufPrintZ(&note, "flow crashed: {s}{s}{s} (see crash.log)\n", .{
            kind,
            if (msg.len > 0) ": " else "",
            msg,
        })) |z| OutputDebugStringA(z.ptr) else |_| {}
    }

    const io = root.get_io();
    const dir = root.get_state_dir() catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{c}crash.log", .{ dir, std.fs.path.sep }) catch return;
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
