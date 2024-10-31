const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("root");
const tracy = @import("tracy");
const log = @import("log");

allocator: std.mem.Allocator,
pid: tp.pid,

const Self = @This();
const module_name = @typeName(Self);
const sp_tag = "child";
const debug_lsp = true;

const OutOfMemoryError = error{OutOfMemory};
const SendError = error{SendFailed};
const CallError = tp.CallError;

pub fn open(allocator: std.mem.Allocator, project: []const u8, cmd: tp.message) (error{ ThespianSpawnFailed, InvalidArgument } || cbor.Error)!Self {
    return .{ .allocator = allocator, .pid = try Process.create(allocator, project, cmd) };
}

pub fn deinit(self: Self) void {
    self.pid.send(.{"close"}) catch {};
    self.pid.deinit();
}

pub fn term(self: Self) void {
    self.pid.send(.{"term"}) catch {};
    self.pid.deinit();
}

pub fn send_request(self: Self, allocator: std.mem.Allocator, method: []const u8, m: anytype) CallError!tp.message {
    var cb = std.ArrayList(u8).init(self.allocator);
    defer cb.deinit();
    try cbor.writeValue(cb.writer(), m);
    const request_timeout: u64 = @intCast(std.time.ns_per_s * tp.env.get().num("lsp-request-timeout"));
    return self.pid.call(allocator, request_timeout, .{ "REQ", method, cb.items });
}

pub fn send_response(self: Self, id: i32, m: anytype) SendError!tp.message {
    var cb = std.ArrayList(u8).init(self.allocator);
    defer cb.deinit();
    try cbor.writeValue(cb.writer(), m);
    return self.pid.send(.{ "RSP", id, cb.items });
}

pub fn send_notification(self: Self, method: []const u8, m: anytype) (OutOfMemoryError || SendError)!void {
    var cb = std.ArrayList(u8).init(self.allocator);
    defer cb.deinit();
    try cbor.writeValue(cb.writer(), m);
    return self.send_notification_raw(method, cb.items);
}

pub fn send_notification_raw(self: Self, method: []const u8, cb: []const u8) SendError!void {
    self.pid.send(.{ "NTFY", method, cb }) catch return error.SendFailed;
}

