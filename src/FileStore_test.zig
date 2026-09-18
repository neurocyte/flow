const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const FileStore = @import("FileStore.zig");

const allocator = std.heap.c_allocator;

test "largest stream messages fit in a remote frame" {
    const remote_max_frame_size = 8 * 4096;
    const remote_send_overhead = 64;
    var chunk: [FileStore.max_chunk_size]u8 = undefined;
    @memset(&chunk, 'x');
    const max_int = std.math.maxInt(usize);
    const read_chunk = tp.message.fmt(.{ "FS", "read_chunk", max_int, max_int, cbor.Bytes.init(&chunk) });
    try std.testing.expect(read_chunk.buf.len + remote_send_overhead < remote_max_frame_size);
    const write_chunk = tp.message.fmt(.{ "write_chunk", max_int, max_int, cbor.Bytes.init(&chunk) });
    try std.testing.expect(write_chunk.buf.len + remote_send_overhead < remote_max_frame_size);
}

const tiny: FileStore.StreamOptions = .{ .chunk_size = 3, .window = 2 };
const big = "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++
    "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789";
const big2 = "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++
    "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij";

const Op = union(enum) {
    write: struct { name: []const u8, content: []const u8, expect_error: bool = false },
    read: struct { name: []const u8, content: ?[]const u8 },
    read_two: struct { a: []const u8, a_content: []const u8, b: []const u8, b_content: []const u8 },
    probe: struct { name: []const u8, kind: FileStore.ProbeKind, binary: bool = false },
    short_write: struct { name: []const u8 },
    dying_writer: struct { name: []const u8 },
    watch: struct { name: []const u8 },
    expect_no_events: struct { ms: u64 },
    external_append: struct { name: []const u8, content: []const u8 },
    expect_event: struct { ms: u64 },
};

fn fail(comptime fmt: []const u8, args: anytype) error{Exit} {
    return tp.exit(std.fmt.allocPrint(allocator, fmt, args) catch "fail");
}

