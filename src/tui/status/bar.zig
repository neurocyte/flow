const std = @import("std");
const EventHandler = @import("EventHandler");

const status_widget = @import("widget.zig");
const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const Plane = @import("renderer").Plane;

pub const Style = enum { none, grip };

pub fn create(allocator: std.mem.Allocator, parent: Plane, config: []const u8, style: Style, event_handler: ?EventHandler) error{OutOfMemory}!Widget {
    var w = try WidgetList.createH(allocator, parent, "statusbar", .{ .static = 1 });
    if (style == .grip) w.after_render = render_grip;
    w.ctx = w;
    var it = std.mem.splitScalar(u8, config, ' ');
    while (it.next()) |widget_name| {
        try w.add(status_widget.create(widget_name, allocator, w.plane, event_handler) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WidgetInitFailed => null,
        } orelse continue);
    }
    return w.widget();
}

fn render_grip(ctx: ?*anyopaque, theme: *const Widget.Theme) void {
    const w: *WidgetList = @ptrCast(@alignCast(ctx.?));
    if (w.hover()) {
        w.plane.set_style(theme.statusbar_hover);
        w.plane.cursor_move_yx(0, 0) catch {};
        _ = w.plane.putstr("  ") catch {};
    }
}
