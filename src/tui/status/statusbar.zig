const std = @import("std");

const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const tui = @import("../tui.zig");

const Self = @This();

pub fn create(a: std.mem.Allocator, parent: Widget, event_handler: ?Widget.EventHandler) !Widget {
    var w = try WidgetList.createH(a, parent, "statusbar", .{ .static = 1 });
    w.after_render = render_grip;
    w.ctx = w;
    if (tui.current().config.modestate_show) try w.add(try @import("modestate.zig").create(a, w.plane, event_handler));
    try w.add(try @import("filestate.zig").create(a, w.plane, event_handler));
    try w.add(try @import("minilog.zig").create(a, w.plane, event_handler));
    if (tui.current().config.selectionstate_show) try w.add(try @import("selectionstate.zig").create(a, w.plane, event_handler));
    try w.add(try @import("diagstate.zig").create(a, w.plane, event_handler));
    try w.add(try @import("linenumstate.zig").create(a, w.plane, event_handler));
    if (tui.current().config.modstate_show) try w.add(try @import("modstate.zig").create(a, w.plane));
    if (tui.current().config.keystate_show) try w.add(try @import("keystate.zig").create(a, w.plane));
    return w.widget();
}

fn render_grip(ctx: ?*anyopaque, theme: *const Widget.Theme) void {
    const w: *WidgetList = @ptrCast(@alignCast(ctx.?));
    if (w.hover()) {
        w.plane.set_style(theme.statusbar_hover);
        const width = w.plane.dim_x();
        const grip_pos = width / 2;
        w.plane.cursor_move_yx(0, @intCast(grip_pos)) catch {};
        _ = w.plane.putstr("  ") catch {};
    }
}
