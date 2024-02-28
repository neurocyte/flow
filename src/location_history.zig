const std = @import("std");
const tp = @import("thespian");

const Self = @This();
const module_name = @typeName(Self);
pub const Error = error{ OutOfMemory, Exit };

pid: ?tp.pid,

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const Selection = struct {
    begin: Cursor = Cursor{},
    end: Cursor = Cursor{},
};

pub fn create() Error!Self {
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
    a: std.mem.Allocator,
    pos: usize = 0,
    records: std.ArrayList(Entry),
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const outer_a = std.heap.page_allocator;

    const Entry = struct {
        cursor: Cursor,
        selection: ?Selection = null,
    };

    pub fn create() Error!tp.pid {
        const self = try outer_a.create(Process);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(outer_a),
            .a = self.arena.allocator(),
            .records = std.ArrayList(Entry).init(self.a),
            .receiver = Receiver.init(Process.receive, self),
        };
        return tp.spawn_link(self.a, self, Process.start, module_name) catch |e| tp.exit_error(e);
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *Process) void {
        self.records.deinit();
        self.arena.deinit();
        outer_a.destroy(self);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        var c: Cursor = .{};
        var s: Selection = .{};
        var cb: usize = 0;

        return if (try m.match(.{ "A", tp.extract(&c.col), tp.extract(&c.row) }))
            self.add(.{ .cursor = c })
        else if (try m.match(.{ "A", tp.extract(&c.col), tp.extract(&c.row), tp.extract(&s.begin.row), tp.extract(&s.begin.col), tp.extract(&s.end.row), tp.extract(&s.end.col) }))
            self.add(.{ .cursor = c, .selection = s })
        else if (try m.match(.{ "B", tp.extract(&cb) }))
            self.back(from, cb)
        else if (try m.match(.{ "F", tp.extract(&cb) }))
            self.forward(from, cb)
        else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn add(self: *Process, entry: Entry) tp.result {
        if (self.records.items.len == 0)
            return self.records.append(entry) catch |e| tp.exit_error(e);

        if (entry.cursor.row == self.records.items[self.pos].cursor.row) {
            self.records.items[self.pos] = entry;
            return;
        }

        if (self.records.items.len > self.pos + 1) {
            if (entry.cursor.row == self.records.items[self.pos + 1].cursor.row)
                return;
        }

        if (self.pos > 0) {
            if (entry.cursor.row == self.records.items[self.pos - 1].cursor.row)
                return;
        }

        self.records.append(entry) catch |e| return tp.exit_error(e);
        self.pos = self.records.items.len - 1;
    }

    fn back(self: *Process, from: tp.pid_ref, cb_addr: usize) void {
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        if (self.pos == 0)
            return;
        self.pos -= 1;
        const entry = self.records.items[self.pos];
        cb(from, entry.cursor, entry.selection);
    }

    fn forward(self: *Process, from: tp.pid_ref, cb_addr: usize) void {
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        if (self.pos == self.records.items.len - 1)
            return;
        self.pos += 1;
        const entry = self.records.items[self.pos];
        cb(from, entry.cursor, entry.selection);
    }
};

pub fn add(self: Self, cursor: Cursor, selection: ?Selection) void {
    if (self.pid) |pid| {
        if (selection) |sel|
            pid.send(.{ "A", cursor.col, cursor.row, sel.begin.row, sel.begin.col, sel.end.row, sel.end.col }) catch {}
        else
            pid.send(.{ "A", cursor.col, cursor.row }) catch {};
    }
}

pub const CallBack = fn (from: tp.pid_ref, cursor: Cursor, selection: ?Selection) void;

pub fn back(self: Self, cb: *const CallBack) tp.result {
    if (self.pid) |pid| try pid.send(.{ "B", @intFromPtr(cb) });
}

pub fn forward(self: Self, cb: *const CallBack) tp.result {
    if (self.pid) |pid| try pid.send(.{ "F", @intFromPtr(cb) });
}
