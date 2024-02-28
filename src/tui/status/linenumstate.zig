const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");

const Widget = @import("../Widget.zig");
const tui = @import("../tui.zig");

parent: nc.Plane,
plane: nc.Plane,
line: usize = 0,
lines: usize = 0,
column: usize = 0,
buf: [256]u8 = undefined,
rendered: [:0]const u8 = "",

const Self = @This();

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(parent);
    return Widget.to(self);
}

fn init(parent: nc.Plane) !Self {
    var n = try nc.Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent);
    errdefer n.deinit();

    return .{
        .parent = parent,
        .plane = n,
    };
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    a.destroy(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return .{ .static = self.rendered.len };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    tui.set_base_style(&self.plane, " ", theme.statusbar);
    self.plane.erase();
    self.plane.home();
    _ = self.plane.putstr(self.rendered) catch {};
    return false;
}

fn format(self: *Self) void {
    var fbs = std.io.fixedBufferStream(&self.buf);
    const writer = fbs.writer();
    std.fmt.format(writer, " Ln {d}, Col {d} ", .{ self.line + 1, self.column + 1 }) catch {};
    self.rendered = @ptrCast(fbs.getWritten());
    self.buf[self.rendered.len] = 0;
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "E", "pos", tp.extract(&self.lines), tp.extract(&self.line), tp.extract(&self.column) })) {
        self.format();
    } else if (try m.match(.{ "E", "close" })) {
        self.lines = 0;
        self.line = 0;
        self.column = 0;
        self.rendered = "";
    }
    return false;
}
