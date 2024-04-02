const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("root");
const tracy = @import("tracy");

a: std.mem.Allocator,
pid: ?tp.pid,

const Self = @This();
const module_name = @typeName(Self);
const sp_tag = "LSP";
const debug_lsp = true;
pub const Error = error{ OutOfMemory, Exit };

pub fn open(a: std.mem.Allocator, cmd: tp.message, tag: [:0]const u8) Error!Self {
    return .{ .a = a, .pid = try Process.create(a, cmd, tag) };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.send(.{"close"}) catch {};
        self.pid = null;
        pid.deinit();
    }
}

pub fn send_request(self: Self, a: std.mem.Allocator, method: []const u8, m: anytype) error{Exit}!tp.message {
    // const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".send_request" });
    // defer frame.deinit();
    const pid = if (self.pid) |pid| pid else return tp.exit_error(error.Closed);
    var cb = std.ArrayList(u8).init(self.a);
    defer cb.deinit();
    cbor.writeValue(cb.writer(), m) catch |e| return tp.exit_error(e);
    return pid.call(a, .{ "REQ", method, cb.items }) catch |e| return tp.exit_error(e);
}

pub fn send_notification(self: Self, method: []const u8, m: anytype) tp.result {
    const pid = if (self.pid) |pid| pid else return tp.exit_error(error.Closed);
    var cb = std.ArrayList(u8).init(self.a);
    defer cb.deinit();
    cbor.writeValue(cb.writer(), m) catch |e| return tp.exit_error(e);
    return pid.send(.{ "NTFY", method, cb.items });
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
    log_file: ?std.fs.File = null,
    next_id: i32 = 0,
    requests: std.AutoHashMap(i32, tp.pid),

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
            .requests = std.AutoHashMap(i32, tp.pid).init(a),
        };
        return tp.spawn_link(self.a, self, Process.start, tag) catch |e| tp.exit_error(e);
    }

    fn deinit(self: *Process) void {
        var i = self.requests.iterator();
        while (i.next()) |req| req.value_ptr.deinit();
        self.recv_buf.deinit();
        self.a.free(self.cmd.buf);
        if (self.log_file) |file| file.close();
        self.close() catch {};
    }

    fn close(self: *Process) tp.result {
        if (self.sp) |*sp| {
            defer self.sp = null;
            try sp.close();
        }
    }

    fn start(self: *Process) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ " start" });
        defer frame.deinit();
        _ = tp.set_trap(true);
        self.sp = tp.subprocess.init(self.a, self.cmd, sp_tag, .Pipe) catch |e| return tp.exit_error(e);
        tp.receive(&self.receiver);

        var log_file_path = std.ArrayList(u8).init(self.a);
        defer log_file_path.deinit();
        const cache_dir = root.get_cache_dir() catch |e| return tp.exit_error(e);
        log_file_path.writer().print("{s}/lsp-{s}.log", .{ cache_dir, self.tag }) catch |e| return tp.exit_error(e);
        self.log_file = std.fs.createFileAbsolute(log_file_path.items, .{ .truncate = true }) catch |e| return tp.exit_error(e);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name });
        defer frame.deinit();
        errdefer self.deinit();
        var method: []u8 = "";
        var bytes: []u8 = "";

        if (try m.match(.{ "REQ", tp.extract(&method), tp.extract(&bytes) })) {
            self.send_request(from, method, bytes) catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ "NTFY", tp.extract(&method), tp.extract(&bytes) })) {
            self.send_notification(method, bytes) catch |e| return tp.exit_error(e);
        } else if (try m.match(.{"close"})) {
            try self.close();
        } else if (try m.match(.{ sp_tag, "stdout", tp.extract(&bytes) })) {
            self.handle_output(bytes) catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ sp_tag, "term", tp.more })) {
            self.handle_terminated() catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ sp_tag, "stderr", tp.extract(&bytes) })) {
            self.write_log("{s}\n", .{bytes});
        } else if (try m.match(.{ "exit", "normal" })) {
            return tp.exit_normal();
        } else {
            const e = tp.unexpected(m);
            self.write_log("{s}\n", .{tp.error_text()});
            return e;
        }
    }

    fn receive_lsp_message(self: *Process, cb: []const u8) !void {
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

    fn handle_output(self: *Process, bytes: []u8) !void {
        try self.recv_buf.appendSlice(bytes);
        self.write_log("### RECV:\n{s}\n###\n", .{bytes});
        try self.frame_message_recv();
    }

    fn handle_terminated(self: *Process) !void {
        self.write_log("terminated\n", .{});
        try self.parent.send(.{ self.tag, "done" });
    }

    fn send_request(self: *Process, from: tp.pid_ref, method: []const u8, params_cb: []const u8) !void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        const id = self.next_id;
        self.next_id += 1;

        var msg = std.ArrayList(u8).init(self.a);
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

        const json = try cbor.toJsonPrettyAlloc(self.a, msg.items);
        defer self.a.free(json);
        var output = std.ArrayList(u8).init(self.a);
        defer output.deinit();
        const writer = output.writer();
        try writer.print("Content-Length: {d}\r\n\r\n", .{json.len});
        _ = try writer.write(json);

        try sp.send(output.items);
        self.write_log("### SEND request:\n{s}\n###\n", .{output.items});
        try self.requests.put(id, from.clone());
    }

    fn send_notification(self: *Process, method: []const u8, params_cb: []const u8) !void {
        const sp = if (self.sp) |*sp| sp else return error.Closed;

        var msg = std.ArrayList(u8).init(self.a);
        defer msg.deinit();
        const msg_writer = msg.writer();
        try cbor.writeMapHeader(msg_writer, 3);
        try cbor.writeValue(msg_writer, "jsonrpc");
        try cbor.writeValue(msg_writer, "2.0");
        try cbor.writeValue(msg_writer, "method");
        try cbor.writeValue(msg_writer, method);
        try cbor.writeValue(msg_writer, "params");
        _ = try msg_writer.write(params_cb);

        const json = try cbor.toJsonPrettyAlloc(self.a, msg.items);
        defer self.a.free(json);
        var output = std.ArrayList(u8).init(self.a);
        defer output.deinit();
        const writer = output.writer();
        try writer.print("Content-Length: {d}\r\n\r\n", .{json.len});
        _ = try writer.write(json);

        try sp.send(output.items);
        self.write_log("### SEND notification:\n{s}\n###\n", .{output.items});
    }

    fn frame_message_recv(self: *Process) !void {
        const sep = "\r\n\r\n";
        const headers_end = std.mem.indexOf(u8, self.recv_buf.items, sep) orelse return;
        const headers_data = self.recv_buf.items[0..headers_end];
        const headers = try Headers.parse(headers_data);
        if (self.recv_buf.items.len - (headers_end + sep.len) < headers.content_length) return;
        const buf = try self.recv_buf.toOwnedSlice();
        const data = buf[headers_end + sep.len .. headers_end + sep.len + headers.content_length];
        const rest = buf[headers_end + sep.len + headers.content_length ..];
        defer self.a.free(buf);
        if (rest.len > 0) try self.recv_buf.appendSlice(rest);
        const message = .{ .body = data[0..headers.content_length] };
        const cb = try cbor.fromJsonAlloc(self.a, message.body);
        defer self.a.free(cb);
        return self.receive_lsp_message(cb);
    }

    fn receive_lsp_request(self: *Process, id: i32, method: []const u8, params: ?[]const u8) !void {
        const json = if (params) |p| try cbor.toJsonPrettyAlloc(self.a, p) else null;
        defer if (json) |p| self.a.free(p);
        self.write_log("### RECV req: {d}\nmethod: {s}\n{s}\n###\n", .{ id, method, json orelse "no params" });
    }

    fn receive_lsp_response(self: *Process, id: i32, result: ?[]const u8, err: ?[]const u8) !void {
        const json = if (result) |p| try cbor.toJsonPrettyAlloc(self.a, p) else null;
        defer if (json) |p| self.a.free(p);
        const json_err = if (err) |p| try cbor.toJsonPrettyAlloc(self.a, p) else null;
        defer if (json_err) |p| self.a.free(p);
        self.write_log("### RECV rsp: {d} {s}\n{s}\n###\n", .{ id, if (json_err) |_| "error" else "response", json_err orelse json orelse "no result" });
        const from = self.requests.get(id) orelse return;
        var msg = std.ArrayList(u8).init(self.a);
        defer msg.deinit();
        const writer = msg.writer();
        try cbor.writeArrayHeader(writer, 2);
        if (err) |err_| {
            try cbor.writeValue(writer, "error");
            try cbor.writeValue(writer, err_);
        } else if (result) |result_| {
            try cbor.writeValue(writer, "result");
            try cbor.writeValue(writer, result_);
        }
        try from.send_raw(.{ .buf = msg.items });
    }

    fn receive_lsp_notification(self: *Process, method: []const u8, params: ?[]const u8) !void {
        const json = if (params) |p| try cbor.toJsonPrettyAlloc(self.a, p) else null;
        defer if (json) |p| self.a.free(p);
        self.write_log("### RECV notify:\nmethod: {s}\n{s}\n###\n", .{ method, json orelse "no params" });
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
