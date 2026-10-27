//! a rich text document laid out in lines of styled runs

const std = @import("std");
const RDoc = @import("RDoc.zig");

const Allocator = std.mem.Allocator;

arena: std.heap.ArenaAllocator,
lines: std.ArrayList(Line) = .empty,
fills: std.ArrayList(Fill) = .empty,

pub const Run = struct {
    text: []const u8,
    attrs: RDoc.Attrs = .{},
};

pub const Line = struct {
    runs: []const Run,
    width: usize,
    src_row: ?usize = null,
};

pub const Fill = struct {
    line: usize,
    fill: []const u8,
    fill_width: usize,
    prefix_width: usize,
};

pub fn init(allocator_: Allocator) @This() {
    return .{ .arena = .init(allocator_) };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub fn reset(self: *@This()) void {
    _ = self.arena.reset(.retain_capacity);
    self.lines = .empty;
    self.fills = .empty;
}

pub fn allocator(self: *@This()) Allocator {
    return self.arena.allocator();
}

pub fn add_line(self: *@This(), text: []const u8, width: usize) error{OutOfMemory}!void {
    const runs = try self.allocator().alloc(Run, 1);
    runs[0] = .{ .text = text };
    try self.lines.append(self.allocator(), .{ .runs = runs, .width = width });
}

pub fn max_width(self: *const @This()) usize {
    var w: usize = 0;
    for (self.lines.items) |line| w = @max(w, line.width);
    return w;
}

pub fn fit_fills(self: *@This()) error{OutOfMemory}!void {
    if (self.fills.items.len == 0) return;
    var w: usize = 0;
    var fill_idx: usize = 0;
    for (self.lines.items, 0..) |line, i| {
        if (fill_idx < self.fills.items.len and self.fills.items[fill_idx].line == i) {
            fill_idx += 1;
            continue;
        }
        w = @max(w, line.width);
    }
    const arena = self.allocator();
    for (self.fills.items) |f| {
        const line = &self.lines.items[f.line];
        const count = @max(1, (w -| f.prefix_width) / f.fill_width);
        var text: std.ArrayList(u8) = .empty;
        for (0..count) |_| try text.appendSlice(arena, f.fill);
        const last = line.runs.len - 1;
        const runs = try arena.dupe(Run, line.runs);
        runs[last].text = text.items;
        line.runs = runs;
        line.width = f.prefix_width + count * f.fill_width;
    }
}
