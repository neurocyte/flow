const std = @import("std");
const tp = @import("thespian");
const dizzy = @import("dizzy");
const Buffer = @import("Buffer");
const tracy = @import("tracy");

const Self = @This();
const module_name = @typeName(Self);

pub const Kind = enum { insert, delete };
pub const Edit = struct {
    kind: Kind,
    line: usize,
    offset: usize,
    bytes: []const u8,
};

pid: ?tp.pid,

pub fn create() !Self {
    return .{ .pid = try Process.create() };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.send(.{"shutdown"}) catch {};
        pid.deinit();
        self.pid = null;
    }
}

const Process = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const outer_a = std.heap.page_allocator;

    pub fn create() !tp.pid {
        const self = try outer_a.create(Process);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(outer_a),
            .allocator = self.arena.allocator(),
            .receiver = Receiver.init(Process.receive, self),
        };
        return tp.spawn_link(self.allocator, self, Process.start, module_name);
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *Process) void {
        self.arena.deinit();
        outer_a.destroy(self);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        var cb: usize = 0;
        var root_dst: usize = 0;
        var root_src: usize = 0;

        return if (try m.match(.{ "D", tp.extract(&cb), tp.extract(&root_dst), tp.extract(&root_src) }))
            self.diff(from, cb, root_dst, root_src) catch |e| tp.exit_error(e, @errorReturnTrace())
        else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn diff(self: *Process, from: tp.pid_ref, cb_addr: usize, root_new_addr: usize, root_old_addr: usize) !void {
        const frame = tracy.initZone(@src(), .{ .name = "diff" });
        defer frame.deinit();
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        const root_dst: Buffer.Root = if (root_new_addr == 0) return else @ptrFromInt(root_new_addr);
        const root_src: Buffer.Root = if (root_old_addr == 0) return else @ptrFromInt(root_old_addr);

        var dizzy_edits = std.ArrayListUnmanaged(dizzy.Edit){};
        var dst = std.ArrayList(u8).init(self.allocator);
        var src = std.ArrayList(u8).init(self.allocator);
        var scratch = std.ArrayListUnmanaged(u32){};
        var edits = std.ArrayList(Edit).init(self.allocator);

        defer {
            dst.deinit();
            src.deinit();
            scratch.deinit(self.allocator);
            dizzy_edits.deinit(self.allocator);
        }

        try root_dst.store(dst.writer());
        try root_src.store(src.writer());

        const scratch_len = 4 * (dst.items.len + src.items.len) + 2;
        try scratch.ensureTotalCapacity(self.allocator, scratch_len);
        scratch.items.len = scratch_len;

        try dizzy.PrimitiveSliceDiffer(u8).diff(self.allocator, &dizzy_edits, src.items, dst.items, scratch.items);

        if (dizzy_edits.items.len > 2)
            try edits.ensureTotalCapacity((dizzy_edits.items.len - 1) / 2);

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
                    scan_char(src.items[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .insert => {
                    const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                    pos_src += 0;
                    pos_dst += dist;
                    const line_start_dst: usize = lines_dst;
                    scan_char(dst.items[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', null);
                    (try edits.addOne()).* = .{
                        .kind = .insert,
                        .line = line_start_dst,
                        .offset = last_offset,
                        .bytes = dst.items[dizzy_edit.range.start..dizzy_edit.range.end],
                    };
                },
                .delete => {
                    const dist = dizzy_edit.range.end - dizzy_edit.range.start;
                    pos_src += dist;
                    pos_dst += 0;
                    (try edits.addOne()).* = .{
                        .kind = .delete,
                        .line = lines_dst,
                        .offset = last_offset,
                        .bytes = src.items[dizzy_edit.range.start..dizzy_edit.range.end],
                    };
                },
            }
        }
        cb(from, edits.items);
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
};

pub const CallBack = fn (from: tp.pid_ref, edits: []Edit) void;

pub fn diff(self: Self, cb: *const CallBack, root_dst: Buffer.Root, root_src: Buffer.Root) tp.result {
    if (self.pid) |pid| try pid.send(.{ "D", @intFromPtr(cb), @intFromPtr(root_dst), @intFromPtr(root_src) });
}
