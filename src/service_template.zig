const std = @import("std");
const tp = @import("thespian");
const log = @import("log");

pid: ?tp.pid,

const Self = @This();
const module_name = @typeName(Self);
pub const Error = error{ OutOfMemory, Exit };

pub fn create(allocator: std.mem.Allocator) Error!Self {
    return .{ .pid = try Process.create(allocator) };
}

pub fn from_pid(pid: tp.pid_ref) Error!Self {
    return .{ .pid = pid.clone() };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        self.pid = null;
        pid.deinit();
    }
}

pub fn shutdown(self: *Self) void {
    if (self.pid) |pid| {
        pid.send(.{"shutdown"}) catch {};
        self.deinit();
    }
}

// pub fn send(self: *Self, m: tp.message) tp.result {
//     const pid = self.pid orelse return tp.exit_error(error.Shutdown);
//     try pid.send(m);
// }

const Process = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    logger: log.Logger,
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);

    pub fn create(allocator: std.mem.Allocator) Error!tp.pid {
        const self = try allocator.create(Process);
        self.* = .{
            .allocator = allocator,
            .parent = tp.self_pid().clone(),
            .logger = log.logger(module_name),
            .receiver = Receiver.init(Process.receive, self),
        };
        return tp.spawn_link(self.a, self, Process.start) catch |e| tp.exit_error(e);
    }

    fn deinit(self: *Process) void {
        self.parent.deinit();
        self.logger.deinit();
        self.a.destroy(self);
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        if (try m.match(.{"shutdown"})) {
            return tp.exit_normal();
        } else {
            self.logger.err("receive", tp.unexpected(m));
            return tp.unexpected(m);
        }
    }
};
