const std = @import("std");
const tp = @import("thespian");
const EditSet = @import("EditSet");
const Buffer = @import("Buffer");
const tracy = @import("tracy");

const module_name = @typeName(@This());

pub const LineDiff = EditSet.LineMark;
pub const LineDiffKind = EditSet.LineMark.Kind;

const Diff = LineDiff;

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

    pub const CallBack = fn (from: tp.pid_ref, data: usize, edits: []Diff) void;

    pub fn diff_buffer(self: @This(), cb: *const CallBack, cb_data: usize, buffer: *Buffer) tp.result {
        const pid = self.pid orelse return;
        const eol_mode = buffer.file_eol_mode;
        const text_src = (buffer.share_diff_base(eol_mode) catch |e| return tp.exit_error(e, @errorReturnTrace())) orelse return;
        errdefer text_src.release();
        const text_dst = buffer.share_text(eol_mode);
        errdefer text_dst.release();
        try pid.send(.{ "D", @intFromPtr(cb), cb_data, @intFromPtr(text_dst), @intFromPtr(text_src) });
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
            .receiver = .init(receive, dtor, self),
        };
        return tp.spawn_link(allocator, self, Process.start, module_name);
    }

    fn start(self: *Process) tp.result {
        tp.receive(&self.receiver);
    }

    fn dtor(self: *Process) void {
        allocator.destroy(self);
    }

    fn receive(_: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        var cb: usize = 0;
        var cb_data: usize = 0;
        var text_dst_ptr: usize = 0;
        var text_src_ptr: usize = 0;

        return if (try m.match(.{ "D", tp.extract(&cb), tp.extract(&cb_data), tp.extract(&text_dst_ptr), tp.extract(&text_src_ptr) })) blk: {
            const text_dst: *Buffer.SharedText = @ptrFromInt(text_dst_ptr);
            defer text_dst.release();
            const text_src: *Buffer.SharedText = @ptrFromInt(text_src_ptr);
            defer text_src.release();
            const cb_: *AsyncDiffer.CallBack = if (cb == 0) return else @ptrFromInt(cb);
            break :blk do_diff_async(from, cb_, cb_data, text_dst.text, text_src.text) catch |e| {
                cb_(from, cb_data, &.{});
                break :blk tp.exit_error(e, @errorReturnTrace());
            };
        } else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn do_diff_async(from: tp.pid_ref, cb: *AsyncDiffer.CallBack, cb_data: usize, text_dst: []const u8, text_src: []const u8) !void {
        var arena_ = std.heap.ArenaAllocator.init(allocator);
        defer arena_.deinit();
        const arena = arena_.allocator();

        const edits = try diff(arena, text_dst, text_src);
        cb(from, cb_data, edits);
    }
};

/// above this estimated cost a diff takes too long and there are no marks
const max_diff_cost = 400_000_000;

pub fn diff(allocator: std.mem.Allocator, dst: []const u8, src: []const u8) error{OutOfMemory}![]Diff {
    const frame = tracy.initZone(@src(), .{ .name = "diff" });
    defer frame.deinit();
    if ((try EditSet.estimate(allocator, src, dst)).cost() > max_diff_cost) return &.{};
    const blocks = EditSet.line_blocks(allocator, src, dst) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InputTooLarge => return &.{},
    };
    defer allocator.free(blocks);
    return EditSet.line_marks(allocator, blocks);
}
