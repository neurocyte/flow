const std = @import("std");
const tp = @import("thespian");
const diffz = @import("diffz");
const Buffer = @import("Buffer");
const tracy = @import("tracy");

const module_name = @typeName(@This());

const diff_ = @import("diff.zig");
const Diff = diff_.LineDiff;
const Kind = diff_.LineDiffKind;

pub fn create() !AsyncDiffer {
    return .{ .pid = try Process.create() };
}

pub const AsyncDiffer = struct {
    pid: ?tp.pid,

    pub fn deinit(self: *@This()) void {
        if (self.pid) |pid| {
            pid.send(.{"shutdown"}) catch {};
            pid.deinit();
            self.pid = null;
        }
    }

    fn text_from_root(root: Buffer.Root, eol_mode: Buffer.EolMode) ![]const u8 {
        var text: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer text.deinit();
        try root.store(&text.writer, eol_mode);
        return text.toOwnedSlice();
    }

    pub const CallBack = fn (from: tp.pid_ref, edits: []Diff) void;

    pub fn diff_buffer(self: @This(), cb: *const CallBack, buffer: *const Buffer) tp.result {
        const eol_mode = buffer.file_eol_mode;
        const text_dst = text_from_root(buffer.root, eol_mode) catch |e| return tp.exit_error(e, @errorReturnTrace());
        errdefer std.heap.c_allocator.free(text_dst);
        const text_src = if (buffer.get_vcs_content()) |vcs_content|
            std.heap.c_allocator.dupe(u8, vcs_content) catch |e| return tp.exit_error(e, @errorReturnTrace())
        else
            text_from_root(buffer.last_save orelse return, eol_mode) catch |e| return tp.exit_error(e, @errorReturnTrace());
        errdefer std.heap.c_allocator.free(text_src);
        const text_dst_ptr: usize = if (text_dst.len > 0) @intFromPtr(text_dst.ptr) else 0;
        const text_src_ptr: usize = if (text_src.len > 0) @intFromPtr(text_src.ptr) else 0;
        if (self.pid) |pid| try pid.send(.{ "D", @intFromPtr(cb), text_dst_ptr, text_dst.len, text_src_ptr, text_src.len });
    }
};

const Process = struct {
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const allocator = std.heap.c_allocator;

    pub fn create() !tp.pid {
        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        self.* = .{
            .receiver = Receiver.init(Process.receive, self),
        };
        return tp.spawn_link(allocator, self, Process.start, module_name);
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *Process) void {
        allocator.destroy(self);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        var cb: usize = 0;
        var text_dst_ptr: usize = 0;
        var text_dst_len: usize = 0;
        var text_src_ptr: usize = 0;
        var text_src_len: usize = 0;

        return if (try m.match(.{ "D", tp.extract(&cb), tp.extract(&text_dst_ptr), tp.extract(&text_dst_len), tp.extract(&text_src_ptr), tp.extract(&text_src_len) })) blk: {
            const text_dst = if (text_dst_len > 0) @as([*]const u8, @ptrFromInt(text_dst_ptr))[0..text_dst_len] else "";
            const text_src = if (text_src_len > 0) @as([*]const u8, @ptrFromInt(text_src_ptr))[0..text_src_len] else "";
            break :blk do_diff_async(from, cb, text_dst, text_src) catch |e| tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn do_diff_async(from_: tp.pid_ref, cb_addr: usize, text_dst: []const u8, text_src: []const u8) !void {
        defer std.heap.c_allocator.free(text_dst);
        defer std.heap.c_allocator.free(text_src);
        const cb_: *AsyncDiffer.CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);

        var arena_ = std.heap.ArenaAllocator.init(allocator);
        defer arena_.deinit();
        const arena = arena_.allocator();

        const edits = try diff(arena, text_dst, text_src);
        cb_(from_, edits);
    }
};

pub fn diff(allocator: std.mem.Allocator, dst: []const u8, src: []const u8) error{OutOfMemory}![]Diff {
    var arena_ = std.heap.ArenaAllocator.init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();
    const frame = tracy.initZone(@src(), .{ .name = "diff" });
    defer frame.deinit();

    var diffs: std.ArrayList(Diff) = .empty;
    errdefer diffs.deinit(allocator);

    const dmp = diffz.default;
    var diff_list = try diffz.diff(&dmp, arena, src, dst, false);
    try diffz.diffCleanupSemantic(arena, &diff_list);

    if (diff_list.items.len > 2)
        try diffs.ensureTotalCapacity(allocator, (diff_list.items.len - 1) / 2);

    var lines_dst: usize = 0;
    var pos_dst: usize = 0;
    var last_offset: usize = 0;

    for (diff_list.items) |diffz_diff| {
        switch (diffz_diff.operation) {
            .equal => {
                const dist = diffz_diff.text.len;
                pos_dst += dist;
                scan_eol(diffz_diff.text, &lines_dst, &last_offset);
            },
            .insert => {
                const dist = diffz_diff.text.len;
                pos_dst += dist;
                const line_start_dst: usize = lines_dst;
                scan_eol(diffz_diff.text, &lines_dst, &last_offset);
                (try diffs.addOne(allocator)).* = .{
                    .kind = .insert,
                    .line = line_start_dst,
                    .lines = lines_dst - line_start_dst,
                };
                if (last_offset > 0)
                    (try diffs.addOne(allocator)).* = .{
                        .kind = .modify,
                        .line = line_start_dst,
                        .lines = 1,
                    };
            },
            .delete => {
                pos_dst += 0;
                var lines: usize = 0;
                var diff_offset: usize = 0;
                scan_eol(diffz_diff.text, &lines, &diff_offset);
                (try diffs.addOne(allocator)).* = .{
                    .kind = .modify,
                    .line = lines_dst,
                    .lines = 1,
                };
                if (lines > 0)
                    (try diffs.addOne(allocator)).* = .{
                        .kind = .delete,
                        .line = lines_dst,
                        .lines = lines,
                    };
                if (lines > 0 and diff_offset > 0)
                    (try diffs.addOne(allocator)).* = .{
                        .kind = .modify,
                        .line = lines_dst,
                        .lines = 1,
                    };
            },
        }
    }
    return diffs.toOwnedSlice(allocator);
}

fn scan_eol(chars: []const u8, lines: *usize, remain: *usize) void {
    var pos = chars;
    remain.* += pos.len;
    while (pos.len > 0) {
        if (pos[0] == '\n') {
            remain.* = pos.len - 1;
            lines.* += 1;
        }
        pos = pos[1..];
    }
}
