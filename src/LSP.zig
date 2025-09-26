const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("root");
const tracy = @import("tracy");

allocator: std.mem.Allocator,
pid: tp.pid,

const Self = @This();
const module_name = @typeName(Self);
const sp_tag = "child";
const debug_lsp = true;

const OutOfMemoryError = error{OutOfMemory};
const SendError = error{SendFailed};
const SpawnError = error{ThespianSpawnFailed};

pub fn open(
    allocator: std.mem.Allocator,
    project: []const u8,
    cmd: tp.message,
) (error{ ThespianSpawnFailed, InvalidLspCommand } || cbor.Error)!*const Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .pid = try Process.create(allocator, project, cmd),
    };
    return self;
}

pub fn deinit(self: *const Self) void {
    self.pid.send(.{"close"}) catch {};
    self.pid.deinit();
    self.allocator.destroy(self);
}

pub fn term(self: *const Self) void {
    self.pid.send(.{"term"}) catch {};
    self.pid.deinit();
    self.allocator.destroy(self);
}

pub fn send_request(
    self: *const Self,
    allocator: std.mem.Allocator,
    method: []const u8,
    m: anytype,
    ctx: anytype,
) (OutOfMemoryError || SpawnError || std.Io.Writer.Error)!void {
    var cb: std.Io.Writer.Allocating = .init(self.allocator);
    defer cb.deinit();
    try cbor.writeValue(&cb.writer, m);
    return RequestContext(@TypeOf(ctx)).send(allocator, self.pid.ref(), ctx, tp.message.fmt(.{ "REQ", method, cb.written() }));
}

pub fn send_notification(self: *const Self, method: []const u8, m: anytype) (OutOfMemoryError || SendError || std.Io.Writer.Error)!void {
    var cb: std.Io.Writer.Allocating = .init(self.allocator);
    defer cb.deinit();
    try cbor.writeValue(&cb.writer, m);
    return self.send_notification_raw(method, cb.written());
}

pub fn send_notification_raw(self: *const Self, method: []const u8, cb: []const u8) SendError!void {
    self.pid.send(.{ "NTFY", method, cb }) catch return error.SendFailed;
}

pub const ErrorCode = enum(i32) {

    // Defined by JSON-RPC
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,

    // Defined by LSP
    RequestFailed = -32803,
    ServerCancelled = -32802,
    ContentModified = -32801,
    RequestCancelled = -32800,
};

pub fn send_response(allocator: std.mem.Allocator, to: tp.pid_ref, cbor_id: []const u8, result: anytype) (SendError || OutOfMemoryError || std.Io.Writer.Error)!void {
    var cb: std.Io.Writer.Allocating = .init(allocator);
    defer cb.deinit();
    const writer = &cb.writer;
    try cbor.writeArrayHeader(writer, 3);
    try cbor.writeValue(writer, "RSP");
    try writer.writeAll(cbor_id);
    try cbor.writeValue(writer, result);
    to.send_raw(.{ .buf = cb.written() }) catch return error.SendFailed;
}

pub fn send_error_response(allocator: std.mem.Allocator, to: tp.pid_ref, cbor_id: []const u8, code: ErrorCode, message: []const u8) (SendError || OutOfMemoryError || std.Io.Writer.Error)!void {
    var cb: std.Io.Writer.Allocating = .init(allocator);
    defer cb.deinit();
    const writer = &cb.writer;
    try cbor.writeArrayHeader(writer, 4);
    try cbor.writeValue(writer, "ERR");
    try writer.writeAll(cbor_id);
    try cbor.writeValue(writer, code);
    try cbor.writeValue(writer, message);
    to.send_raw(.{ .buf = cb.written() }) catch return error.SendFailed;
}

