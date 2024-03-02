const std = @import("std");
const Buffer = @import("Buffer.zig");
const Cursor = @import("Cursor.zig");

begin: Cursor = Cursor{},
end: Cursor = Cursor{},

const Self = @This();

pub inline fn eql(self: Self, other: Self) bool {
    return self.begin.eql(other.begin) and self.end.eql(other.end);
}

pub fn from_cursor(cursor: *const Cursor) Self {
    return .{ .begin = cursor.*, .end = cursor.* };
}

pub fn line_from_cursor(cursor: Cursor, root: Buffer.Root) Self {
    var begin = cursor;
    var end = cursor;
    begin.move_begin();
    end.move_end(root);
    end.move_right(root) catch {};
    return .{ .begin = begin, .end = end };
}

pub fn empty(self: *const Self) bool {
    return self.begin.eql(self.end);
}

pub fn reverse(self: *Self) void {
    const tmp = self.begin;
    self.begin = self.end;
    self.end = tmp;
}

pub fn normalize(self: *Self) void {
    if (self.begin.right_of(self.end))
        self.reverse();
}

pub fn write(self: *const Self, writer: Buffer.MetaWriter) !void {
    try self.begin.write(writer);
    try self.end.write(writer);
}

pub fn extract(self: *Self, iter: *[]const u8) !bool {
    if (!try self.begin.extract(iter)) return false;
    return self.end.extract(iter);
}

pub fn nudge_insert(self: *Self, nudge: Self) void {
    self.begin.nudge_insert(nudge);
    self.end.nudge_insert(nudge);
}

pub fn nudge_delete(self: *Self, nudge: Self) bool {
    if (!self.begin.nudge_delete(nudge))
        return false;
    return self.end.nudge_delete(nudge);
}
