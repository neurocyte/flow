const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");

pub const name = @typeName(Self);

const Self = @This();

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
lines: std.ArrayList([]const u8),

const default_widget_type: Widget.Type = .panel;

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    return create_widget_type(allocator, parent, default_widget_type);
}

pub fn create_widget_type(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .lines = .empty,
    };
    container.ctx = self;
    try container.add(Widget.to(self));
    return container.widget();
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.clear();
    self.lines.deinit(self.allocator);
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

pub fn append_content(self: *Self, content: []const u8) !void {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line|
        (try self.lines.addOne(self.allocator)).* = try self.allocator.dupe(u8, line);
}

pub fn set_content(self: *Self, content: []const u8) !void {
    self.clear();
    return self.append_content(content);
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    var cols: usize = 0;
    for (self.lines.items) |line| cols = @max(cols, line.len);
    return .{ .rows = self.lines.items.len, .cols = cols };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    for (self.lines.items) |line| {
        _ = self.plane.putstr(line) catch {};
        if (self.plane.cursor_y() >= self.view_rows - 1)
            return false;
        self.plane.cursor_move_yx(-1, 0);
        self.plane.cursor_move_rel(1, 0) catch {};
    }
    return false;
}
