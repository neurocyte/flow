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
        const allocator = std.heap.c_allocator;
        const eol_mode = buffer.file_eol_mode;
        const text_dst = allocator.dupe(u8, buffer.store_to_string_cached(buffer.root, eol_mode)) catch |e| return tp.exit_error(e, @errorReturnTrace());
        errdefer allocator.free(text_dst);
        const text_src = allocator.dupe(
            u8,
            if (buffer.get_vcs_content()) |vcs_content|
                vcs_content
            else
                buffer.store_last_save_to_string_cached(eol_mode) orelse return,
        ) catch |e| return tp.exit_error(e, @errorReturnTrace());
        errdefer allocator.free(text_src);
        const text_dst_ptr: usize = if (text_dst.len > 0) @intFromPtr(text_dst.ptr) else 0;
        const text_src_ptr: usize = if (text_src.len > 0) @intFromPtr(text_src.ptr) else 0;
        if (self.pid) |pid| try pid.send(.{ "D", @intFromPtr(cb), cb_data, text_dst_ptr, text_dst.len, text_src_ptr, text_src.len });
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
        var text_dst_len: usize = 0;
        var text_src_ptr: usize = 0;
        var text_src_len: usize = 0;

        return if (try m.match(.{ "D", tp.extract(&cb), tp.extract(&cb_data), tp.extract(&text_dst_ptr), tp.extract(&text_dst_len), tp.extract(&text_src_ptr), tp.extract(&text_src_len) })) blk: {
            const text_dst = if (text_dst_len > 0) @as([*]const u8, @ptrFromInt(text_dst_ptr))[0..text_dst_len] else "";
            const text_src = if (text_src_len > 0) @as([*]const u8, @ptrFromInt(text_src_ptr))[0..text_src_len] else "";
            const cb_: *AsyncDiffer.CallBack = if (cb == 0) return else @ptrFromInt(cb);
            break :blk do_diff_async(from, cb_, cb_data, text_dst, text_src) catch |e| {
                cb_(from, cb_data, &.{});
                break :blk tp.exit_error(e, @errorReturnTrace());
            };
        } else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn do_diff_async(from: tp.pid_ref, cb: *AsyncDiffer.CallBack, cb_data: usize, text_dst: []const u8, text_src: []const u8) !void {
        defer std.heap.c_allocator.free(text_dst);
        defer std.heap.c_allocator.free(text_src);

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
