const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");

const root = @import("soft_root").root;

const ScriptExecutor = @import("ScriptExecutor.zig");

const log = std.log.scoped(.stdin);

const module_name = @typeName(@This());
const chunk_size = 16 * 1024;

pub const Input = struct {
    kind: enum { pipe, file },
    handle: std.Io.File.Handle,
};

pub fn detect(io: std.Io) ?Input {
    if (builtin.os.tag == .windows) return detect_windows();
    if (std.c.fcntl(std.posix.STDIN_FILENO, std.posix.F.GETFD) < 0) return null;
    const stat = std.Io.File.stdin().stat(io) catch return null;
    return .{
        .kind = switch (stat.kind) {
            .named_pipe => .pipe,
            .file => .file,
            else => return null,
        },
        .handle = std.posix.STDIN_FILENO,
    };
}

fn detect_windows() ?Input {
    const handle = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse return null;
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return null;
    const input: Input = .{
        .kind = switch (win32.GetFileType(handle)) {
            win32.FILE_TYPE_PIPE => .pipe,
            win32.FILE_TYPE_DISK => .file,
            else => return null,
        },
        .handle = handle,
    };
    const console = win32.open(std.unicode.utf8ToUtf16LeStringLiteral("CONIN$")) orelse
        win32.open(std.unicode.utf8ToUtf16LeStringLiteral("NUL")) orelse return null;
    _ = win32.SetStdHandle(win32.STD_INPUT_HANDLE, console);
    return input;
}

pub fn spawn(allocator: std.mem.Allocator, ctx: *tp.context, eh: anytype, env: ?tp.env, target: tp.pid_ref, input: Input, create_args: tp.message, script: ?ScriptExecutor.Script, then: ?tp.message) !void {
    const args = try Process.Args.init(allocator, target, input, create_args, script, then);
    errdefer args.deinit();
    const pid = try ctx.spawn_link(args, Process.start, module_name, eh, env);
    pid.deinit();
}

