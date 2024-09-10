const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const Widget = @import("Widget.zig");

pub const name = @typeName(Self);

const Self = @This();

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
lines: std.ArrayList([]const u8),

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .lines = std.ArrayList([]const u8).init(allocator),
    };
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.clear();
    self.lines.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn clear(self: *Self) void {
    for (self.lines.items) |line|
        self.allocator.free(line);
    self.lines.clearRetainingCapacity();
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.view_rows = pos.h;
}

pub fn set_content(self: *Self, content: []const u8) !void {
    self.clear();
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line|
        (try self.lines.addOne()).* = try self.allocator.dupe(u8, line);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(" ", theme.panel);
    self.plane.erase();
    self.plane.home();
    for (self.lines.items) |line| {
        _ = self.plane.putstr(line) catch {};
        if (self.plane.cursor_y() >= self.view_rows - 1)
            return false;
        self.plane.cursor_move_yx(-1, 0) catch {};
        self.plane.cursor_move_rel(1, 0) catch {};
    }
    return false;
}
