const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");

const Widget = @import("../Widget.zig");
const ed = @import("../editor.zig");
const tui = @import("../tui.zig");

parent: nc.Plane,
plane: nc.Plane,
matches: usize = 0,
cursels: usize = 0,
selection: ?ed.Selection = null,
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
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    tui.set_base_style(&self.plane, " ", theme.statusbar);
    self.plane.erase();
    self.plane.home();
    _ = self.plane.putstr(self.rendered) catch {};
    return false;
}

fn format(self: *Self) void {
    var fbs = std.io.fixedBufferStream(&self.buf);
    const writer = fbs.writer();
    _ = writer.write(" ") catch {};
    if (self.matches > 1) {
        std.fmt.format(writer, "({d} matches)", .{self.matches}) catch {};
        if (self.selection) |_|
            _ = writer.write(" ") catch {};
    }
    if (self.cursels > 1) {
        std.fmt.format(writer, "({d} cursors)", .{self.cursels}) catch {};
        if (self.selection) |_|
            _ = writer.write(" ") catch {};
    }
    if (self.selection) |sel_| {
        var sel = sel_;
        sel.normalize();
        const lines = sel.end.row - sel.begin.row;
        if (lines == 0) {
            std.fmt.format(writer, "({d} selected)", .{sel.end.col - sel.begin.col}) catch {};
        } else {
            std.fmt.format(writer, "({d} lines selected)", .{if (sel.end.col == 0) lines else lines + 1}) catch {};
        }
    }
    _ = writer.write(" ") catch {};
    self.rendered = @ptrCast(fbs.getWritten());
    self.buf[self.rendered.len] = 0;
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "E", "match", tp.extract(&self.matches) }))
        self.format();
    if (try m.match(.{ "E", "cursels", tp.extract(&self.cursels) }))
        self.format();
    if (try m.match(.{ "E", "close" })) {
        self.matches = 0;
        self.selection = null;
        self.format();
    } else if (try m.match(.{ "E", "sel", tp.more })) {
        var sel: ed.Selection = undefined;
        if (try m.match(.{ tp.any, tp.any, "none" })) {
            self.matches = 0;
            self.selection = null;
        } else if (try m.match(.{ tp.any, tp.any, tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
            self.selection = sel;
        }
        self.format();
    }
    return false;
}
