const std = @import("std");
const Plane = @import("renderer").Plane;

const Allocator = std.mem.Allocator;

allocator: Allocator,
text: std.ArrayList(u8) = .empty,
cursor: usize = 0,
anchor: ?usize = null,
undo_stack: std.ArrayList(Snapshot) = .empty,
redo_stack: std.ArrayList(Snapshot) = .empty,
last_edit: Edit = .none,

const Self = @This();

pub const Selection = struct { begin: usize, end: usize };

pub const Select = enum { move, select };

const Edit = enum { none, insert, delete, replace };

const Snapshot = struct {
    text: []const u8,
    cursor: usize,
    anchor: ?usize,
};

pub fn init(allocator: Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.clear_stack(&self.undo_stack);
    self.clear_stack(&self.redo_stack);
    self.undo_stack.deinit(self.allocator);
    self.redo_stack.deinit(self.allocator);
    self.text.deinit(self.allocator);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.text.items;
}

pub fn selection(self: *const Self) ?Selection {
    const anchor = self.anchor orelse return null;
    if (anchor == self.cursor) return null;
    return .{ .begin = @min(anchor, self.cursor), .end = @max(anchor, self.cursor) };
}

pub fn selected_text(self: *const Self) ?[]const u8 {
    const sel = self.selection() orelse return null;
    return self.text.items[sel.begin..sel.end];
}

pub fn set_text(self: *Self, text: []const u8) !void {
    if (std.mem.eql(u8, text, self.text.items)) return self.move_to(text.len, .move);
    try self.checkpoint(.replace);
    self.text.clearRetainingCapacity();
    try self.text.appendSlice(self.allocator, text);
    self.cursor = self.text.items.len;
    self.anchor = null;
}

pub fn truncate(self: *Self, len: usize) !void {
    if (len >= self.text.items.len) return self.move_to(self.text.items.len, .move);
    try self.checkpoint(.replace);
    self.text.shrinkRetainingCapacity(len);
    self.cursor = len;
    self.anchor = null;
}

pub fn clear_history(self: *Self) void {
    self.clear_stack(&self.undo_stack);
    self.clear_stack(&self.redo_stack);
    self.last_edit = .none;
}

pub fn clear(self: *Self) !void {
    return self.set_text("");
}

pub fn insert(self: *Self, text: []const u8) !void {
    return self.insert_as(text, if (self.selection() == null) .insert else .replace);
}

pub fn paste(self: *Self, text: []const u8) !void {
    return self.insert_as(text, .replace);
}

fn insert_as(self: *Self, text: []const u8, edit: Edit) !void {
    if (text.len == 0) return;
    try self.checkpoint(edit);
    self.remove_selection();
    try self.text.insertSlice(self.allocator, self.cursor, text);
    self.cursor += text.len;
}

pub fn insert_code_point(self: *Self, c: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(c, &buf);
    return self.insert(buf[0..len]);
}

pub fn move_left(self: *Self, select: Select) void {
    if (select == .move) if (self.selection()) |sel| return self.move_to(sel.begin, .move);
    self.move_to(self.prev(self.cursor), select);
}

pub fn move_right(self: *Self, select: Select) void {
    if (select == .move) if (self.selection()) |sel| return self.move_to(sel.end, .move);
    self.move_to(self.next(self.cursor), select);
}

pub fn move_word_left(self: *Self, select: Select) void {
    self.move_to(self.word_left(self.cursor), select);
}

pub fn move_word_right(self: *Self, select: Select) void {
    self.move_to(self.word_right(self.cursor), select);
}

pub fn move_begin(self: *Self, select: Select) void {
    self.move_to(0, select);
}

pub fn move_end(self: *Self, select: Select) void {
    self.move_to(self.text.items.len, select);
}

pub fn select_all(self: *Self) void {
    self.last_edit = .none;
    self.anchor = 0;
    self.cursor = self.text.items.len;
}

pub fn delete_backward(self: *Self) !void {
    return self.delete_to(self.prev(self.cursor));
}

pub fn delete_forward(self: *Self) !void {
    return self.delete_to(self.next(self.cursor));
}

