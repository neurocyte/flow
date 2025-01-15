const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");

pub const ripgrep_binary = "rg";

pid: ?tp.pid,
stdin_behavior: std.process.Child.StdIo,

const Self = @This();
const module_name = @typeName(Self);
pub const max_chunk_size = tp.subprocess.max_chunk_size;
pub const Writer = std.io.Writer(*Self, Error, write);
pub const BufferedWriter = std.io.BufferedWriter(max_chunk_size, Writer);
pub const Error = error{ OutOfMemory, Exit, ThespianSpawnFailed, Closed };

pub const FindF = fn (allocator: std.mem.Allocator, query: []const u8, tag: [:0]const u8) Error!Self;

pub fn find_in_stdin(allocator: std.mem.Allocator, query: []const u8, tag: [:0]const u8) Error!Self {
    return create(allocator, query, tag, .Pipe);
}

pub fn find_in_files(allocator: std.mem.Allocator, query: []const u8, tag: [:0]const u8) !Self {
    return create(allocator, query, tag, .Close);
}

fn create(allocator: std.mem.Allocator, query: []const u8, tag: [:0]const u8, stdin_behavior: std.process.Child.StdIo) !Self {
    return .{ .pid = try Process.create(allocator, query, tag, stdin_behavior), .stdin_behavior = stdin_behavior };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        if (self.stdin_behavior == .Pipe)
            pid.send(.{"close"}) catch {};
        self.pid = null;
        pid.deinit();
    }
}

pub fn write(self: *Self, bytes: []const u8) !usize {
    try self.input(bytes);
    return bytes.len;
}

pub fn input(self: *const Self, bytes: []const u8) !void {
    const pid = self.pid orelse return error.Closed;
    var remaining = bytes;
    while (remaining.len > 0)
        remaining = loop: {
            if (remaining.len > max_chunk_size) {
                try pid.send(.{ "input", remaining[0..max_chunk_size] });
                break :loop remaining[max_chunk_size..];
            } else {
                try pid.send(.{ "input", remaining });
                break :loop &[_]u8{};
            }
        };
}

pub fn close(self: *Self) void {
    self.deinit();
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}

pub fn bufferedWriter(self: *Self) BufferedWriter {
    return .{ .unbuffered_writer = self.writer() };
}