pub fn close(self: *Self) void {
    self.deinit();
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
    next_id: i32 = 0,
    requests: std.AutoHashMap(i32, tp.pid),

    const Receiver = tp.Receiver(*Process);

    pub fn create(allocator: std.mem.Allocator, project: []const u8, cmd: tp.message) (error{ ThespianSpawnFailed, InvalidArgument } || OutOfMemoryError || cbor.Error)!tp.pid {
        var tag: []const u8 = undefined;
        if (try cbor.match(cmd.buf, .{tp.extract(&tag)})) {
            //
        } else if (try cbor.match(cmd.buf, .{ tp.extract(&tag), tp.more })) {
            //
        } else {
            return error.InvalidArgument;
        }
        const self = try allocator.create(Process);
        var sp_tag_ = std.ArrayList(u8).init(allocator);
        defer sp_tag_.deinit();
        try sp_tag_.appendSlice(tag);
        try sp_tag_.appendSlice("-" ++ sp_tag);
        self.* = .{
            .allocator = allocator,
            .cmd = try cmd.clone(allocator),
            .receiver = Receiver.init(receive, self),
            .recv_buf = std.ArrayList(u8).init(allocator),
            .parent = tp.self_pid().clone(),
            .tag = try allocator.dupeZ(u8, tag),
            .project = try allocator.dupeZ(u8, project),
            .requests = std.AutoHashMap(i32, tp.pid).init(allocator),
            .sp_tag = try sp_tag_.toOwnedSliceSentinel(0),
        };
        return tp.spawn_link(self.allocator, self, Process.start, self.tag);
    }

    fn deinit(self: *Process) void {
        var i = self.requests.iterator();
        while (i.next()) |req| req.value_ptr.deinit();
        self.allocator.free(self.sp_tag);
        self.recv_buf.deinit();
        self.allocator.free(self.cmd.buf);
        self.close() catch {};
        self.write_log("### terminated LSP process ###\n", .{});
        if (self.log_file) |file| file.close();
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

    fn start(self: *Process) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ " start" });
        defer frame.deinit();
        _ = tp.set_trap(true);
        self.sp = tp.subprocess.init(self.allocator, self.cmd, self.sp_tag, .Pipe) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);

        var log_file_path = std.ArrayList(u8).init(self.allocator);
        defer log_file_path.deinit();
        const state_dir = root.get_state_dir() catch |e| return tp.exit_error(e, @errorReturnTrace());
        log_file_path.writer().print("{s}/lsp-{s}.log", .{ state_dir, self.tag }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.log_file = std.fs.createFileAbsolute(log_file_path.items, .{ .truncate = true }) catch |e| return tp.exit_error(e, @errorReturnTrace());
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
    });

    fn receive_safe(self: *Process, from: tp.pid_ref, m: tp.message) Error!void {
        const frame = tracy.initZone(@src(), .{ .name = module_name });
        defer frame.deinit();
        errdefer self.deinit();
        var method: []u8 = "";
        var bytes: []u8 = "";
        var err: []u8 = "";
        var code: u32 = 0;
        var id: i32 = 0;

        if (try cbor.match(m.buf, .{ "REQ", tp.extract(&method), tp.extract(&bytes) })) {
            try self.send_request(from, method, bytes);
        } else if (try cbor.match(m.buf, .{ "RSP", tp.extract(&id), tp.extract(&bytes) })) {
            try self.send_response(id, bytes);
        } else if (try cbor.match(m.buf, .{ "NTFY", tp.extract(&method), tp.extract(&bytes) })) {
            try self.send_notification(method, bytes);
        } else if (try cbor.match(m.buf, .{"close"})) {
            self.write_log("### LSP close ###\n", .{});
            try self.close();
        } else if (try cbor.match(m.buf, .{"term"})) {
            self.write_log("### LSP terminated ###\n", .{});
            try self.term();
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "stdout", tp.extract(&bytes) })) {
            try self.handle_output(bytes);
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "term", tp.extract(&err), tp.extract(&code) })) {
            try self.handle_terminated(err, code);
        } else if (try cbor.match(m.buf, .{ self.sp_tag, "stderr", tp.extract(&bytes) })) {
            self.write_log("{s}\n", .{bytes});
        } else if (try cbor.match(m.buf, .{ "exit", "normal" })) {
            // self.write_log("### exit normal ###\n", .{});
        } else if (try cbor.match(m.buf, .{ "exit", "error.FileNotFound" })) {
            self.write_log("### LSP not found ###\n", .{});
            const logger = log.logger("LSP");
            var buf: [1024]u8 = undefined;
            logger.print_err("init", "executable not found: {s}", .{self.cmd.to_json(&buf) catch "{command too large}"});
            return error.FileNotFound;
        } else {
            tp.unexpected(m) catch {};
            self.write_log("{s}\n", .{tp.error_text()});
            return error.ExitUnexpected;
        }
    }

    fn receive_lsp_message(self: *Process, cb: []const u8) Error!void {
        var iter = cb;

        const MsgMembers = struct {
            id: ?i32 = null,
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
                if (!(try cbor.matchValue(&iter, cbor.extract(&values.id)))) return error.InvalidMessageField;
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

        if (values.id) |id| {
            return if (values.method) |method| // Request messages have a method
                self.receive_lsp_request(id, method, values.params)
            else // Everything else is a Response message
                self.receive_lsp_response(id, values.result, values.@"error");
        } else { // Notification message has no ID
            return if (values.method) |method|
                self.receive_lsp_notification(method, values.params)
            else
                error.InvalidMessage;
        }
    }

    fn handle_output(self: *Process, bytes: []u8) Error!void {
        try self.recv_buf.appendSlice(bytes);
        self.write_log("### RECV:\n{s}\n###\n", .{bytes});
        self.frame_message_recv() catch |e| {
            self.write_log("### RECV error: {any}\n", .{e});
            return e;
        };
    }

    fn handle_terminated(self: *Process, err: []const u8, code: u32) error{ExitNormal}!void {
        const logger = log.logger("LSP");
        logger.print("terminated: {s} {d}", .{ err, code });
        self.write_log("### subprocess terminated {s} {d} ###\n", .{ err, code });
        self.parent.send(.{ sp_tag, self.tag, "done" }) catch {};
        return error.ExitNormal;
    }

    fn send_request(self: *Process, from: tp.pid_ref, method: []const u8, params_cb: []const u8) Error!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        const id = self.next_id;
        self.next_id += 1;

        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        const msg_writer = msg.writer();
        try cbor.writeMapHeader(msg_writer, 4);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "id");
        try cbor.writeValue(msg_writer, id);
        try cbor.writeValue(msg_writer, "method");
        try cbor.writeValue(msg_writer, method);
        try cbor.writeValue(msg_writer, "params");
        _ = try msg_writer.write(params_cb);

        const json = try cbor.toJsonAlloc(self.allocator, msg.items);
        defer self.allocator.free(json);
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();
        const writer = output.writer();
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.items) catch return error.SendFailed;
        self.write_log("### SEND request:\n{s}\n###\n", .{output.items});
        try self.requests.put(id, from.clone());
    }

    fn send_response(self: *Process, id: i32, result_cb: []const u8) (error{Closed} || SendError || cbor.Error || cbor.JsonEncodeError)!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        const msg_writer = msg.writer();
        try cbor.writeMapHeader(msg_writer, 3);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "id");
        try cbor.writeValue(msg_writer, id);
        try cbor.writeValue(msg_writer, "result");
        _ = try msg_writer.write(result_cb);

        const json = try cbor.toJsonAlloc(self.allocator, msg.items);
        defer self.allocator.free(json);
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();
        const writer = output.writer();
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.items) catch return error.SendFailed;
        self.write_log("### SEND response:\n{s}\n###\n", .{output.items});
    }

    fn send_notification(self: *Process, method: []const u8, params_cb: []const u8) Error!void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        const have_params = !(cbor.match(params_cb, cbor.null_) catch false);

        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        const msg_writer = msg.writer();
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

        const json = try cbor.toJsonAlloc(self.allocator, msg.items);
        defer self.allocator.free(json);
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();
        const writer = output.writer();
        const terminator = "\r\n";
        const content_length = json.len + terminator.len;
        try writer.print("Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{content_length});
        _ = try writer.write(json);
        _ = try writer.write(terminator);

        sp.send(output.items) catch return error.SendFailed;
        self.write_log("### SEND notification:\n{s}\n###\n", .{output.items});
    }

    fn frame_message_recv(self: *Process) Error!void {
        const sep = "\r\n\r\n";
        const headers_end = std.mem.indexOf(u8, self.recv_buf.items, sep) orelse return;
        const headers_data = self.recv_buf.items[0..headers_end];
        const headers = try Headers.parse(headers_data);
        if (self.recv_buf.items.len - (headers_end + sep.len) < headers.content_length) return;
        const buf = try self.recv_buf.toOwnedSlice();
        const data = buf[headers_end + sep.len .. headers_end + sep.len + headers.content_length];
        const rest = buf[headers_end + sep.len + headers.content_length ..];
        defer self.allocator.free(buf);
        if (rest.len > 0) try self.recv_buf.appendSlice(rest);
        const message = .{ .body = data[0..headers.content_length] };
        const cb = try cbor.fromJsonAlloc(self.allocator, message.body);
        defer self.allocator.free(cb);
        try self.receive_lsp_message(cb);
        if (rest.len > 0) return self.frame_message_recv();
    }

    fn receive_lsp_request(self: *Process, id: i32, method: []const u8, params: ?[]const u8) Error!void {
        const json = if (params) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json) |p| self.allocator.free(p);
        self.write_log("### RECV req: {d}\nmethod: {s}\n{s}\n###\n", .{ id, method, json orelse "no params" });
        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        const writer = msg.writer();
        try cbor.writeArrayHeader(writer, 7);
        try cbor.writeValue(writer, sp_tag);
        try cbor.writeValue(writer, self.project);
        try cbor.writeValue(writer, self.tag);
        try cbor.writeValue(writer, "request");
        try cbor.writeValue(writer, method);
        try cbor.writeValue(writer, id);
        if (params) |p| _ = try writer.write(p) else try cbor.writeValue(writer, null);
        self.parent.send_raw(.{ .buf = msg.items }) catch return error.SendFailed;
    }

    fn receive_lsp_response(self: *Process, id: i32, result: ?[]const u8, err: ?[]const u8) Error!void {
        const json = if (result) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json) |p| self.allocator.free(p);
        const json_err = if (err) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json_err) |p| self.allocator.free(p);
        self.write_log("### RECV rsp: {d} {s}\n{s}\n###\n", .{ id, if (json_err) |_| "error" else "response", json_err orelse json orelse "no result" });
        const from = self.requests.get(id) orelse return;
        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        const writer = msg.writer();
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
        from.send_raw(.{ .buf = msg.items }) catch return error.SendFailed;
    }

    fn receive_lsp_notification(self: *Process, method: []const u8, params: ?[]const u8) Error!void {
        const json = if (params) |p| try cbor.toJsonPrettyAlloc(self.allocator, p) else null;
        defer if (json) |p| self.allocator.free(p);
        self.write_log("### RECV notify:\nmethod: {s}\n{s}\n###\n", .{ method, json orelse "no params" });
        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        const writer = msg.writer();
        try cbor.writeArrayHeader(writer, 6);
        try cbor.writeValue(writer, sp_tag);
        try cbor.writeValue(writer, self.project);
        try cbor.writeValue(writer, self.tag);
        try cbor.writeValue(writer, "notify");
        try cbor.writeValue(writer, method);
        if (params) |p| _ = try writer.write(p) else try cbor.writeValue(writer, null);
        self.parent.send_raw(.{ .buf = msg.items }) catch return error.SendFailed;
    }

    fn write_log(self: *Process, comptime format: []const u8, args: anytype) void {
        if (!debug_lsp) return;
        const file = self.log_file orelse return;
        file.writer().print(format, args) catch {};
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
