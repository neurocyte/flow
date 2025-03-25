const std = @import("std");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const keybind = @import("keybind");

const Widget = @import("../Widget.zig");

allocator: std.mem.Allocator,
plane: Plane,

const Self = @This();

pub fn create(allocator: std.mem.Allocator, parent: Plane, _: ?EventHandler, _: ?[]const u8) @import("widget.zig").CreateError!Widget {
    const self: *Self = try allocator.create(Self);
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
    writer.print("{}", .{keybind.current_key_event_sequence_fmt()}) catch {};
    const len = fbs.getWritten().len;
    return .{ .static = if (len > 0) len + 2 else 0 };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(theme.statusbar);
    self.plane.fill(" ");
    self.plane.home();
    _ = self.plane.print(" {} ", .{keybind.current_key_event_sequence_fmt()}) catch {};
    return false;
}