const Driver = struct {
    receiver: tp.Receiver(*@This()),
    store: FileStore,
    dir: []const u8,
    ops: []const Op,
    index: usize = 0,
    next_id: usize = 1,
    reads: [2]?FileStore.ReadStream = .{ null, null },
    expected: [2]?[]const u8 = .{ null, null },
    write: ?FileStore.WriteStream = null,
    request_id: usize = 0,
    watched: []const u8 = "",
    events: usize = 0,
    timeout: ?tp.timeout = null,
    helper: ?tp.pid = null,

    const Args = struct { dir: []const u8, ops: []const Op };

    fn start(args: Args) tp.result {
        return init(args) catch |e| tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        tp.env.get().set("enable_file_watcher", true);
        const self = try allocator.create(@This());
        self.* = .{
            .receiver = .init(receive_fn, dtor, self),
            .store = .{ .pid = try FileStore.spawn() },
            .dir = args.dir,
            .ops = args.ops,
        };
        try self.next();
        tp.receive(&self.receiver);
    }

    fn dtor(self: *@This()) void {
        if (self.timeout) |*t| t.deinit();
        self.store.deinit();
    }

    fn path(self: *@This(), name: []const u8) []const u8 {
        return std.fs.path.join(allocator, &.{ self.dir, name }) catch @panic("OOM");
    }

    fn new_id(self: *@This()) usize {
        defer self.next_id += 1;
        return self.next_id;
    }

    fn start_timer(self: *@This(), ms: u64) !void {
        if (self.timeout) |*t| t.deinit();
        self.timeout = try tp.timeout.init_ms(ms, tp.message.fmt(.{"timer"}));
    }

    fn advance(self: *@This()) anyerror!void {
        self.index += 1;
        return self.next();
    }

    fn next(self: *@This()) anyerror!void {
        if (self.index >= self.ops.len) return tp.exit("success");
        switch (self.ops[self.index]) {
            .write => |op| {
                self.write = try FileStore.WriteStream.start(&self.store, allocator, self.new_id(), self.path(op.name), op.content, .{ .stream = tiny });
            },
            .read => |op| {
                self.reads[0] = try .start(&self.store, allocator, self.new_id(), self.path(op.name), tiny);
                self.expected[0] = op.content;
            },
            .read_two => |op| {
                self.reads[0] = try .start(&self.store, allocator, self.new_id(), self.path(op.a), tiny);
                self.expected[0] = op.a_content;
                self.reads[1] = try .start(&self.store, allocator, self.new_id(), self.path(op.b), tiny);
                self.expected[1] = op.b_content;
            },
            .probe => |op| {
                self.request_id = self.new_id();
                try self.store.probe(self.request_id, self.path(op.name));
            },
            .short_write => |op| {
                self.request_id = self.new_id();
                try self.store.pid.send(.{ "write_begin", self.request_id, self.path(op.name), @as(u64, 10), true, @as(usize, 4) });
                try self.store.pid.send(.{ "write_chunk", self.request_id, @as(usize, 0), cbor.Bytes.init("12345") });
                try self.store.pid.send(.{ "write_commit", self.request_id });
            },
            .dying_writer => |op| {
                self.helper = try tp.spawn_link(allocator, DyingWriter.Args{
                    .store = self.store.pid.clone(),
                    .path = self.path(op.name),
                }, DyingWriter.start, "dying_writer");
            },
            .watch => |op| {
                self.watched = self.path(op.name);
                try self.store.watch(self.watched);
                try self.start_timer(300);
            },
            .expect_no_events => |op| {
                self.events = 0;
                try self.start_timer(op.ms);
            },
            .external_append => |op| {
                const io = std.testing.io;
                const f = try std.Io.Dir.cwd().openFile(io, self.path(op.name), .{ .mode = .read_write });
                defer f.close(io);
                const stat = try f.stat(io);
                try f.writePositionalAll(io, op.content, stat.size);
                self.events = 0;
                return self.advance();
            },
            .expect_event => |op| {
                if (self.events > 0) return self.advance();
                try self.start_timer(op.ms);
            },
        }
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var path_: []const u8 = undefined;
        var id: usize = 0;
        var kind: FileStore.ProbeKind = .none;
        var binary = false;
        var op_name: []const u8 = undefined;
        var err_name: []const u8 = undefined;

        if (try m.match(.{ "FS", "change", tp.extract(&path_), tp.more }) or
            try m.match(.{ "FS", "rename", tp.string, tp.extract(&path_), tp.more }))
        {
            if (!std.mem.eql(u8, path_, self.watched)) return;
            self.events += 1;
            if (self.index < self.ops.len and self.ops[self.index] == .expect_event) {
                if (self.timeout) |*t| t.deinit();
                self.timeout = null;
                return self.advance();
            }
            return;
        }
        if (try m.match(.{"timer"})) {
            if (self.timeout) |*t| t.deinit();
            self.timeout = null;
            if (self.index >= self.ops.len) return;
            return switch (self.ops[self.index]) {
                .watch, .dying_writer => self.advance(),
                .expect_no_events => if (self.events == 0) self.advance() else fail("{d} change events for our own write", .{self.events}),
                .expect_event => fail("no change event for an external write", .{}),
                else => {},
            };
        }
        if (try m.match(.{ "exit", tp.more })) {
            if (self.helper) |*helper| if (helper.instance_id() == from.instance_id()) {
                helper.deinit();
                self.helper = null;
                return self.start_timer(200);
            };
            return fail("unexpected exit: {f}", .{m});
        }

        const reply = FileStore.reply_id(m) orelse return fail("unexpected message: {f}", .{m});

        if (self.write) |*w| if (w.id == reply) {
            const op = self.ops[self.index].write;
            const result = w.receive(&self.store, m) catch |e| switch (e) {
                error.FileStoreStreamFailed => {
                    if (!op.expect_error) return fail("write {s} failed: {s}", .{ op.name, w.error_name });
                    w.deinit();
                    self.write = null;
                    return self.advance();
                },
                else => return e,
            };
            if (result == .done) {
                w.deinit();
                self.write = null;
                if (op.expect_error) return fail("write {s} should have failed", .{op.name});
                return self.advance();
            }
            return;
        };

        for (&self.reads, 0..) |*slot, i| if (slot.*) |*r| if (r.id == reply) {
            const result = r.receive(&self.store, m) catch |e| return fail("read failed: {t} {s}", .{ e, r.error_name });
            if (result == .pending) return;
            const expected = self.expected[i];
            if (expected) |content| {
                if (!r.exists) return fail("read: file does not exist", .{});
                if (!std.mem.eql(u8, content, r.content.items))
                    return fail("read: expected '{s}' got '{s}'", .{ content, r.content.items });
            } else if (r.exists) return fail("read: file should not exist", .{});
            r.deinit();
            slot.* = null;
            if (self.reads[0] == null and self.reads[1] == null) return self.advance();
            return;
        };

        if (reply != self.request_id) return;
        switch (self.ops[self.index]) {
            .probe => |op| {
                if (!try m.match(.{ "FS", "probed", tp.extract(&id), tp.extract(&path_), tp.extract(&kind), tp.extract(&binary) }))
                    return fail("unexpected probe reply: {f}", .{m});
                if (kind != op.kind or binary != op.binary)
                    return fail("probe {s}: expected {t}/{} got {t}/{}", .{ op.name, op.kind, op.binary, kind, binary });
                return self.advance();
            },
            .short_write => {
                if (try m.match(.{ "FS", "write_ack", tp.more })) return;
                if (!try m.match(.{ "FS", "error", tp.extract(&id), tp.extract(&op_name), tp.extract(&err_name) }))
                    return fail("short write should fail: {f}", .{m});
                if (!std.mem.eql(u8, err_name, "SizeMismatch")) return fail("short write: {s}", .{err_name});
                return self.advance();
            },
            else => return fail("unexpected reply: {f}", .{m}),
        }
    }
};

