const std = @import("std");
const tp = @import("thespian");

const Self = @This();

pub const State = enum { xon, xoff };

allocator: std.mem.Allocator,
queue: std.ArrayListUnmanaged([]u8) = .empty,
state: State = .xoff,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.queue.items) |m| self.allocator.free(m);
    self.queue.deinit(self.allocator);
}

pub fn pending(self: *const Self) usize {
    return self.queue.items.len;
}

pub fn post(self: *Self, m: anytype) error{ OutOfMemory, NoSpaceLeft, Exit }!void {
    var buf: [tp.max_message_size]u8 = undefined;
    const msg = try tp.message.fmtbuf(&buf, m);
    return self.post_raw(msg);
}

pub fn post_raw(self: *Self, msg: tp.message) error{ OutOfMemory, Exit }!void {
    return switch (self.state) {
        .xon => tp.self_pid().send_raw(msg),
        .xoff => self.queue.append(self.allocator, try self.allocator.dupe(u8, msg.buf)),
    };
}

pub fn set(self: *Self, state: State) tp.result {
    self.state = state;
    return switch (state) {
        .xon => self.flush(),
        .xoff => {},
    };
}

pub fn flush(self: *Self) tp.result {
    for (self.queue.items) |m| {
        try tp.self_pid().send_raw(.{ .buf = m });
        self.allocator.free(m);
    }
    self.queue.clearRetainingCapacity();
}
