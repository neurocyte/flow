const std = @import("std");
const tp = @import("thespian");

const Self = @This();

pub const max_log_message = tp.max_message_size - 128;

allocator: std.mem.Allocator,
receiver: Receiver,
subscriber: ?tp.pid,
heap: [32 + 1024]u8,
fba: std.heap.FixedBufferAllocator,
msg_store: MsgStore,
no_stdout: bool = false,
no_stderr: bool = false,

const MsgStore = std.DoublyLinkedList;
const MsgStoreEntry = struct {
    data: []u8,
    node: MsgStore.Node,
};

const Receiver = tp.Receiver(*Self);

const StartArgs = struct {
    allocator: std.mem.Allocator,
};

pub fn spawn(ctx: *tp.context, allocator: std.mem.Allocator, env: ?*const tp.env) !tp.pid {
    return try ctx.spawn_link(StartArgs{ .allocator = allocator }, Self.start, "log", null, env);
}

fn start(args: StartArgs) tp.result {
    _ = tp.set_trap(true);
    var this = Self.init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    errdefer this.deinit();
    tp.receive(&this.receiver);
}

fn init(args: StartArgs) !*Self {
    var p = try args.allocator.create(Self);
    p.* = .{
        .allocator = args.allocator,
        .receiver = Receiver.init(Self.receive, p),
        .subscriber = null,
        .heap = undefined,
        .fba = std.heap.FixedBufferAllocator.init(&p.heap),
        .msg_store = MsgStore{},
    };
    return p;
}

fn deinit(self: *const Self) void {
    if (self.subscriber) |*s| s.deinit();
    self.allocator.destroy(self);
}

fn log(msg: []const u8) void {
    tp.self_pid().send(.{ "log", "log", msg }) catch {};
}

fn store(self: *Self, m: tp.message) void {
    const allocator: std.mem.Allocator = self.fba.allocator();
    const buf: []u8 = allocator.alloc(u8, m.len()) catch return;
    var msg: *MsgStoreEntry = allocator.create(MsgStoreEntry) catch return;
    msg.data = buf;
    @memcpy(buf, m.buf);
    self.msg_store.append(&msg.node);
}

fn store_send(self: *Self) void {
    var node = self.msg_store.first;
    if (self.subscriber) |sub| {
        while (node) |node_| {
            const msg: *MsgStoreEntry = @fieldParentPtr("node", node_);
            sub.send_raw(tp.message{ .buf = msg.data }) catch return;
            node = node_.next;
        }
    }
    self.store_reset();
}

fn store_reset(self: *Self) void {
    self.msg_store = MsgStore{};
    self.fba.reset();
}

fn receive(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
    errdefer self.deinit();
    var output: []const u8 = undefined;
    if (try m.match(.{ "log", "error", tp.string, tp.string, "->", tp.extract(&output) })) {
        if (self.subscriber) |subscriber| {
            subscriber.send_raw(m) catch {};
        } else {
            self.store(m);
        }
        if (!self.no_stderr) {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
            stderr_writer.interface.print("{s}\n", .{output}) catch {};
            stderr_writer.interface.flush() catch {};
        }
    } else if (try m.match(.{ "log", tp.string, tp.extract(&output) })) {
        if (self.subscriber) |subscriber| {
            subscriber.send_raw(m) catch {};
        } else {
            self.store(m);
        }
        if (!self.no_stdout) {
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
            stdout_writer.interface.print("{s}\n", .{output}) catch {};
            stdout_writer.interface.flush() catch {};
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
    } else if (try m.match(.{ "stdout", "enable" })) {
        self.no_stdout = false;
    } else if (try m.match(.{ "stdout", "disable" })) {
        self.no_stdout = true;
    } else if (try m.match(.{ "stderr", "enable" })) {
        self.no_stderr = false;
    } else if (try m.match(.{ "stderr", "disable" })) {
        self.no_stderr = true;
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

    pub fn print_err(self: Logger, context: []const u8, comptime fmt: anytype, args: anytype) void {
        var buf: [max_log_message]u8 = undefined;
        const output = std.fmt.bufPrint(&buf, fmt, args) catch "MESSAGE TOO LARGE";
        self.err_msg(context, output);
    }

    pub fn err(self: Logger, context: []const u8, e: anyerror) void {
        var msg_fmt: std.ArrayList(u8) = .empty;
        defer msg_fmt.deinit(std.heap.c_allocator);
        defer tp.reset_error();
        var buf: [max_log_message]u8 = undefined;
        var msg: []const u8 = "UNKNOWN";
        switch (e) {
            error.Exit => {
                const msg_: tp.message = .{ .buf = tp.error_message() };
                var msg__: []const u8 = undefined;
                var trace__: []const u8 = "";
                if (msg_.match(.{ "exit", tp.extract(&msg__) }) catch false) {
                    //
                } else if (msg_.match(.{ "exit", tp.extract(&msg__), tp.extract(&trace__) }) catch false) {
                    //
                } else {
                    var failed = false;
                    msg_fmt.writer(std.heap.c_allocator).print("{f}", .{msg_}) catch {
                        failed = true;
                    };
                    if (failed) {
                        msg_fmt.clearRetainingCapacity();
                        msg_fmt.writer(std.heap.c_allocator).print("{f}", .{std.ascii.hexEscape(msg_.buf, .lower)}) catch {};
                    }
                    msg__ = msg_fmt.items;
                    tp.trace(tp.channel.debug, .{ "log_err_fmt", msg__.len, msg__[0..@min(msg__.len, 128)] });
                }
                if (msg__.len > buf.len) {
                    self.proc.send(.{ "log", "error", self.tag, context, "->", "MESSAGE TOO LARGE" }) catch {};
                    return;
                }
                const msg___ = buf[0..msg__.len];
                @memcpy(msg___, msg__);
                if (trace__.len > 0 and buf.len - msg___.len > trace__.len + 1) {
                    const msg____ = buf[0 .. msg__.len + trace__.len + 1];
                    @memcpy(msg____[msg__.len .. msg__.len + 1], "\n");
                    @memcpy(msg____[msg__.len + 1 ..], trace__);
                    msg = msg____;
                } else {
                    msg = msg___;
                }
            },
            else => {
                msg = @errorName(e);
            },
        }
        self.err_msg(context, msg);
    }

    pub fn err_msg(self: Logger, context: []const u8, msg: []const u8) void {
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

pub fn stdout(state: enum { enable, disable }) void {
    tp.env.get().proc("log").send(.{ "stdout", state }) catch {};
}

pub fn stderr(state: enum { enable, disable }) void {
    tp.env.get().proc("log").send(.{ "stderr", state }) catch {};
}

var std_log_pid: ?tp.pid_ref = null;

pub fn set_std_log_pid(pid: ?tp.pid_ref) void {
    std_log_pid = pid;
}

pub fn std_log_function(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const log_pid = std_log_pid orelse return;
    const prefix = "[" ++ comptime level.asText() ++ "] ";
    var buf: [max_log_message]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, prefix ++ format, args) catch "MESSAGE TOO LARGE";
    if (level == .err) {
        log_pid.send(.{ "log", "error", @tagName(scope), "std.log", "->", output }) catch {};
    } else {
        log_pid.send(.{ "log", @tagName(scope), output }) catch {};
    }
}
