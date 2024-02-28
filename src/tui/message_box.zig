const Allocator = @import("std").mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const Widget = @import("Widget.zig");
const tui = @import("tui.zig");

pub const name = @typeName(Self);
const Self = @This();

plane: nc.Plane,

const y_pos = 10;
const y_pos_hidden = -15;
const x_pos = 10;

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(parent);
    return Widget.to(self);
}

pub fn init(parent: nc.Plane) !Self {
    var n = try nc.Plane.init(&(Widget.Box{}).opts_vscroll(name), parent);
    errdefer n.deinit();
    return .{
        .plane = n,
    };
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    a.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    _ = self;
    _ = m;
    return false;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    tui.set_base_style(&self.plane, " ", theme.sidebar);
    return false;
}
