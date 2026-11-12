const std = @import("std");
const tp = @import("thespian");
const root = @import("soft_root").root;

const Self = @This();
const module_name = @typeName(Self);

pid: ?tp.pid,

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const Selection = struct {
    begin: Cursor = Cursor{},
    end: Cursor = Cursor{},
};

pub fn create() error{ OutOfMemory, ThespianSpawnFailed }!Self {
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
    allocator: std.mem.Allocator,
    file_path_table: std.StringArrayHashMapUnmanaged(bool) = .empty,
    backwards: std.ArrayList(Entry) = .empty,
    current: ?Entry = null,
    forwards: std.ArrayList(Entry) = .empty,
    receiver: Receiver,

    const Receiver = tp.Receiver(*Process);
    const max_entries = 1000;

    const Entry = struct {
        file_path: []const u8,
        cursor: Cursor,
        selection: ?Selection = null,
    };

    pub fn create() error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
        const allocator = root.get_init().gpa;
        const self = try allocator.create(Process);
        self.* = .{
            .allocator = allocator,
            .receiver = .init(receive, dtor, self),
        };
        return tp.spawn_link(allocator, self, Process.start, module_name);
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn dtor(self: *Process) void {
        for (self.file_path_table.keys()) |file_path| self.allocator.free(file_path);
        self.file_path_table.deinit(self.allocator);
        self.backwards.deinit(self.allocator);
        self.forwards.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn intern(self: *Process, file_path: []const u8) ![]const u8 {
        if (self.current) |current| if (std.mem.eql(u8, current.file_path, file_path))
            return current.file_path;
        const result = try self.file_path_table.getOrPut(self.allocator, file_path);
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, file_path) catch |e| {
                self.file_path_table.swapRemoveAt(result.index);
                return e;
            };
            result.value_ptr.* = true;
        }
        return result.key_ptr.*;
    }

    fn trim(self: *Process) void {
        const len = self.backwards.items.len;
        if (len <= 2 * max_entries) return;
        std.mem.copyForwards(Entry, self.backwards.items[0..max_entries], self.backwards.items[len - max_entries ..]);
        self.backwards.shrinkRetainingCapacity(max_entries);
        self.collect_file_paths();
    }

    fn collect_file_paths(self: *Process) void {
        @memset(self.file_path_table.values(), false);
        if (self.current) |entry| self.mark_file_path(entry);
        for (self.backwards.items) |entry| self.mark_file_path(entry);
        for (self.forwards.items) |entry| self.mark_file_path(entry);
        var i = self.file_path_table.count();
        while (i > 0) {
            i -= 1;
            if (self.file_path_table.values()[i]) continue;
            const file_path = self.file_path_table.keys()[i];
            self.file_path_table.swapRemoveAt(i);
            self.allocator.free(file_path);
        }
    }

    fn mark_file_path(self: *Process, entry: Entry) void {
        if (self.file_path_table.getPtr(entry.file_path)) |used| used.* = true;
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *Process, from: tp.pid_ref, m: tp.message) !void {
        var c: Cursor = .{};
        var s: Selection = .{};
        var cb: usize = 0;
        var file_path: []const u8 = undefined;
        var in_file: ?[]const u8 = null;

        return if (try m.match(.{ "U", tp.extract(&file_path), tp.extract(&c.col), tp.extract(&c.row) }))
            self.update(.{ .file_path = file_path, .cursor = c })
        else if (try m.match(.{ "U", tp.extract(&file_path), tp.extract(&c.col), tp.extract(&c.row), tp.extract(&s.begin.row), tp.extract(&s.begin.col), tp.extract(&s.end.row), tp.extract(&s.end.col) }))
            self.update(.{ .file_path = file_path, .cursor = c, .selection = s })
        else if (try m.match(.{ "B", tp.extract(&in_file), tp.extract(&cb) }))
            self.back(from, in_file, cb)
        else if (try m.match(.{ "F", tp.extract(&in_file), tp.extract(&cb) }))
            self.forward(from, in_file, cb)
        else if (try m.match(.{"shutdown"}))
            tp.exit_normal();
    }

    fn update(self: *Process, entry_: Entry) !void {
        const entry: Entry = .{
            .file_path = try self.intern(entry_.file_path),
            .cursor = entry_.cursor,
            .selection = entry_.selection,
        };
        if (isdupe(self.current, entry)) {
            self.current = entry;
            return;
        }

        if (isdupe(self.backwards.getLastOrNull(), entry)) {
            if (self.current) |current| self.forwards.append(self.allocator, current) catch {};
            _ = self.backwards.pop();
            tp.trace(tp.channel.all, tp.message.fmt(.{ "location", "back", entry.file_path, entry.cursor.row, entry.cursor.col, self.backwards.items.len, self.forwards.items.len }));
        } else if (isdupe(self.forwards.getLastOrNull(), entry)) {
            if (self.current) |current| self.backwards.append(self.allocator, current) catch {};
            _ = self.forwards.pop();
            tp.trace(tp.channel.all, tp.message.fmt(.{ "location", "forward", entry.file_path, entry.cursor.row, entry.cursor.col, self.backwards.items.len, self.forwards.items.len }));
        } else if (self.current) |current| {
            try self.backwards.append(self.allocator, current);
            tp.trace(tp.channel.all, tp.message.fmt(.{ "location", "new", current.file_path, current.cursor.row, current.cursor.col, self.backwards.items.len, self.forwards.items.len }));
            self.forwards.clearRetainingCapacity();
        }
        self.current = entry;
        self.trim();
    }

    fn isdupe(a_: ?Entry, b: Entry) bool {
        return if (a_) |a| std.mem.eql(u8, a.file_path, b.file_path) and a.cursor.row == b.cursor.row else false;
    }

    fn back(self: *const Process, from: tp.pid_ref, in_file: ?[]const u8, cb_addr: usize) void {
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        var i = self.backwards.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.backwards.items[i];
            if (in_file == null or std.mem.eql(u8, entry.file_path, in_file.?)) {
                cb(from, entry.file_path, entry.cursor, entry.selection);
                break;
            }
        }
    }

    fn forward(self: *Process, from: tp.pid_ref, in_file: ?[]const u8, cb_addr: usize) void {
        const cb: *CallBack = if (cb_addr == 0) return else @ptrFromInt(cb_addr);
        var i = self.forwards.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.forwards.items[i];
            if (in_file == null or std.mem.eql(u8, entry.file_path, in_file.?)) {
                cb(from, entry.file_path, entry.cursor, entry.selection);
                break;
            }
        }
    }
};

pub fn update(self: Self, file_path: []const u8, cursor: Cursor, selection: ?Selection) void {
    if (self.pid) |pid| {
        if (selection) |sel|
            pid.send(.{ "U", file_path, cursor.col, cursor.row, sel.begin.row, sel.begin.col, sel.end.row, sel.end.col }) catch {}
        else
            pid.send(.{ "U", file_path, cursor.col, cursor.row }) catch {};
    }
}

pub const CallBack = fn (from: tp.pid_ref, file_path: []const u8, cursor: Cursor, selection: ?Selection) void;

pub fn back(self: Self, in_file: ?[]const u8, cb: *const CallBack) tp.result {
    if (self.pid) |pid| try pid.send(.{ "B", in_file, @intFromPtr(cb) });
}

pub fn forward(self: Self, in_file: ?[]const u8, cb: *const CallBack) tp.result {
    if (self.pid) |pid| try pid.send(.{ "F", in_file, @intFromPtr(cb) });
}
