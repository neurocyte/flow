const cbor = @import("cbor");
const Writer = @import("std").Io.Writer;

const Buffer = @import("Buffer.zig");
const Cursor = @import("Cursor.zig");

begin: Cursor = Cursor{},
end: Cursor = Cursor{},

const Self = @This();

pub const Style = enum { normal, inclusive };

pub inline fn eql(self: Self, other: Self) bool {
    return self.begin.eql(other.begin) and self.end.eql(other.end);
}

pub fn from_cursor(cursor: *const Cursor) Self {
    return .{ .begin = cursor.*, .end = cursor.* };
}

pub fn from_pos(sel: Self, root: Buffer.Root, metrics: Buffer.Metrics) Self {
    return .{
        .begin = .{
            .row = sel.begin.row,
            .col = root.pos_to_width(sel.begin.row, sel.begin.col, metrics) catch root.line_width(sel.begin.row, metrics) catch 0,
        },
        .end = .{
            .row = sel.end.row,
            .col = root.pos_to_width(sel.end.row, sel.end.col, metrics) catch root.line_width(sel.end.row, metrics) catch 0,
        },
    };
}

pub fn line_from_cursor(cursor: Cursor, root: Buffer.Root, mtrx: Buffer.Metrics) Self {
    var begin = cursor;
    var end = cursor;
    begin.move_begin();
    end.move_end(root, mtrx);
    end.move_right(root, mtrx) catch {};
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

pub inline fn is_reversed(self: *const Self) bool {
    return self.begin.right_of(self.end);
}

pub fn normalize(self: *Self) void {
    if (self.is_reversed()) self.reverse();
}

pub fn write(self: *const Self, writer: *Writer) !void {
    try cbor.writeArrayHeader(writer, 2);
    try self.begin.write(writer);
    try self.end.write(writer);
}

pub fn extract(self: *Self, iter: *[]const u8) !bool {
    var iter2 = iter.*;
    const len = cbor.decodeArrayHeader(&iter2) catch return false;
    if (len != 2) return false;
    if (!try self.begin.extract(&iter2)) return false;
    if (!try self.end.extract(&iter2)) return false;
    iter.* = iter2;
    return true;
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

pub fn merge(self: *Self, other_: Self) bool {
    var other = other_;
    other.normalize();
    if (self.is_reversed()) {
        var this = self.*;
        this.normalize();
        if (this.merge_normal(other)) {
            self.begin = this.end;
            self.end = this.begin;
            return true;
        }
        return false;
    }
    return self.merge_normal(other);
}

fn merge_normal(self: *Self, other: Self) bool {
    var merged = false;
    if (self.begin.within(other)) {
        self.begin = other.begin;
        merged = true;
    }
    if (self.end.within(other)) {
        self.end = other.end;
        merged = true;
    }
    return merged or
        (other.begin.right_of(self.begin) and
            self.end.right_of(other.end));
}

pub fn expand(self: *Self, other_: Self) void {
    var other = other_;
    other.normalize();
    if (self.is_reversed()) {
        var this = self.*;
        this.normalize();
        this.expand_normal(other);
        self.begin = this.end;
        self.end = this.begin;
    } else self.expand_normal(other);
}

fn expand_normal(self: *Self, other: Self) void {
    if (self.begin.right_of(other.begin))
        self.begin = other.begin;
    if (other.end.right_of(self.end))
        self.end = other.end;
}