const Process = struct {
    allocator: std.mem.Allocator,
    target: tp.pid,
    input: Input,
    script: ?ScriptExecutor.Script,
    then: ?[]const u8,
    fd_watcher: ?tp.file_descriptor = null,
    windows_reader: ?*WindowsReader = null,
    buffer_ref: ?[]const u8 = null,
    next_id: u64 = 1,
    read_buf: [chunk_size]u8 = undefined,
    join_buf: [chunk_size + 3]u8 = undefined,
    partial_len: usize = 0,
    args_buf: [chunk_size + 64]u8 = undefined,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        target: tp.pid,
        input: Input,
        create_args: []const u8,
        script: ?ScriptExecutor.Script,
        then: ?[]const u8,

        fn init(allocator: std.mem.Allocator, target: tp.pid_ref, input: Input, create_args: tp.message, script: ?ScriptExecutor.Script, then: ?tp.message) !Args {
            errdefer if (script) |s| s.deinit();
            const create_args_owned = try allocator.dupe(u8, create_args.buf);
            errdefer allocator.free(create_args_owned);
            const then_owned = if (then) |m| try allocator.dupe(u8, m.buf) else null;
            return .{
                .allocator = allocator,
                .target = target.clone(),
                .input = input,
                .create_args = create_args_owned,
                .script = script,
                .then = then_owned,
            };
        }

        fn deinit(self: Args) void {
            self.target.deinit();
            self.allocator.free(self.create_args);
            if (self.script) |s| s.deinit();
            if (self.then) |then| self.allocator.free(then);
        }
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| {
            log.err("start failed: {t}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn init(args: Args) !void {
        defer args.allocator.free(args.create_args);
        const self = args.allocator.create(@This()) catch |e| {
            args.target.deinit();
            if (args.script) |s| s.deinit();
            if (args.then) |then| args.allocator.free(then);
            return e;
        };
        self.* = .{
            .allocator = args.allocator,
            .target = args.target,
            .input = args.input,
            .script = args.script,
            .then = args.then,
            .receiver = .init(receive_fn, @This().deinit, self),
        };
        errdefer self.deinit();
        _ = tp.set_trap(true);
        try self.target.link();
        try self.send_command("create_buffer", .{ .bytes = args.create_args });
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (builtin.os.tag == .windows) {
            if (self.windows_reader) |reader| reader.stop();
        } else if (self.fd_watcher) |fd_watcher| fd_watcher.deinit();
        if (self.buffer_ref) |buffer_ref| self.allocator.free(buffer_ref);
        self.target.deinit();
        if (self.script) |s| s.deinit();
        if (self.then) |then| self.allocator.free(then);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| {
            self.send_then();
            return tp.exit_error(e, @errorReturnTrace());
        };
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var id: u64 = 0;
        var buffer_ref: cbor.Raw = .empty;
        var exit_msg: cbor.Raw = .empty;
        var reason: []const u8 = "";
        var err_code: i64 = 0;
        var err_msg: []const u8 = "";
        var bytes: []const u8 = "";

        if (try m.match(.{ "reply", 1, .{ "buffer", "hidden", tp.more } }) or
            try m.match(.{ "reply", 1, .{ "buffer", "deleted", tp.more } }))
        {
            self.close_stdin();
            return self.finish();
        } else if (try m.match(.{ "reply", tp.extract(&id), .{ "buffer", tp.extract(&buffer_ref) } })) {
            if (id != 1 or self.buffer_ref != null) return;
            self.buffer_ref = try self.allocator.dupe(u8, buffer_ref.bytes);
            try self.buffer_created();
            return self.read_next();
        } else if (try m.match(.{ "reply", tp.extract(&id), "ok" })) {
            // create_buffer may be acked more than once if it waits for loads, so it starts on the buffer reply
            if (id == 1 or id != self.next_id - 1) return;
            return self.read_next();
        } else if (try m.match(.{ "reply", tp.extract(&id), .{ "error", tp.extract(&exit_msg) } })) {
            if (id != 1 and id != self.next_id - 1) return;
            var buf: [256]u8 = undefined;
            if (!try cbor.match(exit_msg.bytes, .{ "exit", cbor.extract(&reason), cbor.more }))
                reason = (tp.message{ .buf = exit_msg.bytes }).to_json(&buf) catch "(unknown)";
            log.err("{s} failed: {s}", .{ if (id == 1) "create_buffer" else "append", reason });
            return self.finish();
        } else if (try m.match(.{"read_next"})) {
            return self.read_next();
        } else if (try m.match(.{ "fd", "stdin", "read_ready" })) {
            return self.read_chunk();
        } else if (try m.match(.{ "fd", "stdin", "read_error", tp.extract(&err_code), tp.extract(&err_msg) }) or
            try m.match(.{ "stream", "stdin", "read_error", tp.extract(&err_code), tp.extract(&err_msg) }))
        {
            log.err("read failed: {s}", .{err_msg});
            return self.finish();
        } else if (try m.match(.{ "stream", "stdin", "read_complete", tp.extract(&bytes) })) {
            if (bytes.len == 0) return self.finish_input();
            return self.append(bytes);
        } else if (try m.match(.{ "exit", tp.more })) {
            if (from.instance_id() == self.target.instance_id()) return tp.exit_normal();
        }
    }

    fn buffer_created(self: *@This()) !void {
        const script = self.script orelse return;
        self.script = null;
        try ScriptExecutor.create(self.allocator, self.target.ref(), script, if (self.then) |m| .{ .buf = m } else null);
    }

    fn read_next(self: *@This()) !void {
        if (builtin.os.tag == .windows) {
            if (self.windows_reader == null)
                self.windows_reader = try WindowsReader.start(self.allocator, self.input.handle);
            return self.windows_reader.?.next.set(root.get_io());
        }
        switch (self.input.kind) {
            .file => return self.read_chunk(),
            .pipe => {
                if (self.fd_watcher == null)
                    self.fd_watcher = try tp.file_descriptor.init("stdin", self.input.handle);
                try self.fd_watcher.?.wait_read();
            },
        }
    }

    fn read_chunk(self: *@This()) !void {
        if (builtin.os.tag == .windows) return self.finish();
        const n = std.posix.read(self.input.handle, &self.read_buf) catch |e| {
            log.err("read failed: {t}", .{e});
            return self.finish();
        };
        if (n == 0) return self.finish_input();
        return self.append(self.read_buf[0..n]);
    }

    fn append(self: *@This(), data: []const u8) !void {
        @memcpy(self.join_buf[self.partial_len..][0..data.len], data);
        const joined = self.join_buf[0 .. self.partial_len + data.len];
        const complete = joined[0 .. joined.len - partial_utf8_suffix_len(joined)];
        self.partial_len = joined.len - complete.len;
        if (complete.len == 0) return tp.self_pid().send(.{"read_next"});
        try self.send_data(complete);
        std.mem.copyForwards(u8, self.join_buf[0..self.partial_len], joined[complete.len..]);
    }

    fn send_data(self: *@This(), data: []const u8) !void {
        try self.send_command("shell_execute_stream_output", .{ .bytes = cbor.fmt(&self.args_buf, .{ cbor.Raw{ .bytes = self.buffer_ref.? }, data }) });
    }

    fn finish_input(self: *@This()) !void {
        if (self.partial_len > 0) try self.send_data(self.join_buf[0..self.partial_len]);
        return self.finish();
    }

    fn partial_utf8_suffix_len(data: []const u8) usize {
        var i: usize = 1;
        while (i <= @min(3, data.len)) : (i += 1) {
            const byte = data[data.len - i];
            if (byte & 0xC0 == 0x80) continue;
            const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch return 0;
            return if (seq_len > i) i else 0;
        }
        return 0;
    }

    fn send_command(self: *@This(), name: []const u8, args: cbor.Raw) !void {
        const id = self.next_id;
        self.next_id += 1;
        try self.target.send(.{ "cmd", name, args, .{ "reply", tp.self_pid().instance_id(), id } });
    }

    fn close_stdin(self: *@This()) void {
        if (builtin.os.tag == .windows) {
            if (self.windows_reader) |reader| reader.stop() else std.os.windows.CloseHandle(self.input.handle);
            self.windows_reader = null;
            return;
        }
        if (self.fd_watcher) |fd_watcher| fd_watcher.deinit();
        self.fd_watcher = null;
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (null_fd < 0) return;
        _ = std.c.dup2(null_fd, self.input.handle);
        _ = std.c.close(null_fd);
    }

    fn finish(self: *@This()) error{Exit} {
        self.send_then();
        return tp.exit_normal();
    }

    fn send_then(self: *@This()) void {
        const then = self.then orelse return;
        self.then = null;
        defer self.allocator.free(then);
        self.target.send_raw(.{ .buf = then }) catch {};
        if (self.script != null) self.target.send_raw(.{ .buf = then }) catch {};
    }
};

const WindowsReader = struct {
    allocator: std.mem.Allocator,
    handle: std.os.windows.HANDLE,
    target: tp.pid,
    thread: std.Thread,
    next: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    buf: [chunk_size]u8 = undefined,

    fn start(allocator: std.mem.Allocator, handle: std.os.windows.HANDLE) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .handle = handle, .target = tp.self_pid().clone(), .thread = undefined };
        errdefer self.target.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn stop(self: *@This()) void {
        const io = root.get_io();
        self.stopping.store(true, .release);
        self.next.set(io);
        while (true) {
            _ = win32.CancelSynchronousIo(self.thread.getHandle());
            self.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch continue;
            break;
        }
        self.thread.join();
        std.os.windows.CloseHandle(self.handle);
        self.target.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *@This()) void {
        const io = root.get_io();
        defer self.done.set(io);
        while (true) {
            self.next.waitUncancelable(io);
            self.next.reset();
            if (self.stopping.load(.acquire)) return;
            var n: std.os.windows.DWORD = 0;
            if (win32.ReadFile(self.handle, &self.buf, self.buf.len, &n, null) == .FALSE) switch (std.os.windows.GetLastError()) {
                .BROKEN_PIPE, .HANDLE_EOF => n = 0,
                .OPERATION_ABORTED => return,
                else => |e| {
                    self.target.send(.{ "stream", "stdin", "read_error", @backingInt(e), "ReadFile failed" }) catch {};
                    return;
                },
            };
            self.target.send(.{ "stream", "stdin", "read_complete", self.buf[0..n] }) catch return;
            if (n == 0) return;
        }
    }
};

