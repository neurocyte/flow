//! Windows pty actor: reads ConPTY output pipe via tp.file_stream (IOCP overlapped I/O).
//!
//! Exit detection: ConPTY does NOT close the output pipe when the child process exits -
//! it keeps it open until ClosePseudoConsole is called. So a pending async read would
//! block forever. Instead we use RegisterWaitForSingleObject on the process handle;
//! when it fires the threadpool callback posts "child_exited" to this actor, which
//! cancels the stream and tears down cleanly.

const std = @import("std");
const tp = @import("thespian");
const Terminal = @import("Terminal");

const Parser = Terminal.Parser;
const Receiver = tp.Receiver(*@This());
const windows = std.os.windows;

// Context struct allocated on the heap and passed to the wait callback.
// Heap-allocated so its lifetime is independent of the actor.
const WaitCtx = struct {
    self_pid: tp.pid,
    allocator: std.mem.Allocator,
};

allocator: std.mem.Allocator,
vt: *Terminal,
stream: ?tp.file_stream = null,
parser: Parser,
receiver: Receiver,
parent: tp.pid,
wait_handle: ?windows.HANDLE = null,

pub fn spawn(allocator: std.mem.Allocator, vt: *Terminal) !tp.pid {
    const self = try allocator.create(@This());
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .vt = vt,
        .parser = .{ .buf = try .initCapacity(allocator, 128) },
        .receiver = Receiver.init(pty_receive, dtor, self),
        .parent = tp.self_pid().clone(),
    };
    return tp.spawn_link(allocator, self, start, "pty_actor");
}

fn dtor(self: *@This()) void {
    if (self.wait_handle) |wh| {
        _ = UnregisterWait(wh);
        self.wait_handle = null;
    }
    if (self.stream) |s| s.deinit();
    self.parser.buf.deinit();
    self.parent.deinit();
    self.allocator.destroy(self);
}

fn deinit(_: *@This()) void {
    std.log.debug("terminal: pty actor (windows) deinit", .{});
}

fn start(self: *@This()) tp.result {
    errdefer self.deinit();
    self.stream = tp.file_stream.init("pty_out", self.vt.ptyOutputHandle()) catch |e| {
        std.log.debug("terminal: pty stream init failed: {}", .{e});
        return tp.exit_error(e, @errorReturnTrace());
    };
    self.stream.?.start_read() catch |e| {
        std.log.debug("terminal: pty stream start_read failed: {}", .{e});
        return tp.exit_error(e, @errorReturnTrace());
    };

    // Register a one-shot wait on the process handle. When the child exits
    // the threadpool fires on_child_exit, which sends "child_exited" to us.
    // This is the only reliable way to detect ConPTY child exit without polling,
    // since ConPTY keeps the output pipe open until ClosePseudoConsole.
    const process_handle = self.vt.cmd.process_handle orelse {
        std.log.debug("terminal: pty actor: no process handle to wait on", .{});
        return tp.exit_error(error.NoProcessHandle, @errorReturnTrace());
    };
    const ctx = self.allocator.create(WaitCtx) catch |e|
        return tp.exit_error(e, @errorReturnTrace());
    ctx.* = .{
        .self_pid = tp.self_pid().clone(),
        .allocator = self.allocator,
    };
    var wh: windows.HANDLE = undefined;
    // WT_EXECUTEONLYONCE: callback fires once then the wait is auto-unregistered.
    const WT_EXECUTEONLYONCE: windows.ULONG = 0x00000008;
    if (RegisterWaitForSingleObject(&wh, process_handle, on_child_exit, ctx, INFINITE, WT_EXECUTEONLYONCE) == .FALSE) {
        ctx.self_pid.deinit();
        self.allocator.destroy(ctx);
        std.log.debug("terminal: RegisterWaitForSingleObject failed", .{});
        return tp.exit_error(error.RegisterWaitFailed, @errorReturnTrace());
    }
    self.wait_handle = wh;

    tp.receive(&self.receiver);
}

/// Threadpool callback - called when the process handle becomes signaled.
/// Must be fast and non-blocking. Sends "child_exited" to the pty actor.
fn on_child_exit(ctx_ptr: ?*anyopaque, _: windows.BOOLEAN) callconv(.winapi) void {
    const ctx: *WaitCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
    defer {
        ctx.self_pid.deinit();
        ctx.allocator.destroy(ctx);
    }
    ctx.self_pid.send(.{"child_exited"}) catch {};
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

    var bytes: []const u8 = "";
    var err_code: i64 = 0;
    var err_msg: []const u8 = "";

    if (try m.match(.{"child_exited"})) {
        self.wait_handle = null;
        if (self.stream) |s| s.cancel() catch {};
        const code = self.vt.cmd.wait();
        std.log.debug("terminal: child exited (process wait), code={d}", .{code});
        try self.send_event_result(.{ .exited = code });
        return tp.exit_normal();
    } else if (try m.match(.{ "stream", "pty_out", "read_complete", tp.extract(&bytes) })) {
        switch (self.vt.processOutput(&self.parser, bytes, self, pty_process_terminal_event) catch |e| {
            std.log.debug("terminal: processOutput error: {}", .{e});
            return tp.exit_normal();
        }) {
            .exited => {
                std.log.debug("terminal: processOutput returned .exited", .{});
                return tp.exit_normal();
            },
            .running => {},
        }
        self.stream.?.start_read() catch |e| {
            std.log.debug("terminal: pty stream re-arm failed: {}", .{e});
            return tp.exit_normal();
        };
    } else if (try m.match(.{ "stream", "pty_out", "read_error", tp.extract(&err_code), tp.extract(&err_msg) })) {
        std.log.debug("terminal: ConPTY stream error: {d} {s}", .{ err_code, err_msg });
        const code = self.vt.cmd.wait();
        try self.send_event_result(.{ .exited = code });
        return tp.exit_normal();
    } else if (try m.match(.{"quit"})) {
        std.log.debug("terminal: pty actor (windows) received quit", .{});
        return tp.exit_normal();
    } else {
        std.log.debug("terminal: pty actor (windows) unexpected message", .{});
        return tp.unexpected(m);
    }
}

// Win32 extern declarations
extern "kernel32" fn RegisterWaitForSingleObject(
    phNewWaitObject: *windows.HANDLE,
    hObject: windows.HANDLE,
    Callback: *const fn (?*anyopaque, windows.BOOLEAN) callconv(.winapi) void,
    Context: ?*anyopaque,
    dwMilliseconds: windows.DWORD,
    dwFlags: windows.ULONG,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn UnregisterWait(
    WaitHandle: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

const INFINITE: windows.DWORD = 0xFFFFFFFF;
