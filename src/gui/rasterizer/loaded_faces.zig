//! Fallback faces a rasterizer backend loaded so far, readable from any thread.

const std = @import("std");
const root = @import("soft_root").root;

const Self = @This();

mutex: std.Io.Mutex = .init,
text: std.ArrayList(u8) = .empty,

pub fn add(self: *Self, allocator: std.mem.Allocator, name: []const u8, face_index: i32, color: bool, scale: f64) void {
    const io = root.get_io();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, &self.text);
    defer self.text = w.toArrayList();
    w.writer.print("  {s}", .{name}) catch return;
    if (face_index != 0) w.writer.print(" face {d}", .{face_index}) catch return;
    w.writer.print(" ({s}, scale {d:.2})\n", .{ if (color) "color" else "mono", scale }) catch return;
}

pub fn clear(self: *Self, allocator: std.mem.Allocator) void {
    const io = root.get_io();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.text.clearAndFree(allocator);
}

pub fn write(self: *Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const io = root.get_io();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    try writer.writeAll(self.text.items);
}