const win32 = struct {
    const w = std.os.windows;
    const STD_INPUT_HANDLE: w.DWORD = 0xFFFFFFF6; // -10
    const FILE_TYPE_DISK: w.DWORD = 0x0001;
    const FILE_TYPE_PIPE: w.DWORD = 0x0003;
    extern "kernel32" fn GetStdHandle(nStdHandle: w.DWORD) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn SetStdHandle(nStdHandle: w.DWORD, hHandle: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetFileType(hFile: w.HANDLE) callconv(.winapi) w.DWORD;
    extern "kernel32" fn CreateFileW(lpFileName: w.LPCWSTR, dwDesiredAccess: w.DWORD, dwShareMode: w.DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: w.DWORD, dwFlagsAndAttributes: w.DWORD, hTemplateFile: ?w.HANDLE) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn ReadFile(hFile: w.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: w.DWORD, lpNumberOfBytesRead: ?*w.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CancelSynchronousIo(hThread: w.HANDLE) callconv(.winapi) w.BOOL;

    fn open(name: [*:0]const u16) ?w.HANDLE {
        const GENERIC_READ: w.DWORD = 0x80000000;
        const GENERIC_WRITE: w.DWORD = 0x40000000;
        const FILE_SHARE_READ: w.DWORD = 0x0001;
        const FILE_SHARE_WRITE: w.DWORD = 0x0002;
        const OPEN_EXISTING: w.DWORD = 3;
        const h = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        return if (h == w.INVALID_HANDLE_VALUE) null else h;
    }
};
