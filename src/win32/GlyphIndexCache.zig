const GlyphIndexCache = @This();
const std = @import("std");

const Node = struct {
    prev: ?u32,
    next: ?u32,
    codepoint: ?u21,
};

map: std.AutoHashMapUnmanaged(u21, u32) = .{},
nodes: []Node,
front: u32,
back: u32,

pub fn init(allocator: std.mem.Allocator, capacity: u32) error{OutOfMemory}!GlyphIndexCache {
    var result: GlyphIndexCache = .{
        .map = .{},
        .nodes = try allocator.alloc(Node, capacity),
        .front = undefined,
        .back = undefined,
    };
    result.clearRetainingCapacity();
    return result;
}

pub fn clearRetainingCapacity(self: *GlyphIndexCache) void {
    self.map.clearRetainingCapacity();
    self.nodes[0] = .{ .prev = null, .next = 1, .codepoint = null };
    self.nodes[self.nodes.len - 1] = .{ .prev = @intCast(self.nodes.len - 2), .next = null, .codepoint = null };
    for (self.nodes[1 .. self.nodes.len - 1], 1..) |*node, index| {
        node.* = .{
            .prev = @intCast(index - 1),
            .next = @intCast(index + 1),
            .codepoint = null,
        };
    }
    self.front = 0;
    self.back = @intCast(self.nodes.len - 1);
}

pub fn deinit(self: *GlyphIndexCache, allocator: std.mem.Allocator) void {
    allocator.free(self.nodes);
    self.map.deinit(allocator);
}

pub fn isFull(self: *const GlyphIndexCache) bool {
    return self.map.count() == self.nodes.len;
}

const Reserved = struct {
    index: u32,
    replaced: ?u21,
};
pub fn reserve(self: *GlyphIndexCache, allocator: std.mem.Allocator, codepoint: u21) error{OutOfMemory}!union(enum) {
    newly_reserved: Reserved,
    already_reserved: u32,
} {
    {
        const entry = try self.map.getOrPut(allocator, codepoint);
        if (entry.found_existing) {
            self.moveToBack(entry.value_ptr.*);
            return .{ .already_reserved = entry.value_ptr.* };
        }
        entry.value_ptr.* = self.front;
    }

    std.debug.assert(self.nodes[self.front].prev == null);
    std.debug.assert(self.nodes[self.front].next != null);
    const replaced = self.nodes[self.front].codepoint;
    self.nodes[self.front].codepoint = codepoint;
    if (replaced) |r| {
        const removed = self.map.remove(r);
        std.debug.assert(removed);
    }
    const save_front = self.front;
    self.moveToBack(self.front);
    return .{ .newly_reserved = .{ .index = save_front, .replaced = replaced } };
}

fn moveToBack(self: *GlyphIndexCache, index: u32) void {
    if (index == self.back) return;

    const node = &self.nodes[index];
    if (node.prev) |prev| {
        self.nodes[prev].next = node.next;
    } else {
        self.front = node.next.?;
    }

    if (node.next) |next| {
        self.nodes[next].prev = node.prev;
    }

    self.nodes[self.back].next = index;
    node.prev = self.back;
    node.next = null;
    self.back = index;
}

fn testValidate(self: *const GlyphIndexCache, seen: []bool) !void {
    for (seen) |*s| {
        s.* = false;
    }
    try std.testing.expectEqual(null, self.nodes[self.front].prev);
    try std.testing.expect(self.nodes[self.front].next != null);
    seen[self.front] = true;
    try std.testing.expectEqual(null, self.nodes[self.back].next);
    try std.testing.expect(self.nodes[self.back].prev != null);
    seen[self.back] = true;

    var index = self.nodes[self.front].next.?;
    var count: u32 = 1;
    while (index != self.back) : ({
        count += 1;
        index = self.nodes[index].next orelse break;
    }) {
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        const node = &self.nodes[index];
        try std.testing.expect(node.prev != null);
        try std.testing.expect(node.next != null);
        try std.testing.expectEqual(index, self.nodes[node.prev.?].next.?);
        try std.testing.expectEqual(index, self.nodes[node.next.?].prev.?);
    }
    try std.testing.expectEqual(self.nodes.len - 1, count);
    for (seen) |s| {
        try std.testing.expect(s);
    }
}

test "GlyphIndexCache" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validation_buf: [3]bool = undefined;
    var cache = try GlyphIndexCache.init(allocator, 3);
    defer cache.deinit(allocator);

    try cache.testValidate(&validation_buf);

    switch (try cache.reserve(allocator, 'A')) {
        .newly_reserved => |reserved| {
            try cache.testValidate(&validation_buf);
            try testing.expectEqual(0, reserved.index);
            try testing.expectEqual(null, reserved.replaced);
            try testing.expectEqual(reserved.index, cache.back);
            try testing.expect(!cache.isFull());
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try cache.reserve(allocator, 'A')) {
        .already_reserved => |index| {
            try cache.testValidate(&validation_buf);
            try testing.expectEqual(0, index);
            try testing.expectEqual(index, cache.back);
            try testing.expect(!cache.isFull());
        },
        else => return error.TestUnexpectedResult,
    }

    switch (try cache.reserve(allocator, 'B')) {
        .newly_reserved => |reserved| {
            try cache.testValidate(&validation_buf);
            try testing.expectEqual(1, reserved.index);
            try testing.expectEqual(null, reserved.replaced);
            try testing.expectEqual(reserved.index, cache.back);
            try testing.expect(!cache.isFull());
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try cache.reserve(allocator, 'A')) {
        .already_reserved => |index| {
            try cache.testValidate(&validation_buf);
            try testing.expectEqual(0, index);
            try testing.expectEqual(index, cache.back);
            try testing.expectEqual(2, cache.front);
            try testing.expect(!cache.isFull());
        },
        else => return error.TestUnexpectedResult,
    }

    for (0..6) |run| {
        const index: u32 = @intCast(run % 2);
        cache.moveToBack(index);
        try cache.testValidate(&validation_buf);
        try testing.expectEqual(index, cache.back);
        try testing.expectEqual(2, cache.front);
        try testing.expect(!cache.isFull());
    }

    switch (try cache.reserve(allocator, 'C')) {
        .newly_reserved => |reserved| {
            try cache.testValidate(&validation_buf);
            try testing.expectEqual(2, reserved.index);
            try testing.expectEqual(null, reserved.replaced);
            try testing.expectEqual(reserved.index, cache.back);
            try testing.expect(cache.isFull());
        },
        else => return error.TestUnexpectedResult,
    }

    for (0..10) |run| {
        const index: u32 = @intCast(run % 3);
        cache.moveToBack(index);
        try cache.testValidate(&validation_buf);
        try testing.expectEqual(index, cache.back);
        try testing.expect(cache.isFull());
    }

    {
        const expected_index = cache.front;
        const expected_replaced = cache.nodes[cache.front].codepoint.?;
        switch (try cache.reserve(allocator, 'D')) {
            .newly_reserved => |reserved| {
                try cache.testValidate(&validation_buf);
                try testing.expectEqual(expected_index, reserved.index);
                try testing.expectEqual(expected_replaced, reserved.replaced.?);
                try testing.expectEqual(reserved.index, cache.back);
                try testing.expect(cache.isFull());
            },
            else => return error.TestUnexpectedResult,
        }
    }
}
