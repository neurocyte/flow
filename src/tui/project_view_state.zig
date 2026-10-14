const std = @import("std");

const Self = @This();

allocator: std.mem.Allocator,
states: std.StringHashMapUnmanaged([]const u8) = .empty,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.states.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.states.deinit(self.allocator);
}

pub fn store(self: *Self, project: []const u8, state: []const u8) error{OutOfMemory}!void {
    errdefer self.allocator.free(state);
    if (self.states.fetchRemove(project)) |old| {
        self.allocator.free(old.key);
        self.allocator.free(old.value);
    }
    const key = try self.allocator.dupe(u8, project);
    errdefer self.allocator.free(key);
    try self.states.put(self.allocator, key, state);
}

pub fn get(self: *const Self, project: []const u8) ?[]const u8 {
    return self.states.get(project);
}
