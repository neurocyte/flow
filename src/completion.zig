const std = @import("std");
const tp = @import("thespian");

const OutOfMemoryError = error{OutOfMemory};
const SpawnError = error{ThespianSpawnFailed};

pub fn send(
    allocator: std.mem.Allocator,
    to: tp.pid_ref,
    m: anytype,
    ctx: anytype,
) (OutOfMemoryError || SpawnError)!void {
    return RequestContext(@TypeOf(ctx)).send(allocator, to, ctx, tp.message.fmt(m));
}

fn RequestContext(T: type) type {
    return struct {
        receiver: ReceiverT,
        ctx: T,
        to: tp.pid,
        request: tp.message,
        response: ?tp.message,
        a: std.mem.Allocator,

        const Self = @This();
        const ReceiverT = tp.Receiver(*@This());

        fn send(a: std.mem.Allocator, to: tp.pid_ref, ctx: T, request: tp.message) (OutOfMemoryError || SpawnError)!void {
            const self = try a.create(@This());
            self.* = .{
                .receiver = undefined,
                .ctx = if (@hasDecl(T, "clone")) ctx.clone() else ctx,
                .to = to.clone(),
                .request = try request.clone(std.heap.c_allocator),
                .response = null,
                .a = a,
            };
            self.receiver = ReceiverT.init(receive_, self);
            const proc = try tp.spawn_link(a, self, start, @typeName(@This()));
            defer proc.deinit();
        }

        fn deinit(self: *@This()) void {
            if (@hasDecl(T, "deinit")) self.ctx.deinit();
            std.heap.c_allocator.free(self.request.buf);
            self.to.deinit();
            self.a.destroy(self);
        }

        fn start(self: *@This()) tp.result {
            _ = tp.set_trap(true);
            if (@hasDecl(T, "link")) try self.ctx.link();
            errdefer self.deinit();
            try self.to.link();
            try self.to.send_raw(self.request);
            tp.receive(&self.receiver);
        }

        fn receive_(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
            defer self.deinit();
            self.ctx.receive(m) catch |e| return tp.exit_error(e, @errorReturnTrace());
            return tp.exit_normal();
        }
    };
}
