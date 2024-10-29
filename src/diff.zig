const std = @import("std");
const tp = @import("thespian");
const dizzy = @import("dizzy");
const Buffer = @import("Buffer");
const tracy = @import("tracy");

const module_name = @typeName(@This());

pub const Kind = enum { insert, delete };
pub const Diff = struct {
    kind: Kind,
    line: usize,
    offset: usize,
    start: usize,
    end: usize,
    bytes: []const u8,
};

pub const Edit = struct {
    kind: Kind,
    start: usize,
    end: usize,
    bytes: []const u8,
};

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

    pub const CallBack = fn (from: tp.pid_ref, edits: []Diff) void;

    pub fn diff(self: @This(), cb: *const CallBack, root_dst: Buffer.Root, root_src: Buffer.Root, eol_mode: Buffer.EolMode) tp.result {
        if (self.pid) |pid| try pid.send(.{ "D", @intFromPtr(cb), @intFromPtr(root_dst), @intFromPtr(root_src), @intFromEnum(eol_mode) });
    }
};

const Process = struct {
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const allocator = std.heap.c_allocator;

    pub fn create() !tp.pid {
        const self = try allocator.create(Process);
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
        var root_dst: usize = 0;
        var root_src: usize = 0;
        var eol_mode: Buffer.EolModeTag = @intFromEnum(Buffer.EolMode.lf);

        return if (try m.match(.{ "D", tp.extract(&cb), tp.extract(&root_dst), tp.extract(&root_src), tp.extract(&eol_mode) }))
            do_diff_async(from, cb, root_dst, root_src, @enumFromInt(eol_mode)) catch |e| tp.exit_error(e, @errorReturnTrace())
        else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn do_diff_async(from_: tp.pid_ref, cb_addr: usize, root_dst_addr: usize, root_src_addr: usize, eol_mode: Buffer.EolMode) !void {
        const cb_: *AsyncDiffer.CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        const root_dst: Buffer.Root = if (root_dst_addr == 0) return else @ptrFromInt(root_dst_addr);
        const root_src: Buffer.Root = if (root_src_addr == 0) return else @ptrFromInt(root_src_addr);

        var arena_ = std.heap.ArenaAllocator.init(allocator);
        defer arena_.deinit();
        const arena = arena_.allocator();

        var dst = std.ArrayList(u8).init(arena);
        var src = std.ArrayList(u8).init(arena);
        try root_dst.store(dst.writer(), eol_mode);
        try root_src.store(src.writer(), eol_mode);

        const edits = try diff(arena, dst.items, src.items);
        cb_(from_, edits);
    }
};

pub fn diff(allocator: std.mem.Allocator, dst: []const u8, src: []const u8) ![]Diff {
    var arena_ = std.heap.ArenaAllocator.init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();
    const frame = tracy.initZone(@src(), .{ .name = "diff" });
    defer frame.deinit();

    var dizzy_edits = std.ArrayListUnmanaged(dizzy.Edit){};
    var scratch = std.ArrayListUnmanaged(u32){};
    var diffs = std.ArrayList(Diff).init(allocator);

    const scratch_len = 4 * (dst.len + src.len) + 2;
    try scratch.ensureTotalCapacity(arena, scratch_len);
    scratch.items.len = scratch_len;

    try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, src, dst, scratch.items);

    if (dizzy_edits.items.len > 2)
        try diffs.ensureTotalCapacity((dizzy_edits.items.len - 1) / 2);

    var lines_dst: usize = 0;
    var pos_src: usize = 0;
    var pos_dst: usize = 0;
    var last_offset: usize = 0;

    for (dizzy_edits.items) |dizzy_edit| {
        switch (dizzy_edit.kind) {
            .equal => {
                const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                pos_src += dist;
                pos_dst += dist;
                scan_char(src[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
            },
            .insert => {
                const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                pos_src += 0;
                pos_dst += dist;
                const line_start_dst: usize = lines_dst;
                scan_char(dst[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', null);
                (try diffs.addOne()).* = .{
                    .kind = .insert,
                    .line = line_start_dst,
                    .offset = last_offset,
                    .start = dizzy_edit.range.start,
                    .end = dizzy_edit.range.end,
                    .bytes = dst[dizzy_edit.range.start..dizzy_edit.range.end],
                };
            },
            .delete => {
                const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                pos_src += dist;
                pos_dst += 0;
                (try diffs.addOne()).* = .{
                    .kind = .delete,
                    .line = lines_dst,
                    .offset = last_offset,
                    .start = dizzy_edit.range.start,
                    .end = dizzy_edit.range.end,
                    .bytes = src[dizzy_edit.range.start..dizzy_edit.range.end],
                };
            },
        }
    }
    return diffs.toOwnedSlice();
}

pub fn get_edits(allocator: std.mem.Allocator, dst: []const u8, src: []const u8) ![]Edit {
    var arena_ = std.heap.ArenaAllocator.init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();
    const frame = tracy.initZone(@src(), .{ .name = "diff" });
    defer frame.deinit();

    var dizzy_edits = std.ArrayListUnmanaged(dizzy.Edit){};
    var scratch = std.ArrayListUnmanaged(u32){};
    var edits = std.ArrayList(Edit).init(allocator);

    const scratch_len = 4 * (dst.len + src.len) + 2;
    try scratch.ensureTotalCapacity(arena, scratch_len);
    scratch.items.len = scratch_len;

    try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, src, dst, scratch.items);

    if (dizzy_edits.items.len > 2)
        try edits.ensureTotalCapacity((dizzy_edits.items.len - 1) / 2);

    var pos: usize = 0;

    for (dizzy_edits.items) |dizzy_edit| {
        switch (dizzy_edit.kind) {
            .equal => {
                const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                pos += dist;
            },
            .insert => {
                (try edits.addOne()).* = .{
                    .kind = .insert,
                    .start = pos,
                    .end = pos,
                    .bytes = dst[dizzy_edit.range.start..dizzy_edit.range.end],
                };
                const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                pos += dist;
            },
            .delete => {
                const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                pos += 0;
                (try edits.addOne()).* = .{
                    .kind = .delete,
                    .start = pos,
                    .end = pos + dist,
                    .bytes = "",
                };
            },
        }
    }
    return edits.toOwnedSlice();
}

fn scan_char(chars: []const u8, lines: *usize, char: u8, last_offset: ?*usize) void {
    var pos = chars;
    while (pos.len > 0) {
        if (pos[0] == char) {
            if (last_offset) |off| off.* = pos.len - 1;
            lines.* += 1;
        }
        pos = pos[1..];
    }
}

pub fn assert_edits_valid(allocator: std.mem.Allocator, dst: []const u8, src: []const u8, edits: []Edit) void {
    const frame = tracy.initZone(@src(), .{ .name = "diff validate" });
    defer frame.deinit();
    var result = std.ArrayListUnmanaged(u8){};
    var tmp = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);
    defer tmp.deinit(allocator);
    result.appendSlice(allocator, src) catch @panic("assert_edits_valid OOM");

    for (edits) |edit| {
        tmp.clearRetainingCapacity();
        tmp.appendSlice(allocator, result.items[0..edit.start]) catch @panic("assert_edits_valid OOM");
        tmp.appendSlice(allocator, edit.bytes) catch @panic("assert_edits_valid OOM");
        tmp.appendSlice(allocator, result.items[edit.end..]) catch @panic("assert_edits_valid OOM");
        result.clearRetainingCapacity();
        result.appendSlice(allocator, tmp.items) catch @panic("assert_edits_valid OOM");
    }

    if (!std.mem.eql(u8, dst, result.items)) {
        write_file(src, "bad_diff_src") catch @panic("invalid edits write failed");
        write_file(dst, "bad_diff_dst") catch @panic("invalid edits write failed");
        write_file(result.items, "bad_diff_result") catch @panic("invalid edits write failed");
        @panic("invalid edits");
    }
}

fn write_file(data: []const u8, file_name: []const u8) !void {
    var file = try std.fs.cwd().createFile(file_name, .{ .truncate = true });
    defer file.close();
    return file.writeAll(data);
}
