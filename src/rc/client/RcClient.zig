const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const remote = @import("remote");
const common = @import("common");
const z2d = @import("z2d");

const log = std.log.scoped(.client);

pub const Probe = @import("Probe.zig");

pid: ?tp.pid,

const module_name = @typeName(@This());
pub const Error = error{ OutOfMemory, ThespianSpawnFailed };

pub const Track = common.Track;
pub const exit_failed = "remote_requests_failed";
pub const exit_terminal_prefix = "terminal_exited:";

pub const Options = struct {
    track: Track = .none,
    verbose: bool = false,
    terminal: ?u64 = null,
    focus_mode: FocusMode = .auto,
    output: ?Output = null,
    when_done: WhenDone = .disconnect,
    io: ?std.Io = null,
};

pub const WhenDone = enum { disconnect, keep_open };

pub const Output = struct {
    writer: *std.Io.Writer,
    format: Format,

    pub const Format = enum { json, cbor, text };

    pub fn write(self: Output, allocator: std.mem.Allocator, value: anytype) !void {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        try cbor.writeValue(&buf.writer, value);
        return self.write_raw(.{ .bytes = buf.written() });
    }

    pub fn write_raw(self: Output, value: cbor.Raw) !void {
        switch (self.format) {
            .json => {
                try cbor.toJsonWriter(value.bytes, self.writer, .{});
                try self.writer.writeByte('\n');
            },
            .cbor => try self.writer.writeAll(value.bytes),
            .text => try write_text(self.writer, value.bytes),
        }
        try self.writer.flush();
    }

    fn write_text(writer: *std.Io.Writer, value: []const u8) !void {
        var iter = value;
        const len = cbor.decodeArrayHeader(&iter) catch {
            try write_text_value(writer, value);
            return writer.writeByte('\n');
        };
        for (0..len) |i| {
            if (i > 0) try writer.writeByte('\t');
            const start = iter;
            try cbor.skipValue(&iter);
            try write_text_value(writer, start[0 .. start.len - iter.len]);
        }
        try writer.writeByte('\n');
    }

    fn write_text_value(writer: *std.Io.Writer, value: []const u8) !void {
        var iter = value;
        var str: []const u8 = undefined;
        if (cbor.matchString(&iter, &str) catch false) return writer.writeAll(str);
        return cbor.toJsonWriter(value, writer, .{});
    }
};

pub const FocusMode = enum { auto, always, never };

pub fn create(allocator: std.mem.Allocator, path: []const u8, options: Options) Error!@This() {
    const args = try Process.Args.init(allocator, path, options);
    errdefer args.deinit();
    return .{ .pid = try tp.spawn_link(allocator, args, Process.start, module_name) };
}

pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, env: ?tp.env, path: []const u8, options: Options) !@This() {
    const args = try Process.Args.init(allocator, path, options);
    errdefer args.deinit();
    return .{ .pid = try ctx.spawn_link(args, Process.start, module_name, eh, env) };
}

pub fn deinit(self: *@This()) void {
    if (self.pid) |pid| {
        self.pid = null;
        pid.deinit();
    }
}

pub fn shutdown(self: *@This()) void {
    if (self.pid) |pid| {
        pid.send(.{"shutdown"}) catch {};
        self.deinit();
    }
}

pub fn disconnect(self: *const @This()) tp.result {
    const pid = self.pid orelse return tp.exit_error(error.Shutdown, null);
    return pid.send(.{"disconnect"});
}

pub fn navigate(self: *const @This(), args: anytype) tp.result {
    return self.request("navigate", args);
}

pub fn request(self: *const @This(), cmd: []const u8, args: anytype) tp.result {
    const pid = self.pid orelse return tp.exit_error(error.Shutdown, null);
    return pid.send(.{ "request", cmd, args });
}

