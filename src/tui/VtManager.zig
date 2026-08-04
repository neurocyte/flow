const std = @import("std");
const tp = @import("thespian");
const command = @import("command");

const Vt = @import("Vt.zig");
const TerminalOnExit = @import("config").TerminalOnExit;

var global_vt: ?Vt = null;

pub fn create(env: std.process.Environ.Map, on_exit: TerminalOnExit) !*Vt {
    if (global_vt) |_| @panic("global_vt already exists");
    global_vt = .{
        .vt = undefined,
        .env = env,
        .write_buf = undefined, // managed via self.vt's pty_writer pointer
        .pty_pid = null,
        .on_exit = on_exit,
    };
    return &global_vt.?;
}

pub fn destroyed(gone: *Vt) void {
    if (global_vt) |*vt| if (@intFromPtr(vt) == @intFromPtr(gone)) {
        global_vt = null;
    };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, ctx: command.Context, rows: u16, cols: u16) !*Vt {
    if (global_vt) |*vt| {
        try vt.run_cmd(ctx);
        return vt;
    }
    return try Vt.run_new_cmd(io, allocator, ctx, rows, cols);
}

pub fn shutdown_all() void {
    if (global_vt) |*vt| {
        vt.deinit(vt.vt.allocator);
        global_vt = null;
    }
}

pub fn receive_event(from: tp.pid_ref, m: tp.message) !void {
    const vt = &(global_vt orelse return);
    var event: Vt.Event = undefined;
    if (!(m.match(.{ "VT", tp.extract(&event) }) catch false)) return;

    if (vt.pty_pid) |pty_pid| if (pty_pid.instance_id() == from.instance_id())
        try vt.process_event(event);
}
