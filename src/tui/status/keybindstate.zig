const std = @import("std");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const keybind = @import("keybind");

const Widget = @import("../Widget.zig");

allocator: std.mem.Allocator,
plane: Plane,

const Self = @This();

pub fn create(allocator: std.mem.Allocator, parent: Plane, _: ?EventHandler, _: ?[]const u8) @import("widget.zig").CreateError!Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
    };
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    writer.print(" ", .{}) catch {};
    if (keybind.current_integer_argument()) |integer_argument|
        writer.print("{}", .{integer_argument}) catch {};
    writer.print("{} ", .{keybind.current_key_event_sequence_fmt()}) catch {};
    const len = fbs.getWritten().len;
    return .{ .static = if (len > 0) len else 0 };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(theme.statusbar);
    self.plane.fill(" ");
    self.plane.home();
    _ = self.plane.print(" ", .{}) catch {};
    if (keybind.current_integer_argument()) |integer_argument|
        _ = self.plane.print("{}", .{integer_argument}) catch {};
    _ = self.plane.print("{} ", .{keybind.current_key_event_sequence_fmt()}) catch {};
    return false;
}
