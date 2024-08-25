const std = @import("std");

const status_widget = @import("widget.zig");
const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const tui = @import("../tui.zig");

const Self = @This();

pub const Style = enum { none, grip };

pub fn create(a: std.mem.Allocator, parent: Widget, config: []const u8, style: Style, event_handler: ?Widget.EventHandler) !Widget {
    var w = try WidgetList.createH(a, parent, "statusbar", .{ .static = 1 });
    if (style == .grip) w.after_render = render_grip;
    w.ctx = w;
    var it = std.mem.splitScalar(u8, config, ' ');
    while (it.next()) |widget_name|
        try w.add(try status_widget.create(widget_name, a, w.plane, event_handler) orelse continue);
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
