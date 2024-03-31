const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");

pid: ?tp.pid,

const Self = @This();
const module_name = @typeName(Self);
const sp_tag = "LSP";
pub const Error = error{ OutOfMemory, Exit };

pub fn open(a: std.mem.Allocator, cmd: tp.message, tag: [:0]const u8) Error!Self {
    return .{ .pid = try Process.create(a, cmd, tag) };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.send(.{"close"}) catch {};
        self.pid = null;
        pid.deinit();
    }
}

pub fn send(self: *Self, message: []const u8) tp.result {
    const pid = if (self.pid) |pid| pid else return tp.exit_error(error.Closed);
    try pid.send(.{ "M", message });
}

pub fn close(self: *Self) void {
    self.deinit();
}

const Process = struct {
    a: std.mem.Allocator,
    cmd: tp.message,
    receiver: Receiver,
    sp: ?tp.subprocess = null,
    recv_buf: std.ArrayList(u8),
    parent: tp.pid,
    tag: [:0]const u8,
    logger: log.Logger,

    const Receiver = tp.Receiver(*Process);

    pub fn create(a: std.mem.Allocator, cmd: tp.message, tag: [:0]const u8) Error!tp.pid {
        const self = try a.create(Process);
        self.* = .{
            .a = a,
            .cmd = try cmd.clone(a),
            .receiver = Receiver.init(receive, self),
            .recv_buf = std.ArrayList(u8).init(a),
            .parent = tp.self_pid().clone(),
            .tag = try a.dupeZ(u8, tag),
            .logger = log.logger(module_name),
        };
        return tp.spawn_link(self.a, self, Process.start, tag) catch |e| tp.exit_error(e);
    }

    fn deinit(self: *Process) void {
        self.recv_buf.deinit();
        self.a.free(self.cmd.buf);
        self.close() catch {};
    }

    fn close(self: *Process) tp.result {
        if (self.sp) |*sp| {
            defer self.sp = null;
            try sp.close();
        }
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        self.sp = tp.subprocess.init(self.a, self.cmd, sp_tag, .Pipe) catch |e| return tp.exit_error(e);
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var bytes: []u8 = "";

        if (try m.match(.{ "S", tp.extract(&bytes) })) {
            const sp = if (self.sp) |sp| sp else return tp.exit_error(error.Closed);
            try sp.send(bytes);
        } else if (try m.match(.{"close"})) {
            try self.close();
        } else if (try m.match(.{ sp_tag, "stdout", tp.extract(&bytes) })) {
            self.handle_output(bytes) catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ sp_tag, "term", tp.more })) {
            self.handle_terminated() catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ sp_tag, "stderr", tp.extract(&bytes) })) {
            self.logger.print("ERR: {s}", .{bytes});
        } else if (try m.match(.{ "exit", "normal" })) {
            return tp.exit_normal();
        } else {
            self.logger.err("receive", tp.unexpected(m));
            return tp.unexpected(m);
        }
    }

    fn handle_output(self: *Process, bytes: []u8) !void {
        try self.recv_buf.appendSlice(bytes);
        self.logger.print("{s}", .{bytes});
        const message = try self.frame_message() orelse return;
        _ = message;
    }

    fn handle_terminated(self: *Process) !void {
        self.logger.print("done", .{});
        try self.parent.send(.{ self.tag, "done" });
    }

    fn frame_message(self: *Process) !?Message {
        const end = std.mem.indexOf(u8, self.recv_buf.items, "\r\n\r\n") orelse return null;
        const headers = try Headers.parse(self.recv_buf.items[0..end]);
        const body = self.recv_buf.items[end + 2 ..];
        if (body.len < headers.content_length) return null;
        return .{ .body = body };
    }
};

const Message = struct {
    body: []const u8,
};

const Headers = struct {
    content_length: usize = 0,
    content_type: ?[]const u8 = null,

    fn parse(buf_: []const u8) !Headers {
        var buf = buf_;
        var ret: Headers = .{};
        while (true) {
            const sep = std.mem.indexOf(u8, buf, ":") orelse return error.InvalidSyntax;
            const name = buf[0..sep];
            const end = std.mem.indexOf(u8, buf, "\r\n") orelse buf.len;
            const vstart = if (buf.len > sep + 1)
                if (buf[sep + 1] == ' ')
                    sep + 2
                else
                    sep + 1
            else
                sep + 1;
            const value = buf[vstart..end];
            try ret.parse_one(name, value);
            buf = if (end < buf.len - 2) buf[end + 2 ..] else return ret;
        }
    }

    fn parse_one(self: *Headers, name: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, "Content-Length", name)) {
            self.content_length = try std.fmt.parseInt(@TypeOf(self.content_length), value, 10);
        } else if (std.mem.eql(u8, "Content-Type", name)) {
            self.content_type = value;
        }
    }
};