pub fn delete_word_left(self: *Self) !void {
    return self.delete_to(self.word_left(self.cursor));
}

pub fn delete_word_right(self: *Self) !void {
    return self.delete_to(self.word_right(self.cursor));
}

pub fn delete_to_begin(self: *Self) !void {
    return self.delete_to(0);
}

pub fn delete_to_end(self: *Self) !void {
    return self.delete_to(self.text.items.len);
}

pub fn delete_selection(self: *Self) !void {
    if (self.selection() == null) return;
    try self.checkpoint(.replace);
    self.remove_selection();
}

pub fn undo(self: *Self) !void {
    return self.restore(&self.undo_stack, &self.redo_stack);
}

pub fn redo(self: *Self) !void {
    return self.restore(&self.redo_stack, &self.undo_stack);
}

fn move_to(self: *Self, pos: usize, select: Select) void {
    self.last_edit = .none;
    switch (select) {
        .move => self.anchor = null,
        .select => if (self.anchor == null) {
            self.anchor = self.cursor;
        },
    }
    self.cursor = pos;
}

fn delete_to(self: *Self, pos: usize) !void {
    if (self.selection()) |_| return self.delete_selection();
    if (pos == self.cursor) return;
    try self.checkpoint(.delete);
    self.anchor = pos;
    self.remove_selection();
}

fn remove_selection(self: *Self) void {
    defer self.anchor = null;
    const sel = self.selection() orelse return;
    self.text.replaceRangeAssumeCapacity(sel.begin, sel.end - sel.begin, "");
    self.cursor = sel.begin;
}

fn prev(self: *const Self, pos: usize) usize {
    return pos - Plane.egc_last(self.text.items[0..pos]).len;
}

fn next(self: *const Self, pos: usize) usize {
    return pos + Plane.egc_first(self.text.items[pos..]).len;
}

fn is_word_at(self: *const Self, pos: usize) bool {
    return switch (self.text.items[pos]) {
        '0'...'9', 'A'...'Z', 'a'...'z', 0x80...0xff => true,
        else => false,
    };
}

fn word_left(self: *const Self, pos_: usize) usize {
    var pos = pos_;
    while (pos > 0 and !self.is_word_at(self.prev(pos))) pos = self.prev(pos);
    while (pos > 0 and self.is_word_at(self.prev(pos))) pos = self.prev(pos);
    return pos;
}

fn word_right(self: *const Self, pos_: usize) usize {
    const len = self.text.items.len;
    var pos = pos_;
    while (pos < len and self.is_word_at(pos)) pos = self.next(pos);
    while (pos < len and !self.is_word_at(pos)) pos = self.next(pos);
    return pos;
}

fn snapshot(self: *const Self) !Snapshot {
    return .{
        .text = try self.allocator.dupe(u8, self.text.items),
        .cursor = self.cursor,
        .anchor = self.anchor,
    };
}

fn clear_stack(self: *Self, stack: *std.ArrayList(Snapshot)) void {
    for (stack.items) |item| self.allocator.free(item.text);
    stack.clearRetainingCapacity();
}

fn checkpoint(self: *Self, edit: Edit) !void {
    defer self.last_edit = edit;
    if (edit != .replace and edit == self.last_edit) return;
    const state = try self.snapshot();
    errdefer self.allocator.free(state.text);
    try self.undo_stack.append(self.allocator, state);
    self.clear_stack(&self.redo_stack);
}

fn restore(self: *Self, from: *std.ArrayList(Snapshot), to: *std.ArrayList(Snapshot)) !void {
    if (from.items.len == 0) return;
    const state = from.items[from.items.len - 1];
    try to.ensureUnusedCapacity(self.allocator, 1);
    try self.text.ensureTotalCapacity(self.allocator, state.text.len);
    to.appendAssumeCapacity(try self.snapshot());
    _ = from.pop();
    defer self.allocator.free(state.text);
    self.text.clearRetainingCapacity();
    self.text.appendSliceAssumeCapacity(state.text);
    self.cursor = state.cursor;
    self.anchor = state.anchor;
    self.last_edit = .none;
}