const DyingWriter = struct {
    receiver: tp.Receiver(*@This()),
    store: tp.pid,

    const Args = struct { store: tp.pid, path: []const u8 };

    fn start(args: Args) tp.result {
        const self = allocator.create(@This()) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.* = .{ .receiver = .init(receive, dtor, self), .store = args.store };
        self.store.send(.{ "write_begin", @as(usize, 1), args.path, @as(u64, 1000), true, @as(usize, 4) }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.store.send(.{ "write_chunk", @as(usize, 1), @as(usize, 0), cbor.Bytes.init("partial") }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.store.send(.{ "probe", @as(usize, 2), args.path }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn dtor(self: *@This()) void {
        self.store.deinit();
    }

    fn receive(_: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
        if (m.match(.{ "FS", "probed", tp.more }) catch false) return tp.exit_normal();
    }
};

fn write_fixture(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    const io = std.testing.io;
    const f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writePositionalAll(io, data, 0);
}

fn read_fixture(dir: std.Io.Dir, name: []const u8) ![]u8 {
    const io = std.testing.io;
    const f = try dir.openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const stat = try f.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

test "file store streams" {
    const io = std.testing.io;
    const posix = builtin.os.tag != .windows;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    try write_fixture(tmp.dir, "existing.txt", "old content");
    if (posix) {
        const f = try tmp.dir.openFile(io, "existing.txt", .{});
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o640));
    }
    try write_fixture(tmp.dir, "big2.txt", big2);
    try write_fixture(tmp.dir, "binary.bin", "abc\x00def");
    try write_fixture(tmp.dir, "watched.txt", "first");
    if (posix) {
        try write_fixture(tmp.dir, "target.txt", "target");
        try tmp.dir.symLink(io, "target.txt", "link.txt", .{});
    }
    const read_only_dir = builtin.os.tag == .linux and std.os.linux.getuid() != 0;
    if (read_only_dir) {
        try tmp.dir.createDir(io, "ro", .default_dir);
        const ro = try tmp.dir.openDir(io, "ro", .{ .iterate = true });
        defer ro.close(io);
        try ro.setPermissions(io, .fromMode(0o555));
    }

    var ops: std.ArrayList(Op) = .empty;
    try ops.appendSlice(allocator, &.{
        .{ .write = .{ .name = "new.txt", .content = big } },
        .{ .read = .{ .name = "new.txt", .content = big } },
        .{ .write = .{ .name = "empty.txt", .content = "" } },
        .{ .read = .{ .name = "empty.txt", .content = "" } },
        .{ .write = .{ .name = "exact.txt", .content = "abc" } },
        .{ .read = .{ .name = "exact.txt", .content = "abc" } },
        .{ .write = .{ .name = "plus1.txt", .content = "abcd" } },
        .{ .read = .{ .name = "plus1.txt", .content = "abcd" } },
        .{ .read = .{ .name = "missing.txt", .content = null } },
        .{ .write = .{ .name = "existing.txt", .content = "new content" } },
        .{ .write = .{ .name = "nested/dir/file.txt", .content = "nested" } },
        .{ .read_two = .{ .a = "new.txt", .a_content = big, .b = "big2.txt", .b_content = big2 } },
        .{ .probe = .{ .name = "new.txt", .kind = .file } },
        .{ .probe = .{ .name = "nested", .kind = .dir } },
        .{ .probe = .{ .name = "binary.bin", .kind = .file, .binary = true } },
        .{ .probe = .{ .name = "nope", .kind = .none } },
        .{ .short_write = .{ .name = "short.txt" } },
        .{ .dying_writer = .{ .name = "dying.txt" } },
    });
    if (posix) try ops.append(allocator, .{ .write = .{ .name = "link.txt", .content = "via link" } });
    if (read_only_dir) try ops.append(allocator, .{ .write = .{ .name = "ro/file.txt", .content = big, .expect_error = true } });
    try ops.appendSlice(allocator, &.{
        .{ .watch = .{ .name = "watched.txt" } },
        .{ .write = .{ .name = "watched.txt", .content = "own write" } },
        .{ .expect_no_events = .{ .ms = 300 } },
        .{ .external_append = .{ .name = "watched.txt", .content = " external" } },
        .{ .expect_event = .{ .ms = 3000 } },
    });

    var ctx = try tp.context.init(std.testing.allocator, .{});
    defer ctx.deinit();
    var status: []const u8 = "not run";
    var exit_handler = tp.make_exit_handler(&status, struct {
        fn handle(result: *[]const u8, msg: []const u8) void {
            result.* = allocator.dupe(u8, msg) catch "OOM";
        }
    }.handle);
    _ = try ctx.spawn_link(Driver.Args{ .dir = dir, .ops = ops.items }, Driver.start, "file_store_test", &exit_handler, null);
    ctx.run();
    if (!std.mem.eql(u8, status, "success")) {
        std.log.err("file store test: {s}", .{status});
        return error.TestFailed;
    }

    try std.testing.expectEqualStrings("new content", try read_fixture(tmp.dir, "existing.txt"));
    try std.testing.expectEqualStrings("nested", try read_fixture(tmp.dir, "nested/dir/file.txt"));
    try std.testing.expectEqualStrings("own write external", try read_fixture(tmp.dir, "watched.txt"));
    if (posix) {
        const f = try tmp.dir.openFile(io, "existing.txt", .{});
        defer f.close(io);
        const mode = @backingInt((try f.stat(io)).permissions);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o640), mode & 0o777);

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link = link_buf[0..try tmp.dir.readLink(io, "link.txt", &link_buf)];
        try std.testing.expectEqualStrings("target.txt", link);
        try std.testing.expectEqualStrings("via link", try read_fixture(tmp.dir, "target.txt"));
    }

    const allowed = [_][]const u8{ "new.txt", "empty.txt", "exact.txt", "plus1.txt", "existing.txt", "nested", "big2.txt", "binary.bin", "watched.txt", "target.txt", "link.txt", "ro" };
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, name, entry.name)) break;
        } else {
            std.log.err("unexpected file left behind: {s}", .{entry.name});
            return error.TestFailed;
        }
    }
    if (read_only_dir) {
        const ro = try tmp.dir.openDir(io, "ro", .{ .iterate = true });
        defer ro.close(io);
        try ro.setPermissions(io, .fromMode(0o755));
    }
}