const Process = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    receiver: Receiver,
    sp: ?tp.subprocess = null,
    output: std.ArrayList(u8),
    parent: tp.pid,
    tag: [:0]const u8,
    logger: log.Logger,
    stdin_behavior: std.process.Child.StdIo,
    match_count: usize = 0,

    const Receiver = tp.Receiver(*Process);

    pub fn create(allocator: std.mem.Allocator, query: []const u8, tag: [:0]const u8, stdin_behavior: std.process.Child.StdIo) !tp.pid {
        const self = try allocator.create(Process);
        self.* = .{
            .allocator = allocator,
            .query = try allocator.dupe(u8, query),
            .receiver = Receiver.init(receive, self),
            .output = std.ArrayList(u8).init(allocator),
            .parent = tp.self_pid().clone(),
            .tag = try allocator.dupeZ(u8, tag),
            .logger = log.logger(@typeName(Self)),
            .stdin_behavior = stdin_behavior,
        };
        return tp.spawn_link(self.allocator, self, Process.start, tag);
    }

    fn deinit(self: *Process) void {
        if (self.sp) |*sp| sp.deinit();
        self.parent.deinit();
        self.output.deinit();
        self.logger.deinit();
        self.allocator.free(self.tag);
        self.allocator.free(self.query);
        self.close() catch {};
        self.allocator.destroy(self);
    }

    fn close(self: *Process) tp.result {
        if (self.sp) |*sp| {
            defer self.sp = null;
            try sp.close();
        }
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        _ = tp.set_trap(true);
        const args = tp.message.fmt(.{
            ripgrep_binary,
            // "--line-buffered",
            "--fixed-strings",
            "--json",
            "--smart-case",
            self.query,
        });
        self.sp = tp.subprocess.init(self.allocator, args, module_name, self.stdin_behavior) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var bytes: []u8 = "";

        if (try m.match(.{ "input", tp.extract(&bytes) })) {
            const sp = self.sp orelse return tp.exit_error(error.Closed, null);
            try sp.send(bytes);
        } else if (try m.match(.{"close"})) {
            try self.close();
        } else if (try m.match(.{ module_name, "stdout", tp.extract(&bytes) })) {
            self.handle_output(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ module_name, "term", tp.more })) {
            self.handle_terminated(m) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ module_name, "stderr", tp.extract(&bytes) })) {
            self.logger.print("ERR: {s}", .{bytes});
        } else if (try m.match(.{ "exit", "normal" })) {
            return tp.exit_normal();
        } else {
            self.logger.err("receive", tp.unexpected(m));
            return tp.unexpected(m);
        }
    }

    fn handle_output(self: *Process, bytes: []u8) !void {
        try self.output.appendSlice(bytes);
    }

    fn handle_terminated(self: *Process, m: tp.message) !void {
        const output = try self.output.toOwnedSlice();
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |json| {
            if (json.len == 0) continue;
            var msg_buf: [tp.max_message_size]u8 = undefined;
            const msg: tp.message = .{ .buf = try cbor.fromJson(json, &msg_buf) };
            try self.dispatch(msg);
            count += 1;
            if (count > 1000) break;
        }
        try self.parent.send(.{ self.tag, "done" });
        if (count > 1000) {
            self.logger.print("found more than {d} matches", .{self.match_count});
        } else {
            var err_msg: []const u8 = undefined;
            var exit_code: i64 = undefined;
            if (try m.match(.{ tp.any, tp.any, "exited", 0 })) {
                self.logger.print("found {d} matches", .{self.match_count});
            } else if (try m.match(.{ tp.any, tp.any, "exited", 1 })) {
                self.logger.print("no matches found", .{});
            } else if (try m.match(.{ tp.any, tp.any, "error.FileNotFound", 1 })) {
                self.logger.print_err(ripgrep_binary, "'{s}' executable not found", .{ripgrep_binary});
            } else if (try m.match(.{ tp.any, tp.any, tp.extract(&err_msg), tp.extract(&exit_code) })) {
                self.logger.print_err(ripgrep_binary, "terminated {s} exitcode: {d}", .{ err_msg, exit_code });
            }
        }
    }

    fn dispatch(self: *Process, m: tp.message) !void {
        var obj = std.json.ObjectMap.init(self.allocator);
        defer obj.deinit();
        if (try m.match(tp.extract(&obj))) {
            if (obj.get("type")) |*val| {
                if (std.mem.eql(u8, "match", val.string))
                    if (obj.get("data")) |*data| switch (data.*) {
                        .object => |*o| try self.dispatch_match(o),
                        else => {},
                    };
            }
        }
    }

    fn get_match_string(obj: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
        return if (obj.get(name)) |*val| switch (val.*) {
            .object => |*o| if (o.get("text")) |*val_| switch (val_.*) {
                .string => |s| if (std.mem.eql(u8, "<stdin>", s)) null else s,
                else => null,
            } else null,
            else => null,
        } else null;
    }

    fn dispatch_match(self: *Process, obj: *const std.json.ObjectMap) !void {
        const path: ?[]const u8 = get_match_string(obj, "path");
        const lines: ?[]const u8 = get_match_string(obj, "lines");

        const line = if (obj.get("line_number")) |*val| switch (val.*) {
            .integer => |i| i,
            else => return,
        } else return;

        if (obj.get("submatches")) |*val| switch (val.*) {
            .array => |*a| try self.dispatch_submatches(path, line, a, lines),
            else => return,
        };
    }

    fn dispatch_submatches(self: *Process, path: ?[]const u8, line: i64, arr: *const std.json.Array, lines: ?[]const u8) !void {
        for (arr.items) |*item| switch (item.*) {
            .object => |*o| try self.dispatch_submatch(path, line, o, lines),
            else => {},
        };
    }

    fn dispatch_submatch(self: *Process, path: ?[]const u8, line: i64, obj: *const std.json.ObjectMap, lines: ?[]const u8) !void {
        const begin = if (obj.get("start")) |*val| switch (val.*) {
            .integer => |i| i,
            else => return,
        } else return;
        const end = if (obj.get("end")) |*val| switch (val.*) {
            .integer => |i| i,
            else => return,
        } else return;
        if (path) |p| {
            const match_text = if (lines) |l|
                if (l[l.len - 1] == '\n') l[0 .. l.len - 1] else l
            else
                "";
            try self.parent.send(.{ self.tag, p, line, begin, line, end, match_text });
        } else {
            try self.parent.send(.{ self.tag, line, begin, line, end });
        }
        self.match_count += 1;
    }
};
