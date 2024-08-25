const std = @import("std");
const tp = @import("thespian");
const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");

plane: Plane,
on_event: ?Widget.EventHandler,

const Self = @This();

pub fn create(a: std.mem.Allocator, parent: Plane, event_handler: ?Widget.EventHandler) @import("widget.zig").CreateError!Widget {
    const self: *Self = try a.create(Self);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .on_event = event_handler,
    };
    return Widget.to(self);
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    self.plane.deinit();
    a.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    return .dynamic;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(" ", theme.statusbar);
    self.plane.erase();
    return false;
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var btn: u32 = 0;
    if (try m.match(.{ "D", tp.any, tp.extract(&btn), tp.more })) {
        if (self.on_event) |h| h.send(from, m) catch {};
        return true;
    }
    return false;
}