const Process = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    connector: ?tp.pid = null,
    connection: ?tp.pid = null,
    server: ?tp.pid = null,
    disconnecting: bool = false,
    pending: std.ArrayList([]const u8) = .empty,
    held: std.ArrayList([]const u8) = .empty,
    next_request_id: u64 = 1,
    outstanding: std.AutoHashMapUnmanaged(u64, Request) = .empty,
    failed: usize = 0,
    discarded: usize = 0,
    terminal_exit: u8 = 0,
    track: Track,
    verbose: bool,
    terminal: ?u64,
    focus_mode: FocusMode,
    focus: Focus = .{},
    tracked_requests: std.AutoHashMapUnmanaged(u64, void) = .empty,
    tracked_buffers: std.AutoHashMapUnmanaged(u64, void) = .empty,
    creates: std.AutoHashMapUnmanaged(u64, ?LocalReply) = .empty,
    holds: usize = 0,
    output: ?Output,
    when_done: WhenDone,
    io: ?std.Io,
    screenshot: ?Screenshot = null,
    names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    receiver: tp.Receiver(*@This()),

    const Screenshot = struct {
        request_id: u64,
        pixels: std.ArrayList(u8) = .empty,
        next: usize = 0,
    };

    const Request = struct {
        cmd: []const u8,
        origin: enum { user, focus },
        reply_to: ?LocalReply = null,
    };

    const LocalReply = struct {
        piid: tp.piid,
        id: u64,

        fn send(self: LocalReply, payload: cbor.Raw) void {
            const pid = tp.pid.from_id(self.piid) orelse return;
            defer pid.deinit();
            pid.send(.{ "reply", self.id, payload }) catch {};
        }
    };

    const TerminalFocus = enum { focused, unfocused };
    const PanelState = enum { maximized, normal };

    const Focus = struct {
        state: enum { unknown, querying, known, restoring } = .unknown,
        unfocused: bool = false,
        unmaximized: bool = false,
    };

    const Args = struct {
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        options: Options,

        fn init(allocator: std.mem.Allocator, path: []const u8, options: Options) Error!Args {
            return .{ .allocator = allocator, .path = try allocator.dupeSentinel(u8, path, 0), .options = options };
        }

        fn deinit(self: Args) void {
            self.allocator.free(self.path);
        }
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| {
            log.err("start failed on {s}: {t}", .{ args.path, e });
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn init(args: Args) !void {
        const self = args.allocator.create(@This()) catch |e| {
            args.deinit();
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .path = args.path,
            .track = args.options.track,
            .verbose = args.options.verbose,
            .terminal = args.options.terminal,
            .focus_mode = args.options.focus_mode,
            .output = args.options.output,
            .when_done = args.options.when_done,
            .io = args.options.io,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);
        self.connector = try remote.endpoint.unx.connect(self.allocator, self.path, .file, tp.self_pid().clone());
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        for (self.pending.items) |msg| self.allocator.free(msg);
        self.pending.deinit(self.allocator);
        for (self.held.items) |msg| self.allocator.free(msg);
        self.held.deinit(self.allocator);
        var it = self.outstanding.valueIterator();
        while (it.next()) |pending_request| self.allocator.free(pending_request.cmd);
        self.outstanding.deinit(self.allocator);
        var names = self.names.valueIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.names.deinit(self.allocator);
        self.tracked_requests.deinit(self.allocator);
        self.tracked_buffers.deinit(self.allocator);
        self.creates.deinit(self.allocator);
        if (self.screenshot) |*s| s.pixels.deinit(self.allocator);
        if (self.server) |p| p.deinit();
        if (self.connection) |p| p.deinit();
        if (self.connector) |p| p.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var conn_id: tp.piid = .empty;
        var reason: []const u8 = "";
        var server_version: []const u8 = "";
        var args: cbor.Raw = .empty;
        var cmd: []const u8 = "";
        var request_id: u64 = 0;
        var local: LocalReply = undefined;

        if (try m.match(.{ "request", tp.extract(&cmd), tp.extract(&args) })) {
            try self.send_request(cmd, args, null);
        } else if (try m.match(.{ "cmd", tp.extract(&cmd), tp.extract(&args), .{ "reply", tp.extract(&local.piid), tp.extract(&local.id) } })) {
            try self.send_request(cmd, args, local);
        } else if (try m.match(.{ "cmd", "navigate", tp.extract(&args) })) {
            try self.send_request("navigate", args, null);
        } else if (try m.match(.{ "reply", tp.extract(&request_id), tp.extract(&args) })) {
            return self.handle_reply(request_id, args);
        } else if (try m.match(.{ "cmd", tp.extract(&cmd), tp.more })) {
            self.log_verbose("ignoring unsupported command: {s}", .{cmd});
        } else if (try m.match(.{ "A", tp.more })) {
            self.log_verbose("ignoring unsupported selection request", .{});
        } else if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            try self.connected(conn_id);
        } else if (try m.match(.{ "hello", tp.extract(&server_version) })) {
            try self.hello(from, server_version);
        } else if (try m.match(.{"hold"})) {
            self.holds += 1;
        } else if (try m.match(.{"release"})) {
            self.holds -|= 1;
            return self.disconnect_when_done();
        } else if (try m.match(.{"disconnect"})) {
            self.disconnecting = true;
            return self.disconnect_when_done();
        } else if (try m.match(.{"shutdown"})) {
            self.shutdown();
            return self.exit_done();
        } else if (try m.match(.{ "exit", tp.extract(&reason) }) or try m.match(.{ "exit", tp.extract(&reason), tp.more })) {
            return self.handle_exit(from, reason);
        } else {
            var buf: [256]u8 = undefined;
            log.warn("ignoring unexpected message: {s}", .{m.to_json(&buf) catch "(too large)"});
        }
    }

    fn connected(self: *@This(), conn_id: tp.piid) !void {
        const conn = tp.pid.from_id(conn_id) orelse return self.closed_before_handshake();
        self.connection = conn;
        conn.link() catch return self.closed_before_handshake();
        const self_id: remote.protocol.lpiid = .fromInt(tp.self_pid().instance_id().toInt());
        conn.send(.{ "send", self_id, common.service_name, .{ "hello", common.build_version } }) catch return self.closed_before_handshake();
    }

    fn closed_before_handshake(self: *@This()) error{Exit} {
        return tp.exit_fmt("connection to {s} closed before the handshake", .{self.path});
    }

    fn hello(self: *@This(), from: tp.pid_ref, server_version: []const u8) !void {
        if (self.server != null) return;
        const server = from.clone();
        self.server = server;
        self.log_verbose("connected to {s}: {s}", .{ self.path, server_version });
        for (self.pending.items) |msg| try server.send_raw(.{ .buf = msg });
        for (self.pending.items) |msg| self.allocator.free(msg);
        self.pending.clearRetainingCapacity();
        return self.disconnect_when_done();
    }

    fn send_request(self: *@This(), cmd: []const u8, args: cbor.Raw, reply_to: ?LocalReply) !void {
        const manage_focus = switch (self.focus_mode) {
            .auto => std.mem.eql(u8, cmd, "create_buffer") or std.mem.eql(u8, cmd, "navigate"),
            .always => true,
            .never => false,
        };
        if (manage_focus) try self.query_terminal_state();
        return self.send_request_from(.user, cmd, args, reply_to);
    }

    fn send_focus_request(self: *@This(), cmd: []const u8, args: anytype) !void {
        var buf: [64]u8 = undefined;
        return self.send_request_from(.focus, cmd, .{ .bytes = cbor.fmt(&buf, args) }, null);
    }

    fn query_terminal_state(self: *@This()) !void {
        const terminal = self.terminal orelse return;
        if (self.focus.state != .unknown) return;
        self.focus.state = .querying;
        try self.send_focus_request("get_terminal_state", .{terminal});
    }

    fn apply_terminal_state(self: *@This(), focus: TerminalFocus, panel: PanelState) !void {
        const terminal = self.terminal orelse return;
        if (self.focus.state != .querying) return;
        self.focus.state = .known;
        if (panel == .maximized) {
            try self.send_focus_request("unmaximize_panel", .{});
            self.focus.unmaximized = true;
        }
        if (focus == .focused) {
            try self.send_focus_request("unfocus_terminal_id", .{terminal});
            self.focus.unfocused = true;
        }
        return self.release_held();
    }

    fn release_held(self: *@This()) !void {
        const server = self.server orelse return;
        for (self.held.items) |msg| try server.send_raw(.{ .buf = msg });
        for (self.held.items) |msg| self.allocator.free(msg);
        self.held.clearRetainingCapacity();
    }

    fn restore_terminal_state(self: *@This()) !bool {
        const terminal = self.terminal orelse return false;
        if (self.track == .none or self.focus.state != .known) return false;
        if (!self.focus.unfocused and !self.focus.unmaximized) return false;
        self.focus.state = .restoring;
        if (self.focus.unfocused) try self.send_focus_request("focus_terminal_id", .{terminal});
        if (self.focus.unmaximized) try self.send_focus_request("maximize_panel", .{});
        return true;
    }

    fn send_request_from(self: *@This(), origin: @FieldType(Request, "origin"), cmd: []const u8, args: cbor.Raw, reply_to: ?LocalReply) !void {
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        const cmd_owned = try self.allocator.dupe(u8, cmd);
        errdefer self.allocator.free(cmd_owned);
        try self.outstanding.put(self.allocator, request_id, .{ .cmd = cmd_owned, .origin = origin, .reply_to = reply_to });
        if (self.output != null and origin == .user) {
            const name = try self.allocator.dupe(u8, cmd);
            errdefer self.allocator.free(name);
            try self.names.put(self.allocator, request_id, name);
        }
        var tracked_args: std.Io.Writer.Allocating = .init(self.allocator);
        defer tracked_args.deinit();
        const request_args = if (self.track != .none and std.mem.eql(u8, cmd, "navigate")) blk: {
            if (!try add_track_field(&tracked_args.writer, args, self.track)) break :blk args;
            try self.tracked_requests.put(self.allocator, request_id, {});
            break :blk cbor.Raw{ .bytes = tracked_args.written() };
        } else args;
        if (origin == .user and std.mem.eql(u8, cmd, "create_buffer"))
            try self.creates.put(self.allocator, request_id, reply_to);
        if (self.track != .none and std.mem.eql(u8, cmd, "open_terminal_argv"))
            try self.tracked_requests.put(self.allocator, request_id, {});
        const m = tp.message.fmt(.{ "request", request_id, cmd, request_args });
        const hold = origin == .user and self.focus.state == .querying;
        if (!hold) if (self.server) |server| return server.send_raw(m);
        const msg = try self.allocator.dupe(u8, m.buf);
        errdefer self.allocator.free(msg);
        return (if (hold) &self.held else &self.pending).append(self.allocator, msg);
    }

    fn add_track_field(writer: *std.Io.Writer, args: cbor.Raw, track: Track) !bool {
        var iter = args.bytes;
        const len = cbor.decodeMapHeader(&iter) catch return false;
        try cbor.writeMapHeader(writer, len + 1);
        try writer.writeAll(iter);
        try cbor.writeValue(writer, "track");
        try cbor.writeValue(writer, track);
        return true;
    }

    fn handle_reply(self: *@This(), request_id: u64, payload: cbor.Raw) !void {
        if (try self.handle_screenshot(request_id, payload)) return;
        if (self.output) |output| try self.print_reply(output, request_id, payload);
        if (self.creates.get(request_id)) |reply_to| return self.handle_create_reply(request_id, reply_to, payload);
        if (self.outstanding.get(request_id)) |pending_request| if (pending_request.reply_to) |reply_to| reply_to.send(payload);
        if (try self.handle_event(request_id, payload)) return self.disconnect_when_done();
        if (!try is_ack(payload)) {
            if (self.output != null) return;
            if (self.outstanding.get(request_id)) |pending_request|
                log.info("{s}: {f}", .{ pending_request.cmd, tp.message{ .buf = payload.bytes } })
            else
                log.info("reply {d}: {f}", .{ request_id, tp.message{ .buf = payload.bytes } });
            return;
        }
        const entry = self.outstanding.fetchRemove(request_id) orelse {
            if (self.output == null) log.info("reply {d}: {f}", .{ request_id, tp.message{ .buf = payload.bytes } });
            return;
        };
        const cmd = entry.value.cmd;
        defer self.allocator.free(cmd);
        var exit_msg: cbor.Raw = .empty;
        var reason: []const u8 = "";
        if (try cbor.match(payload.bytes, "ok")) {
            self.log_verbose("{s}: ok", .{cmd});
        } else if (entry.value.origin == .focus and try cbor.match(payload.bytes, .{ "error", cbor.extract(&exit_msg) })) {
            self.log_verbose("{s} failed: {f}", .{ cmd, tp.message{ .buf = exit_msg.bytes } });
            if (self.focus.state == .querying) {
                self.focus.state = .known;
                try self.release_held();
            }
        } else if (try cbor.match(payload.bytes, .{ "error", cbor.extract(&exit_msg) })) {
            self.failed += 1;
            _ = self.tracked_requests.remove(request_id);
            if (entry.value.reply_to != null) {
                self.log_verbose("{s} failed", .{cmd});
            } else if (try cbor.match(exit_msg.bytes, .{ "exit", cbor.extract(&reason), cbor.more }))
                log.err("{s} failed: {s}", .{ cmd, reason })
            else
                log.err("{s} failed: {f}", .{ cmd, tp.message{ .buf = exit_msg.bytes } });
        }
        return self.disconnect_when_done();
    }

    fn handle_screenshot(self: *@This(), request_id: u64, payload: cbor.Raw) !bool {
        var idx: usize = 0;
        var chunk: cbor.Bytes = .empty;
        if (try cbor.match(payload.bytes, .{ "screenshot", cbor.extract(&idx), cbor.extract(&chunk) })) {
            const s = try self.screenshot_for(request_id);
            if (idx != s.next) return error.ScreenshotChunkOutOfOrder;
            try s.pixels.appendSlice(self.allocator, chunk.data);
            s.next += 1;
            return true;
        }
        var format: []const u8 = "";
        var width: u16 = 0;
        var height: u16 = 0;
        if (try cbor.match(payload.bytes, .{ "screenshot", cbor.extract(&idx), "done", cbor.extract(&format), cbor.extract(&width), cbor.extract(&height) })) {
            const s = try self.screenshot_for(request_id);
            defer {
                s.pixels.deinit(self.allocator);
                self.screenshot = null;
            }
            if (idx != s.next) return error.ScreenshotIncomplete;
            if (!std.mem.eql(u8, format, "rgba8")) return error.UnsupportedScreenshotFormat;
            const path = try self.write_screenshot(s.pixels.items, width, height);
            defer self.allocator.free(path);
            var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
            const done: cbor.Raw = .{ .bytes = cbor.fmt(&buf, .{ "screenshot", path }) };
            if (self.output) |output| try self.print_reply(output, request_id, done) else log.info("screenshot saved to {s}", .{path});
            return true;
        }
        if (self.screenshot) |*s| if (s.request_id == request_id and try cbor.match(payload.bytes, .{ "error", cbor.any })) {
            s.pixels.deinit(self.allocator);
            self.screenshot = null;
        };
        return false;
    }

    fn screenshot_for(self: *@This(), request_id: u64) !*Screenshot {
        if (self.screenshot) |*s| {
            if (s.request_id != request_id) return error.ScreenshotAlreadyActive;
            return s;
        }
        self.screenshot = .{ .request_id = request_id };
        return &self.screenshot.?;
    }

    fn write_screenshot(self: *@This(), bytes: []const u8, width: u16, height: u16) ![]const u8 {
        const io = self.io orelse return error.ScreenshotNeedsIo;
        if (width == 0 or height == 0 or bytes.len != @as(usize, width) * height * @sizeOf(z2d.pixel.RGBA))
            return error.ScreenshotSizeMismatch;
        const pixels = try self.allocator.alloc(z2d.pixel.RGBA, @as(usize, width) * height);
        defer self.allocator.free(pixels);
        @memcpy(std.mem.sliceAsBytes(pixels), bytes);
        const surface: z2d.surface.ImageSurface(z2d.pixel.RGBA) = .{ .width = width, .height = height, .buf = pixels };
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        const path = try std.fmt.allocPrint(self.allocator, "flow-screenshot-{d}.png", .{now});
        errdefer self.allocator.free(path);
        try z2d.png_exporter.writeToPNGFile(io, surface.asSurfaceInterface(), path, .{});
        return path;
    }

    /// only the ack ("ok" or an error) ends a request, data replies come before it
    fn is_ack(payload: cbor.Raw) !bool {
        return try cbor.match(payload.bytes, "ok") or try cbor.match(payload.bytes, .{ "error", cbor.any });
    }

    /// focus requests are internal and have no name, so they do not print
    fn print_reply(self: *@This(), output: Output, request_id: u64, payload: cbor.Raw) error{Exit}!void {
        const cmd = self.names.get(request_id) orelse return;
        const result = switch (output.format) {
            .text => if (is_ack(payload) catch true) {} else output.write_raw(payload),
            .json, .cbor => output.write(self.allocator, .{ .id = request_id, .command = cmd, .reply = payload }),
        };
        result catch |e| {
            self.shutdown();
            return tp.exit_fmt("write reply {d} failed: {t}", .{ request_id, e });
        };
    }

    /// a created buffer replies {"buffer", ref}, acks (maybe more than once) and then sends buffer events until it is closed
    fn handle_create_reply(self: *@This(), request_id: u64, reply_to: ?LocalReply, payload: cbor.Raw) !void {
        if (reply_to) |local| local.send(payload);
        if (try is_ack(payload)) if (self.outstanding.fetchRemove(request_id)) |entry| self.allocator.free(entry.value.cmd);
        var exit_msg: cbor.Raw = .empty;
        var event: []const u8 = "";
        var path: []const u8 = "";
        if (try cbor.match(payload.bytes, .{ "error", cbor.extract(&exit_msg) })) {
            _ = self.creates.remove(request_id);
            self.failed += 1;
            if (reply_to == null) log.err("create_buffer failed: {f}", .{tp.message{ .buf = exit_msg.bytes }});
        } else if (try cbor.match(payload.bytes, .{ "buffer", cbor.extract(&event), cbor.any, cbor.extract(&path), cbor.more })) {
            if (std.mem.eql(u8, event, "hidden") or std.mem.eql(u8, event, "deleted")) {
                if (self.creates.remove(request_id)) self.log_verbose("closed {s}", .{path});
            }
        }
        return self.disconnect_when_done();
    }

    fn log_verbose(self: *const @This(), comptime fmt: []const u8, args: anytype) void {
        if (self.verbose) log.info(fmt, args);
    }

    fn handle_event(self: *@This(), request_id: u64, payload: cbor.Raw) !bool {
        var buffer_id: u64 = 0;
        var path: []const u8 = "";
        var event: []const u8 = "";
        var old_path: []const u8 = "";
        var focus: TerminalFocus = .unfocused;
        var panel: PanelState = .normal;
        var exit_code: u8 = 0;
        if (try cbor.match(payload.bytes, .{ "terminal_state", cbor.extract(&focus), cbor.extract(&panel) })) {
            try self.apply_terminal_state(focus, panel);
        } else if (try cbor.match(payload.bytes, .{ "terminal", "exited", cbor.extract(&exit_code) })) {
            if (self.tracked_requests.remove(request_id)) self.terminal_exit = exit_code;
            self.log_verbose("terminal exited with code {d}", .{exit_code});
        } else if (try cbor.match(payload.bytes, .{ "terminal", "closed" })) {
            if (self.tracked_requests.remove(request_id)) self.terminal_exit = 1;
            self.log_verbose("terminal closed", .{});
        } else if (try cbor.match(payload.bytes, .{ "navigation", "complete", .{ "BUFID", cbor.extract(&buffer_id) }, cbor.extract(&path) })) {
            _ = self.tracked_requests.remove(request_id);
            try self.tracked_buffers.put(self.allocator, buffer_id, {});
            self.log_verbose("opened {s}", .{path});
        } else if (try cbor.match(payload.bytes, .{ "navigation", "failed", cbor.extract(&path) })) {
            _ = self.tracked_requests.remove(request_id);
            self.failed += 1;
            log.err("open {s} failed", .{path});
        } else if (try cbor.match(payload.bytes, .{ "buffer", "renamed", .{ "BUFID", cbor.extract(&buffer_id) }, cbor.extract(&path), cbor.extract(&old_path) })) {
            self.log_verbose("renamed {s} -> {s}", .{ old_path, path });
        } else if (try cbor.match(payload.bytes, .{ "buffer", "discarded", .{ "BUFID", cbor.extract(&buffer_id) }, cbor.extract(&path) })) {
            if (self.tracked_buffers.remove(buffer_id)) {
                self.discarded += 1;
                self.log_verbose("discarded {s}", .{path});
            }
        } else if (try cbor.match(payload.bytes, .{ "buffer", cbor.extract(&event), .{ "BUFID", cbor.extract(&buffer_id) }, cbor.extract(&path), cbor.more })) {
            if (std.mem.eql(u8, event, "hidden") or std.mem.eql(u8, event, "deleted")) {
                if (self.tracked_buffers.remove(buffer_id)) self.log_verbose("closed {s}", .{path});
            } else {
                self.log_verbose("{s} {s}", .{ event, path });
            }
        } else return false;
        return true;
    }

    fn disconnect_when_done(self: *@This()) !void {
        if (!self.disconnecting or self.server == null) return;
        if (self.when_done == .keep_open and self.failed == 0) return;
        if (self.outstanding.count() > 0 or self.tracked_requests.count() > 0 or self.tracked_buffers.count() > 0) return;
        if (self.holds > 0 or (self.track != .none and self.creates.count() > 0)) return;
        if (try self.restore_terminal_state()) return;
        self.shutdown();
        return self.exit_done();
    }

    fn exit_done(self: *@This()) error{Exit} {
        if (self.failed == 0 and self.discarded == 0) {
            if (self.terminal_exit != 0) return tp.exit_fmt(exit_terminal_prefix ++ "{d}", .{self.terminal_exit});
            return tp.exit_normal();
        }
        if (self.failed > 0) log.err("{d} remote request(s) failed", .{self.failed});
        return tp.exit(exit_failed);
    }

    fn handle_exit(self: *@This(), from: tp.pid_ref, reason: []const u8) !void {
        const id = from.instance_id();
        if (self.connector) |connector| if (id == connector.instance_id()) {
            connector.deinit();
            self.connector = null;
            if (std.mem.eql(u8, reason, "normal")) return;
            return tp.exit_fmt("connect to {s} failed: {s}", .{ self.path, reason });
        };
        if (self.connection) |connection| if (id == connection.instance_id()) {
            connection.deinit();
            self.connection = null;
            if (!std.mem.eql(u8, reason, "peer_closed")) return tp.exit(reason);
            if (self.server == null) return self.closed_before_handshake();
            if (self.outstanding.count() > 0 or self.pending.items.len > 0 or self.held.items.len > 0)
                return tp.exit_fmt("connection to {s} closed before all replies arrived", .{self.path});
            return self.exit_done();
        };
    }

    fn shutdown(self: *@This()) void {
        if (self.connection) |connection| connection.send(.{ "exit", "shutdown" }) catch {};
        if (self.connector) |connector| connector.send(.{"cancel"}) catch {};
    }
};
