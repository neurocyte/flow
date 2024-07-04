const std = @import("std");
const cbor = @import("cbor");
const Buffer = @import("Buffer.zig");
const View = @import("View.zig");
const Selection = @import("Selection.zig");
const Metrix = Buffer.Metrix;

row: usize = 0,
col: usize = 0,
target: usize = 0,

const Self = @This();

pub inline fn invalid() Self {
    return .{
        .row = std.math.maxInt(u32),
        .col = std.math.maxInt(u32),
        .target = std.math.maxInt(u32),
    };
}

pub inline fn eql(self: Self, other: Self) bool {
    return self.row == other.row and self.col == other.col;
}

pub inline fn right_of(self: Self, other: Self) bool {
    return if (self.row > other.row) true else if (self.row == other.row and self.col > other.col) true else false;
}

pub fn clamp_to_buffer(self: *Self, root: Buffer.Root, mtrx: Metrix) void {
    self.row = @min(self.row, root.lines() - 1);
    self.col = @min(self.col, root.line_width(self.row, mtrx) catch 0);
}

fn follow_target(self: *Self, root: Buffer.Root, mtrx: Metrix) void {
    self.col = @min(self.target, root.line_width(self.row, mtrx) catch 0);
}

fn move_right_no_target(self: *Self, root: Buffer.Root, mtrx: Metrix) !void {
    const lines = root.lines();
    if (lines <= self.row) return error.Stop;
    if (self.col < root.line_width(self.row, mtrx) catch 0) {
        _, const wcwidth, const offset = root.ecg_at(self.row, self.col, mtrx) catch return error.Stop;
        self.col += wcwidth - offset;
    } else if (self.row < lines - 1) {
        self.col = 0;
        self.row += 1;
    } else return error.Stop;
}

pub fn move_right(self: *Self, root: Buffer.Root, mtrx: Metrix) !void {
    try self.move_right_no_target(root, mtrx);
    self.target = self.col;
}

fn move_left_no_target(self: *Self, root: Buffer.Root, mtrx: Metrix) !void {
    if (self.col == 0) {
        if (self.row == 0) return error.Stop;
        self.row -= 1;
        self.col = root.line_width(self.row, mtrx) catch 0;
    } else {
        _, const wcwidth, _ = root.ecg_at(self.row, self.col - 1, mtrx) catch return error.Stop;
        if (self.col > wcwidth) self.col -= wcwidth else self.col = 0;
    }
}

pub fn move_left(self: *Self, root: Buffer.Root, mtrx: Metrix) !void {
    try self.move_left_no_target(root, mtrx);
    self.target = self.col;
}

pub fn move_up(self: *Self, root: Buffer.Root, mtrx: Metrix) !void {
    if (self.row > 0) {
        self.row -= 1;
        self.follow_target(root, mtrx);
        self.move_left_no_target(root, mtrx) catch return;
        try self.move_right_no_target(root, mtrx);
    } else return error.Stop;
}

pub fn move_down(self: *Self, root: Buffer.Root, mtrx: Metrix) !void {
    if (self.row < root.lines() - 1) {
        self.row += 1;
        self.follow_target(root, mtrx);
        self.move_left_no_target(root, mtrx) catch return;
        try self.move_right_no_target(root, mtrx);
    } else return error.Stop;
}

pub fn move_page_up(self: *Self, root: Buffer.Root, view: *const View, mtrx: Metrix) void {
    self.row = if (self.row > view.rows) self.row - view.rows else 0;
    self.follow_target(root, mtrx);
    self.move_left_no_target(root, mtrx) catch return;
    self.move_right_no_target(root, mtrx) catch return;
}

pub fn move_page_down(self: *Self, root: Buffer.Root, view: *const View, mtrx: Metrix) void {
    if (root.lines() > self.row + view.rows) {
        self.row += view.rows;
    } else self.move_buffer_last(root, mtrx);
    self.follow_target(root, mtrx);
    self.move_left_no_target(root, mtrx) catch return;
    self.move_right_no_target(root, mtrx) catch return;
}

