const std = @import("std");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");

const Vt = @import("Vt.zig");
const TerminalOnExit = @import("config").TerminalOnExit;

var vts: std.ArrayListUnmanaged(*Vt) = .empty;

var most_recent: ?*Vt = null;

pub fn set_most_recent(vt: *Vt) void {
    most_recent = vt;
}

pub fn most_recent_index() ?usize {
    return index_of(most_recent);
}

pub fn create(env: std.process.Environ.Map, on_exit: TerminalOnExit) !*Vt {
    const allocator = root.get_init().gpa;
    const self = try allocator.create(Vt);
    errdefer allocator.destroy(self);
    self.* = .{
        .vt = undefined,
        .env = env,
        .write_buf = undefined, // managed via self.vt's pty_writer pointer
        .pty_pid = null,
        .on_exit = on_exit,
    };
    try vts.append(allocator, self);
    return self;
}

pub fn destroyed(gone: *Vt) void {
    const allocator = root.get_init().gpa;
    if (most_recent == gone) most_recent = null;
    for (vts.items, 0..) |vt, i| if (vt == gone) {
        _ = vts.orderedRemove(i);
        break;
    };
    allocator.destroy(gone);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, ctx: command.Context, rows: u16, cols: u16) !*Vt {
    if (most_recent) |mr| if (index_of(mr) != null) switch (try mr.run_cmd(ctx)) {
        .ok => return set_most_recent_and(mr),
        .busy => {},
    };
    for (vts.items) |vt| {
        if (vt == most_recent) continue; // already tried above
        switch (try vt.run_cmd(ctx)) {
            .ok => return set_most_recent_and(vt),
            .busy => continue,
        }
    }
    return set_most_recent_and(try Vt.run_new_cmd(io, allocator, ctx, rows, cols));
}

fn set_most_recent_and(vt: *Vt) *Vt {
    most_recent = vt;
    return vt;
}

pub fn shutdown_all() void {
    while (vts.items.len > 0) {
        const vt = vts.items[vts.items.len - 1];
        vt.deinit(vt.vt.allocator);
    }
    vts.clearAndFree(root.get_init().gpa);
    most_recent = null;
}

pub fn receive_event(from: tp.pid_ref, m: tp.message) !void {
    var event: Vt.Event = undefined;
    if (!(m.match(.{ "VT", tp.extract(&event) }) catch false)) return;

    for (vts.items) |vt| {
        if (vt.pty_pid) |pty_pid| if (pty_pid.instance_id() == from.instance_id()) {
            try vt.process_event(event);
            return;
        };
    }
}

pub fn position(target: *const Vt) ?struct { index: usize, count: usize } {
    for (vts.items, 0..) |vt, i| if (vt == target)
        return .{ .index = i + 1, .count = vts.items.len };
    return null;
}

pub fn running_except(exclude: *const Vt) ?*Vt {
    for (vts.items) |vt| if (vt != exclude and !vt.process_exited) return vt;
    return null;
}

pub fn index_of(target: ?*const Vt) ?usize {
    const t = target orelse return null;
    for (vts.items, 0..) |vt, i| if (vt == t) return i;
    return null;
}

pub fn by_index(idx: usize) ?*Vt {
    for (vts.items, 0..) |vt, i| if (i == idx) return vt;
    return null;
}

pub fn next(current: ?*const Vt) ?*Vt {
    if (vts.items.len == 0) return null;
    const i = index_of(current) orelse return vts.items[0];
    return vts.items[(i + 1) % vts.items.len];
}

pub fn prev(current: ?*const Vt) ?*Vt {
    if (vts.items.len == 0) return null;
    const i = index_of(current) orelse return vts.items[vts.items.len - 1];
    return vts.items[(i + vts.items.len - 1) % vts.items.len];
}

pub fn reap_exited(keep: ?*const Vt) void {
    var i: usize = 0;
    while (i < vts.items.len) {
        const vt = vts.items[i];
        if (vt.process_exited and vt != keep) {
            // deinit calls back into destroyed(), which removes vt at index i,
            // shifting the next entry into i, so we do not advance here.
            vt.deinit(vt.vt.allocator);
        } else i += 1;
    }
}
