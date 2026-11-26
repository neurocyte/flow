const std = @import("std");
const cbor = @import("cbor");

const Allocator = std.mem.Allocator;
const Self = @This();

pub const max_entries = 100;

pub const View = union(enum) {
    preview: []const u8,
    panel: u32,

    fn eql(a: View, b: View) bool {
        return switch (a) {
            .preview => |path| b == .preview and std.mem.eql(u8, path, b.preview),
            .panel => |id| b == .panel and id == b.panel,
        };
    }
};

pub const Entry = struct {
    view: View,
    row: usize = 0,
    offset: isize = 0,

    fn dupe(self: Entry, allocator: Allocator) error{OutOfMemory}!Entry {
        var result = self;
        if (self.view == .preview) result.view = .{ .preview = try allocator.dupe(u8, self.view.preview) };
        return result;
    }

    pub fn deinit(self: Entry, allocator: Allocator) void {
        if (self.view == .preview) allocator.free(self.view.preview);
    }

    fn same_place(a: Entry, b: Entry) bool {
        return a.view.eql(b.view) and a.row == b.row;
    }
};

pub const Direction = enum { back, forward };

allocator: Allocator,
back: std.ArrayList(Entry) = .empty,
forward: std.ArrayList(Entry) = .empty,

pub fn init(allocator: Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.reset();
    self.back.deinit(self.allocator);
    self.forward.deinit(self.allocator);
}

pub fn reset(self: *Self) void {
    clear_list(self.allocator, &self.back);
    clear_list(self.allocator, &self.forward);
}

pub fn record(self: *Self, from: Entry) error{OutOfMemory}!void {
    try push(self.allocator, &self.back, from);
    clear_list(self.allocator, &self.forward);
}

pub fn jump(self: *Self, direction: Direction, current: Entry, context: anytype, comptime exists: fn (@TypeOf(context), View) bool) error{OutOfMemory}!?Entry {
    const from, const to = switch (direction) {
        .back => .{ &self.back, &self.forward },
        .forward => .{ &self.forward, &self.back },
    };
    while (from.pop()) |target| {
        if (target.same_place(current) or !exists(context, target.view)) {
            target.deinit(self.allocator);
            continue;
        }
        errdefer target.deinit(self.allocator);
        try push(self.allocator, to, current);
        return target;
    }
    return null;
}

pub fn remove_panel(self: *Self, id: u32) void {
    remove_where(self.allocator, &self.back, id);
    remove_where(self.allocator, &self.forward, id);
}

pub fn remove_panels(self: *Self) void {
    remove_where(self.allocator, &self.back, null);
    remove_where(self.allocator, &self.forward, null);
}

pub fn write_state(self: *const Self, writer: *std.Io.Writer) error{WriteFailed}!void {
    try cbor.writeArrayHeader(writer, 2);
    try write_list(writer, self.back.items);
    try write_list(writer, self.forward.items);
}

pub fn extract_state(self: *Self, iter: *[]const u8) !void {
    self.reset();
    errdefer self.reset();
    if (try cbor.decodeArrayHeader(iter) < 2) return error.InvalidInfoHistoryState;
    try self.extract_list(iter, &self.back);
    try self.extract_list(iter, &self.forward);
}

fn write_list(writer: *std.Io.Writer, entries: []const Entry) error{WriteFailed}!void {
    var n: usize = 0;
    for (entries) |entry| if (entry.view == .preview) {
        n += 1;
    };
    try cbor.writeArrayHeader(writer, n);
    for (entries) |entry| if (entry.view == .preview)
        try cbor.writeValue(writer, .{ entry.view.preview, entry.row, entry.offset });
}

fn extract_list(self: *Self, iter: *[]const u8, list: *std.ArrayList(Entry)) !void {
    var n = try cbor.decodeArrayHeader(iter);
    while (n > 0) : (n -= 1) {
        var source: []const u8 = undefined;
        var row: usize = 0;
        var offset: isize = 0;
        if (!try cbor.matchValue(iter, .{ cbor.extract(&source), cbor.extract(&row), cbor.extract(&offset) }))
            return error.InvalidInfoHistoryState;
        try push(self.allocator, list, .{ .view = .{ .preview = source }, .row = row, .offset = offset });
    }
}

fn push(allocator: Allocator, list: *std.ArrayList(Entry), entry: Entry) error{OutOfMemory}!void {
    if (list.items.len > 0 and list.items[list.items.len - 1].same_place(entry)) {
        list.items[list.items.len - 1].offset = entry.offset;
        return;
    }
    const owned = try entry.dupe(allocator);
    errdefer owned.deinit(allocator);
    if (list.items.len >= max_entries) list.orderedRemove(0).deinit(allocator);
    try list.append(allocator, owned);
}

fn clear_list(allocator: Allocator, list: *std.ArrayList(Entry)) void {
    for (list.items) |entry| entry.deinit(allocator);
    list.clearRetainingCapacity();
}

fn remove_where(allocator: Allocator, list: *std.ArrayList(Entry), id: ?u32) void {
    var i: usize = 0;
    while (i < list.items.len) {
        const entry = list.items[i];
        if (entry.view == .panel and (id == null or entry.view.panel == id.?)) {
            entry.deinit(allocator);
            _ = list.orderedRemove(i);
        } else i += 1;
    }
}
