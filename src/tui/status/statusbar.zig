const std = @import("std");
const nc = @import("notcurses");

const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const tui = @import("../tui.zig");

parent: nc.Plane,
plane: nc.Plane,

const Self = @This();

pub fn create(a: std.mem.Allocator, parent: Widget) !Widget {
    var w = try WidgetList.createH(a, parent, "statusbar", .{ .static = 1 });
    if (tui.current().config.modestate_show) try w.add(try @import("modestate.zig").create(a, w.plane));
    try w.add(try @import("filestate.zig").create(a, w.plane));
    try w.add(try @import("minilog.zig").create(a, w.plane));
    if (tui.current().config.selectionstate_show) try w.add(try @import("selectionstate.zig").create(a, w.plane));
    try w.add(try @import("linenumstate.zig").create(a, w.plane));
    if (tui.current().config.modstate_show) try w.add(try @import("modstate.zig").create(a, w.plane));
    if (tui.current().config.keystate_show) try w.add(try @import("keystate.zig").create(a, w.plane));
    return w.widget();
}