pub fn close(self: *Self) void {
    self.deinit();
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
            self.ctx.deinit();
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

const Process = struct {
    allocator: std.mem.Allocator,
    cmd: tp.message,
    receiver: Receiver,
    sp: ?tp.subprocess = null,
    recv_buf: std.ArrayList(u8),
    parent: tp.pid,
    tag: [:0]const u8,
    project: [:0]const u8,
    sp_tag: [:0]const u8,
    log_file: ?std.fs.File = null,
    log_file_path: ?[]const u8 = null,
    log_file_writer: ?std.fs.File.Writer = null,
    log_file_writer_buf: [1024]u8 = undefined,
    next_id: i32 = 0,
    requests: std.StringHashMap(tp.pid),
    state: enum { init, running } = .init,
    init_queue: ?std.ArrayListUnmanaged(struct { tp.pid, []const u8, []const u8, InitQueueType }) = null,

    const InitQueueType = enum { request, notify };

    const Receiver = tp.Receiver(*Process);

    pub fn create(allocator: std.mem.Allocator, project: []const u8, cmd: tp.message) (error{ ThespianSpawnFailed, InvalidLspCommand } || OutOfMemoryError || cbor.Error || std.Io.Writer.Error)!tp.pid {
        var tag: []const u8 = undefined;
        if (try cbor.match(cmd.buf, .{tp.extract(&tag)})) {
            //
        } else if (try cbor.match(cmd.buf, .{ tp.extract(&tag), tp.more })) {
            //
        } else {
            var buf: [1024]u8 = undefined;
            send_msg(tp.self_pid().clone(), tag, .err, "invalid command: {d} {s}", .{ cmd.buf.len, cmd.to_json(&buf) catch "{command too large}" });
            return error.InvalidLspCommand;
        }
        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        var sp_tag_: std.Io.Writer.Allocating = .init(allocator);
        defer sp_tag_.deinit();
        try sp_tag_.writer.writeAll(tag);
        try sp_tag_.writer.writeAll("-" ++ sp_tag);
        self.* = .{
            .allocator = allocator,
            .cmd = try cmd.clone(allocator),
            .receiver = Receiver.init(receive, self),
            .recv_buf = .empty,
            .parent = tp.self_pid().clone(),
            .tag = try allocator.dupeZ(u8, tag),
            .project = try allocator.dupeZ(u8, project),
            .requests = std.StringHashMap(tp.pid).init(allocator),
            .sp_tag = try sp_tag_.toOwnedSliceSentinel(0),
        };
        return tp.spawn_link(self.allocator, self, Process.start, self.tag);
    }

    fn deinit(self: *Process) void {
        self.free_init_queue();
        var i = self.requests.iterator();
        while (i.next()) |req| {
            self.allocator.free(req.key_ptr.*);
            req.value_ptr.deinit();
        }
        self.allocator.free(self.sp_tag);
        self.recv_buf.deinit(self.allocator);
        self.allocator.free(self.cmd.buf);
        self.close() catch {};
        self.write_log("### terminated LSP process ###\n", .{});
        if (self.log_file) |file| {
            if (self.log_file_writer) |*writer| writer.interface.flush() catch {};
            file.close();
        }
        if (self.log_file_path) |file_path| self.allocator.free(file_path);
    }

    fn close(self: *Process) error{CloseFailed}!void {
        if (self.sp) |*sp| {
            defer self.sp = null;
            sp.close() catch return error.CloseFailed;
            self.write_log("### closed ###\n", .{});
        }
    }

    fn term(self: *Process) error{TerminateFailed}!void {
        if (self.sp) |*sp| {
            defer self.sp = null;
            sp.term() catch return error.TerminateFailed;
            self.write_log("### terminated ###\n", .{});
        }
    }

    fn msg(self: *const Process, comptime fmt: anytype, args: anytype) void {
        send_msg(self.parent, self.tag, .msg, fmt, args);
    }

    fn err_msg(self: *const Process, comptime fmt: anytype, args: anytype) void {
        send_msg(self.parent, self.tag, .err, fmt, args);
    }

    fn send_msg(proc: tp.pid, tag: []const u8, type_: enum { msg, err }, comptime fmt: anytype, args: anytype) void {
        var buf: [@import("log").max_log_message]u8 = undefined;
        const output = std.fmt.bufPrint(&buf, fmt, args) catch "MESSAGE TOO LARGE";
        proc.send(.{ "lsp", type_, tag, output }) catch {};
    }

    fn start(self: *Process) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ " start" });
        defer frame.deinit();
        _ = tp.set_trap(true);
        self.sp = tp.subprocess.init(self.allocator, self.cmd, self.sp_tag, .Pipe) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);

        var log_file_path: std.Io.Writer.Allocating = .init(self.allocator);
        defer log_file_path.deinit();
        const state_dir = root.get_state_dir() catch |e| return tp.exit_error(e, @errorReturnTrace());
        log_file_path.writer.print("{s}{c}lsp-{s}.log", .{ state_dir, std.fs.path.sep, self.tag }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.log_file = std.fs.createFileAbsolute(log_file_path.written(), .{ .truncate = true }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.log_file_path = log_file_path.toOwnedSlice() catch null;
        if (self.log_file) |log_file| self.log_file_writer = log_file.writer(&self.log_file_writer_buf);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            error.ExitUnexpected => error.Exit,
            else => tp.exit_error(e, @errorReturnTrace()),
        };
    }

    const Error = (cbor.Error || cbor.JsonDecodeError || OutOfMemoryError || SendError || error{
        FileNotFound,
        InvalidSyntax,
        InvalidMessageField,
        InvalidMessage,
        InvalidContentLength,
        Closed,
        CloseFailed,
        TerminateFailed,
        UnsupportedType,
        ExitNormal,
        ExitUnexpected,
        InvalidMapType,
    });

    fn receive_safe(self: *Process, from: tp.pid_ref, m: tp.message) Error!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name });
        defer frame.deinit();
        errdefer self.deinit();
        var method: []const u8 = "";
        var bytes: []const u8 = "";
        var err: []const u8 = "";
        var code: u32 = 0;
        var cbor_id: []const u8 = "";
        var error_code: ErrorCode = undefined;
        var message: []const u8 = "";

        if (try cbor.match(m.buf, .{ "REQ", "initialize", tp.extract(&bytes) })) {
            try self.send_request(from, "initialize", bytes);
        } else if (try cbor.match(m.buf, .{ "REQ", tp.extract(&method), tp.extract(&bytes) })) {
            switch (self.state) {
                .init => try self.append_init_queue(from, method, bytes, .request), //queue requests
                .running => try self.send_request(from, method, bytes),
            }
        } else if (try cbor.match(m.buf, .{ "RSP", tp.extract_cbor(&cbor_id), tp.extract_cbor(&bytes) })) {
            try self.send_response(cbor_id, bytes);
        } else if (try cbor.match(m.buf, .{ "ERR", tp.extract_cbor(&cbor_id), tp.extract(&error_code), tp.extract(&message) })) {
            try self.send_error_response(cbor_id, error_code, message);
        } else if (try cbor.match(m.buf, .{ "NTFY", "initialized", tp.extract(&bytes) })) {
            self.state = .running;
            try self.send_notification("initialized", bytes);
            try self.replay_init_queue();
        } else if (try cbor.match(m.buf, .{ "NTFY", tp.extract(&method), tp.extract(&bytes) })) {
            switch (self.state) {
                .init => try self.append_init_queue(from, method, bytes, .notify), //queue requests
                .running => try self.send_notification(method, bytes),
            }
        } else if (try cbor.match(m.buf, .{"close"})) {
            self.write_log("### LSP close ###\n", .{});
            try self.close();
        } else if (try cbor.match(m.buf, .{"term"})) {
            self.write_log("### LSP terminated ###\n", .{});
            try self.term();
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "stdout", tp.extract(&bytes) })) {
            try self.handle_output(bytes);
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "term", "error.FileNotFound", 1 })) {
            try self.handle_not_found();
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "term", tp.extract(&err), tp.extract(&code) })) {
            try self.handle_terminated(err, code);
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "stderr", tp.extract(&bytes) })) {
            self.write_log("{s}\n", .{bytes});
        } else if (try cbor.match(m.buf, .{ "exit", "normal" })) {
            // self.write_log("### exit normal ###\n", .{});
        } else {
            tp.unexpected(m) catch {};
            self.write_log("{s}\n", .{tp.error_text()});
            return error.ExitUnexpected;
        }
    }

    fn append_init_queue(self: *Process, from: tp.pid_ref, method: []const u8, bytes: []const u8, type_: InitQueueType) !void {
        const queue = if (self.init_queue) |*queue| queue else blk: {
            self.init_queue = .empty;
            break :blk &self.init_queue.?;
        };
        const p = try queue.addOne(self.allocator);
        p.* = .{
            from.clone(),
            try self.allocator.dupe(u8, method),
            try self.allocator.dupe(u8, bytes),
            type_,
        };
    }

    fn replay_init_queue(self: *Process) !void {
        defer self.free_init_queue();
        if (self.init_queue) |*queue| {
            for (queue.items) |*p|
                switch (p[3]) {
                    .request => try self.send_request(p[0].ref(), p[1], p[2]),
                    .notify => try self.send_notification(p[1], p[2]),
                };
        }
    }

    fn free_init_queue(self: *Process) void {
        if (self.init_queue) |*queue| {
            for (queue.items) |*p| {
                p[0].deinit();
                self.allocator.free(p[1]);
                self.allocator.free(p[2]);
            }
            queue.deinit(self.allocator);
        }
        self.init_queue = null;
    }

    fn receive_lsp_message(self: *Process, cb: []const u8) Error!void {
        var iter = cb;

        const MsgMembers = struct {
            cbor_id: ?[]const u8 = null,
            method: ?[]const u8 = null,
            params: ?[]const u8 = null,
            result: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
        };
        var values: MsgMembers = .{};

        var len = try cbor.decodeMapHeader(&iter);
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
            if (std.mem.eql(u8, field_name, "id")) {
                var value: []const u8 = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return error.InvalidMessageField;
                values.cbor_id = value;
            } else if (std.mem.eql(u8, field_name, "method")) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&values.method)))) return error.InvalidMessageField;
            } else if (std.mem.eql(u8, field_name, "params")) {
                var value: []const u8 = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return error.InvalidMessageField;
                values.params = value;
            } else if (std.mem.eql(u8, field_name, "result")) {
                var value: []const u8 = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return error.InvalidMessageField;
                values.result = value;
            } else if (std.mem.eql(u8, field_name, "error")) {
                var value: []const u8 = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return error.InvalidMessageField;
                values.@"error" = value;
            } else {
                try cbor.skipValue(&iter);
            }
        }

        if (values.cbor_id) |cbor_id| {
            return if (values.method) |method| // Request messages have a method
                self.receive_lsp_request(cbor_id, method, values.params)
            else // Everything else is a Response message
                self.receive_lsp_response(cbor_id, values.result, values.@"error");
        } else { // Notification message has no ID
            return if (values.method) |method|
                self.receive_lsp_notification(method, values.params)
            else
                error.InvalidMessage;
        }
    }

    fn handle_output(self: *Process, bytes: []const u8) Error!void {
        try self.recv_buf.appendSlice(self.allocator, bytes);
        self.write_log("### RECV:\n{s}\n###\n", .{bytes});
        self.frame_message_recv() catch |e| {
            self.write_log("### RECV error: {any}\n", .{e});
            switch (e) {
                // ignore invalid LSP messages that are at least framed correctly
                error.InvalidMessage, error.InvalidMessageField => {},
                else => return e,
            }
        };
    }

    fn handle_not_found(self: *Process) error{ExitNormal}!void {
        self.err_msg("'{s}' executable not found", .{self.tag});
        self.write_log("### '{s}' executable not found ###\n", .{self.tag});
        self.parent.send(.{ sp_tag, self.tag, "not found" }) catch {};
        return error.ExitNormal;
    }

    fn handle_terminated(self: *Process, err: []const u8, code: u32) error{ExitNormal}!void {
        self.msg("terminated: {s} {d}", .{ err, code });
        self.write_log("### subprocess terminated {s} {d} ###\n", .{ err, code });
        self.parent.send(.{ sp_tag, self.tag, "done" }) catch {};
        return error.ExitNormal;
    }

    fn send_request(self: *Process, from: tp.pid_ref, method: []const u8, params_cb: []const u8) Error!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        const id = self.next_id;
        self.next_id += 1;

        var request: std.Io.Writer.Allocating = .init(self.allocator);
        defer request.deinit();
        const msg_writer = &request.writer;
        try cbor.writeMapHeader(msg_writer, 4);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "id");
        try cbor.writeValue(msg_writer, id);
        try cbor.writeValue(msg_writer, "method");
        try cbor.writeValue(msg_writer, method);
        try cbor.writeValue(msg_writer, "params");
        _ = try msg_writer.write(params_cb);

        const json = try cbor.toJsonAlloc(self.allocator, request.written());
        defer self.allocator.free(json);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.written()) catch return error.SendFailed;
        self.write_log("### SEND request:\n{s}\n###\n", .{output.written()});

        var cbor_id: std.Io.Writer.Allocating = .init(self.allocator);
        defer cbor_id.deinit();
        try cbor.writeValue(&cbor_id.writer, id);
        try self.requests.put(try cbor_id.toOwnedSlice(), from.clone());
    }

    fn send_response(self: *Process, cbor_id: []const u8, result_cb: []const u8) (error{Closed} || SendError || cbor.Error || cbor.JsonEncodeError)!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        var response: std.Io.Writer.Allocating = .init(self.allocator);
        defer response.deinit();
        const msg_writer = &response.writer;
        try cbor.writeMapHeader(msg_writer, 3);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "id");
        try msg_writer.writeAll(cbor_id);
        try cbor.writeValue(msg_writer, "result");
        _ = try msg_writer.write(result_cb);

        const json = try cbor.toJsonAlloc(self.allocator, response.written());
        defer self.allocator.free(json);

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.written()) catch return error.SendFailed;
        self.write_log("### SEND response:\n{s}\n###\n", .{output.written()});
    }

    fn send_error_response(self: *Process, cbor_id: []const u8, error_code: ErrorCode, message: []const u8) (error{Closed} || SendError || cbor.Error || cbor.JsonEncodeError)!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        var response: std.Io.Writer.Allocating = .init(self.allocator);
        defer response.deinit();
        const msg_writer = &response.writer;
        try cbor.writeMapHeader(msg_writer, 3);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "id");
        try msg_writer.writeAll(cbor_id);
        try cbor.writeValue(msg_writer, "error");
        try cbor.writeMapHeader(msg_writer, 2);
        try cbor.writeValue(msg_writer, "code");
        try cbor.writeValue(msg_writer, @intFromEnum(error_code));
        try cbor.writeValue(msg_writer, "message");
        try cbor.writeValue(msg_writer, message);

        const json = try cbor.toJsonAlloc(self.allocator, response.written());
        defer self.allocator.free(json);

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.written()) catch return error.SendFailed;
        self.write_log("### SEND error response:\n{s}\n###\n", .{output.written()});
    }

    fn send_notification(self: *Process, method: []const u8, params_cb: []const u8) Error!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        const have_params = !(cbor.match(params_cb, cbor.null_) catch false);

        var notification: std.Io.Writer.Allocating = .init(self.allocator);
        defer notification.deinit();
        const msg_writer = &notification.writer;
        try cbor.writeMapHeader(msg_writer, 3);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "method");
        try cbor.writeValue(msg_writer, method);
        try cbor.writeValue(msg_writer, "params");
        if (have_params) {
            _ = try msg_writer.write(params_cb);
        } else {
            try cbor.writeMapHeader(msg_writer, 0);
        }

        const json = try cbor.toJsonAlloc(self.allocator, notification.written());
        defer self.allocator.free(json);

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.written()) catch return error.SendFailed;
        self.write_log("### SEND notification:\n{s}\n###\n", .{output.written()});
    }

    fn frame_message_recv(self: *Process) Error!void {
        const sep = "\r\n\r\n";
        const headers_end = std.mem.indexOf(u8, self.recv_buf.items, sep) orelse return;
        const headers_data = self.recv_buf.items[0..headers_end];
        const headers = try Headers.parse(headers_data);
        if (self.recv_buf.items.len - (headers_end + sep.len) < headers.content_length) return;
        const buf = try self.recv_buf.toOwnedSlice(self.allocator);
        const data = buf[headers_end + sep.len .. headers_end + sep.len + headers.content_length];
        const rest = buf[headers_end + sep.len + headers.content_length ..];
        defer self.allocator.free(buf);
        if (rest.len > 0) try self.recv_buf.appendSlice(self.allocator, rest);
        const message = .{ .body = data[0..headers.content_length] };
        const cb = try cbor.fromJsonAlloc(self.allocator, message.body);
        defer self.allocator.free(cb);
        try self.receive_lsp_message(cb);
        if (rest.len > 0) return self.frame_message_recv();
    }

    fn receive_lsp_request(self: *Process, cbor_id: []const u8, method: []const u8, params: ?[]const u8) Error!void {
        const json_id = try cbor.toJsonPrettyAlloc(self.allocator, cbor_id);
        defer self.allocator.free(json_id);
        const json = if (params) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json) |p| self.allocator.free(p);
        self.write_log("### RECV req: {s}\nmethod: {s}\n{s}\n###\n", .{ json_id, method, json orelse "no params" });
        var request: std.Io.Writer.Allocating = .init(self.allocator);
        defer request.deinit();
        const writer = &request.writer;
        try cbor.writeArrayHeader(writer, 7);
        try cbor.writeValue(writer, sp_tag);
        try cbor.writeValue(writer, self.project);
        try cbor.writeValue(writer, self.tag);
        try cbor.writeValue(writer, "request");
        try cbor.writeValue(writer, method);
        try writer.writeAll(cbor_id);
        if (params) |p| _ = try writer.write(p) else try cbor.writeValue(writer, null);
        self.parent.send_raw(.{ .buf = request.written() }) catch return error.SendFailed;
    }

    fn receive_lsp_response(self: *Process, cbor_id: []const u8, result: ?[]const u8, err: ?[]const u8) Error!void {
        const json_id = try cbor.toJsonPrettyAlloc(self.allocator, cbor_id);
        defer self.allocator.free(json_id);
        const json = if (result) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json) |p| self.allocator.free(p);
        const json_err = if (err) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json_err) |p| self.allocator.free(p);
        self.write_log("### RECV rsp: {s} {s}\n{s}\n###\n", .{ json_id, if (json_err) |_| "error" else "response", json_err orelse json orelse "no result" });
        const from = self.requests.get(cbor_id) orelse return;
        var response: std.Io.Writer.Allocating = .init(self.allocator);
        defer response.deinit();
        const writer = &response.writer;
        try cbor.writeArrayHeader(writer, 4);
        try cbor.writeValue(writer, sp_tag);
        try cbor.writeValue(writer, self.tag);
        if (err) |err_| {
            try cbor.writeValue(writer, "error");
            _ = try writer.write(err_);
        } else if (result) |result_| {
            try cbor.writeValue(writer, "result");
            _ = try writer.write(result_);
        }
        from.send_raw(.{ .buf = response.written() }) catch return error.SendFailed;
    }

    fn receive_lsp_notification(self: *Process, method: []const u8, params: ?[]const u8) Error!void {
        const json = if (params) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json) |p| self.allocator.free(p);
        self.write_log("### RECV notify:\nmethod: {s}\n{s}\n###\n", .{ method, json orelse "no params" });
        var notification: std.Io.Writer.Allocating = .init(self.allocator);
        defer notification.deinit();
        const writer = &notification.writer;
        try cbor.writeArrayHeader(writer, 6);
        try cbor.writeValue(writer, sp_tag);
        try cbor.writeValue(writer, self.project);
        try cbor.writeValue(writer, self.tag);
        try cbor.writeValue(writer, "notify");
        try cbor.writeValue(writer, method);
        if (params) |p| _ = try writer.write(p) else try cbor.writeValue(writer, null);
        self.parent.send_raw(.{ .buf = notification.written() }) catch return error.SendFailed;
    }

    fn write_log(self: *Process, comptime format: []const u8, args: anytype) void {
        if (!debug_lsp) return;
        const file_writer = if (self.log_file_writer) |*writer| writer else return;
        file_writer.interface.print(format, args) catch {};
        file_writer.interface.flush() catch {};
    }
};

const Headers = struct {
    content_length: usize = 0,
    content_type: ?[]const u8 = null,

    fn parse(buf_: []const u8) Process.Error!Headers {
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

    fn parse_one(self: *Headers, name: []const u8, value: []const u8) Process.Error!void {
        if (std.mem.eql(u8, "Content-Length", name)) {
            self.content_length = std.fmt.parseInt(@TypeOf(self.content_length), value, 10) catch |e| switch (e) {
                error.Overflow => return error.InvalidContentLength,
                error.InvalidCharacter => return error.InvalidContentLength,
            };
        } else if (std.mem.eql(u8, "Content-Type", name)) {
            self.content_type = value;
        }
    }
};

pub const CompletionItemKind = enum(u8) {
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25,
};