pub fn move_to(self: *Self, root: Buffer.Root, row: usize, col: usize, mtrx: Metrix) !void {
    if (row < root.lines()) {
        self.row = row;
        self.col = @min(col, root.line_width(self.row, mtrx) catch return error.Stop);
        self.target = self.col;
    } else return error.Stop;
}

pub fn move_abs(self: *Self, root: Buffer.Root, v: *View, y: usize, x: usize, mtrx: Metrix) !void {
    self.row = v.row + y;
    self.col = v.col + x;
    self.clamp_to_buffer(root, mtrx);
    self.target = self.col;
}

pub fn move_begin(self: *Self) void {
    self.col = 0;
    self.target = self.col;
}

pub fn move_end(self: *Self, root: Buffer.Root, mtrx: Metrix) void {
    if (self.row < root.lines()) self.col = root.line_width(self.row, mtrx) catch 0;
    self.target = std.math.maxInt(u32);
}

pub fn move_buffer_begin(self: *Self) void {
    self.row = 0;
    self.col = 0;
    self.target = 0;
}

pub fn move_buffer_end(self: *Self, root: Buffer.Root, mtrx: Metrix) void {
    self.row = root.lines() - 1;
    self.move_end(root, mtrx);
    if (self.col == 0) self.target = 0;
}

fn move_buffer_first(self: *Self, root: Buffer.Root, mtrx: Metrix) void {
    self.row = 0;
    self.follow_target(root, mtrx);
}

fn move_buffer_last(self: *Self, root: Buffer.Root, mtrx: Metrix) void {
    self.row = root.lines() - 1;
    self.follow_target(root, mtrx);
}

fn is_at_begin(self: *const Self) bool {
    return self.col == 0;
}

fn is_at_end(self: *const Self, root: Buffer.Root, mtrx: Metrix) bool {
    return if (self.row < root.lines()) self.col == root.line_width(self.row, mtrx) catch 0 else true;
}

pub fn test_at(self: *const Self, root: Buffer.Root, pred: *const fn (c: []const u8) bool, mtrx: Metrix) bool {
    return root.test_at(pred, self.row, self.col, mtrx);
}

pub fn write(self: *const Self, writer: Buffer.MetaWriter) !void {
    try cbor.writeValue(writer, .{
        self.row,
        self.col,
        self.target,
    });
}

pub fn extract(self: *Self, iter: *[]const u8) !bool {
    return cbor.matchValue(iter, .{
        cbor.extract(&self.row),
        cbor.extract(&self.col),
        cbor.extract(&self.target),
    });
}

pub fn nudge_insert(self: *Self, nudge: Selection) void {
    if (self.row < nudge.begin.row or (self.row == nudge.begin.row and self.col < nudge.begin.col)) return;

    const rows = nudge.end.row - nudge.begin.row;
    if (self.row == nudge.begin.row) {
        if (nudge.begin.row < nudge.end.row) {
            self.row += rows;
            self.col = self.col - nudge.begin.col + nudge.end.col;
        } else {
            self.col += nudge.end.col - nudge.begin.col;
        }
    } else {
        self.row += rows;
    }
}

pub fn nudge_delete(self: *Self, nudge: Selection) bool {
    if (self.row < nudge.begin.row or (self.row == nudge.begin.row and self.col < nudge.begin.col)) return true;
    if (self.row == nudge.begin.row) {
        if (nudge.begin.row < nudge.end.row) {
            return false;
        } else {
            if (self.col < nudge.end.col) {
                return false;
            }
            self.col -= nudge.end.col - nudge.begin.col;
            return true;
        }
    }
    if (self.row < nudge.end.row) return false;
    if (self.row == nudge.end.row) {
        if (self.col < nudge.end.col) return false;
        self.row -= nudge.end.row - nudge.begin.row;
        self.col -= nudge.end.col;
        return true;
    }
    self.row -= nudge.end.row - nudge.begin.row;
    return true;
}
