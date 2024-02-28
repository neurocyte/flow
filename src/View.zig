const std = @import("std");
const cbor = @import("cbor");
const Buffer = @import("Buffer.zig");
const Cursor = @import("Cursor.zig");
const Selection = @import("Selection.zig");

row: usize = 0,
col: usize = 0,
rows: usize = 0,
cols: usize = 0,

const scroll_cursor_min_border_distance = 5;
const scroll_cursor_min_border_distance_mouse = 1;

const Self = @This();

pub inline fn invalid() Self {
    return .{
        .row = std.math.maxInt(u32),
        .col = std.math.maxInt(u32),
    };
}

inline fn reset(self: *Self) void {
    self.* = .{};
}

pub inline fn eql(self: Self, other: Self) bool {
    return self.row == other.row and self.col == other.col and self.rows == other.rows and self.cols == other.cols;
}

pub fn move_left(self: *Self) !void {
    if (self.col > 0) {
        self.col -= 1;
    } else return error.Stop;
}

pub fn move_right(self: *Self) !void {
    self.col += 1;
}

pub fn move_up(self: *Self) !void {
    if (!self.is_at_top()) {
        self.row -= 1;
    } else return error.Stop;
}

pub fn move_down(self: *Self, root: Buffer.Root) !void {
    if (!self.is_at_bottom(root)) {
        self.row += 1;
    } else return error.Stop;
}

pub fn move_to(self: *Self, root: Buffer.Root, row: usize) !void {
    if (row < root.lines() - self.rows - 1) {
        self.row = row;
    } else return error.Stop;
}

inline fn is_at_top(self: *const Self) bool {
    return self.row == 0;
}

inline fn is_at_bottom(self: *const Self, root: Buffer.Root) bool {
    if (root.lines() < self.rows) return true;
    return self.row >= root.lines() - scroll_cursor_min_border_distance;
}

pub inline fn is_visible(self: *const Self, cursor: *const Cursor) bool {
    const row_min = self.row;
    const row_max = row_min + self.rows;
    const col_min = self.col;
    const col_max = col_min + self.cols;
    return row_min <= cursor.row and cursor.row <= row_max and
        col_min <= cursor.col and cursor.col < col_max;
}

inline fn is_visible_selection(self: *const Self, sel: *const Selection) bool {
    const row_min = self.row;
    const row_max = row_min + self.rows;
    return self.is_visible(sel.begin) or is_visible(sel.end) or
        (sel.begin.row < row_min and sel.end.row > row_max);
}

inline fn to_cursor_top(self: *const Self) Cursor {
    return .{ .row = self.row, .col = 0 };
}

inline fn to_cursor_bottom(self: *const Self, root: Buffer.Root) Cursor {
    const bottom = @min(root.lines(), self.row + self.rows + 1);
    return .{ .row = bottom, .col = 0 };
}

fn clamp_row(self: *Self, cursor: *const Cursor, abs: bool) void {
    const min_border_distance: usize = if (abs) scroll_cursor_min_border_distance_mouse else scroll_cursor_min_border_distance;
    if (cursor.row < min_border_distance) {
        self.row = 0;
        return;
    }
    if (self.row > 0 and cursor.row >= min_border_distance) {
        if (cursor.row < self.row + min_border_distance) {
            self.row = cursor.row - min_border_distance;
            return;
        }
    }
    if (cursor.row < self.row) {
        self.row = 0;
    } else if (cursor.row > self.row + self.rows - min_border_distance) {
        self.row = cursor.row + min_border_distance - self.rows;
    }
}

fn clamp_col(self: *Self, cursor: *const Cursor, _: bool) void {
    if (cursor.col < self.col) {
        self.col = cursor.col;
    } else if (cursor.col > self.col + self.cols - 1) {
        self.col = cursor.col - self.cols + 1;
    }
}

pub fn clamp(self: *Self, cursor: *const Cursor, abs: bool) void {
    self.clamp_row(cursor, abs);
    self.clamp_col(cursor, abs);
}

pub fn write(self: *const Self, writer: Buffer.MetaWriter) !void {
    try cbor.writeValue(writer, .{
        self.row,
        self.col,
        self.rows,
        self.cols,
    });
}

pub fn extract(self: *Self, iter: *[]const u8) !bool {
    return cbor.matchValue(iter, .{
        cbor.extract(&self.row),
        cbor.extract(&self.col),
        cbor.extract(&self.rows),
        cbor.extract(&self.cols),
    });
}
