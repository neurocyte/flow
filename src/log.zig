const std = @import("std");
const tp = @import("thespian");

const deque = std.TailQueue;
const fba = std.heap.FixedBufferAllocator;

const Self = @This();

pub const max_log_message = tp.max_message_size - 128;

a: std.mem.Allocator,
receiver: Receiver,
subscriber: ?tp.pid,
heap: [32 + 1024]u8,
fba: fba,
msg_store: MsgStoreT,

const MsgStoreT = std.DoublyLinkedList([]u8);
const Receiver = tp.Receiver(*Self);

const StartArgs = struct {
    a: std.mem.Allocator,
};

pub fn spawn(ctx: *tp.context, a: std.mem.Allocator, env: ?*const tp.env) !tp.pid {
    return try ctx.spawn_link(StartArgs{ .a = a }, Self.start, "log", null, env);
}

fn start(args: StartArgs) tp.result {
    _ = tp.set_trap(true);
    var this = Self.init(args) catch |e| return tp.exit_error(e);
    errdefer this.deinit();
    tp.receive(&this.receiver);
}

fn init(args: StartArgs) !*Self {
    var p = try args.a.create(Self);
    p.* = .{
        .a = args.a,
        .receiver = Receiver.init(Self.receive, p),
        .subscriber = null,
        .heap = undefined,
        .fba = fba.init(&p.heap),
        .msg_store = MsgStoreT{},
    };
    return p;
}

fn deinit(self: *const Self) void {
    if (self.subscriber) |*s| s.deinit();
    self.a.destroy(self);
}

fn log(msg: []const u8) void {
    tp.self_pid().send(.{ "log", "log", msg }) catch {};
}

fn store(self: *Self, m: tp.message) void {
    const a: std.mem.Allocator = self.fba.allocator();
    const buf: []u8 = a.alloc(u8, m.len()) catch return;
    var node: *MsgStoreT.Node = a.create(MsgStoreT.Node) catch return;
    node.data = buf;
    @memcpy(buf, m.buf);
    self.msg_store.append(node);
}

fn store_send(self: *Self) void {
    var node = self.msg_store.first;
    if (self.subscriber) |sub| {
        while (node) |node_| {
            sub.send_raw(tp.message{ .buf = node_.data }) catch return;
            node = node_.next;
        }
    }
    self.store_reset();
}

fn store_reset(self: *Self) void {
    self.msg_store = MsgStoreT{};
    self.fba.reset();
}

fn receive(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
    errdefer self.deinit();
    if (try m.match(.{ "log", tp.more })) {
        if (self.subscriber) |subscriber| {
            subscriber.send_raw(m) catch {};
        } else {
            self.store(m);
        }
    } else if (try m.match(.{"subscribe"})) {
        // log("subscribed");
        if (self.subscriber) |*s| s.deinit();
        self.subscriber = from.clone();
        self.store_send();
    } else if (try m.match(.{"unsubscribe"})) {
        // log("unsubscribed");
        if (self.subscriber) |*s| s.deinit();
        self.subscriber = null;
        self.store_reset();
    } else if (try m.match(.{"shutdown"})) {
        return tp.exit_normal();
    }
}

pub const Logger = struct {
    proc: tp.pid,
    tag: []const u8,

    pub fn deinit(self: *const Logger) void {
        self.proc.deinit();
    }

    pub fn write(self: Logger, value: anytype) void {
        self.proc.send(.{ "log", self.tag } ++ value) catch {};
    }

    pub fn print(self: Logger, comptime fmt: anytype, args: anytype) void {
        var buf: [max_log_message]u8 = undefined;
        const output = std.fmt.bufPrint(&buf, fmt, args) catch "MESSAGE TOO LARGE";
        self.proc.send(.{ "log", self.tag, output }) catch {};
    }

    pub fn err(self: Logger, context: []const u8, e: anyerror) void {
        defer tp.reset_error();
        var buf: [max_log_message]u8 = undefined;
        var msg: []const u8 = "UNKNOWN";
        switch (e) {
            error.Exit => {
                const msg_: tp.message = .{ .buf = tp.error_message() };
                var msg__: []const u8 = undefined;
                if (!(msg_.match(.{ "exit", tp.extract(&msg__) }) catch false))
                    msg__ = msg_.buf;
                if (msg__.len > buf.len) {
                    self.proc.send(.{ "log", "error", self.tag, context, "->", "MESSAGE TOO LARGE" }) catch {};
                    return;
                }
                const msg___ = buf[0..msg__.len];
                @memcpy(msg___, msg__);
                msg = msg___;
            },
            else => {
                msg = @errorName(e);
            },
        }
        self.proc.send(.{ "log", "error", self.tag, context, "->", msg }) catch {};
    }
};

pub fn logger(tag: []const u8) Logger {
    return .{ .proc = tp.env.get().proc("log").clone(), .tag = tag };
}

pub fn print(tag: []const u8, comptime fmt: anytype, args: anytype) void {
    const l = logger(tag);
    defer l.deinit();
    return l.print(fmt, args);
}

pub fn err(tag: []const u8, context: []const u8, e: anyerror) void {
    const l = logger(tag);
    defer l.deinit();
    return l.err(context, e);
}

pub fn subscribe() tp.result {
    return tp.env.get().proc("log").send(.{"subscribe"});
}

pub fn unsubscribe() tp.result {
    return tp.env.get().proc("log").send(.{"unsubscribe"});
}
