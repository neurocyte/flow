const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");
const root = @import("root");

const Widget = @import("../Widget.zig");
const command = @import("../command.zig");
const ed = @import("../editor.zig");
const tui = @import("../tui.zig");

parent: nc.Plane,
plane: nc.Plane,

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

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = if (is_mini_mode()) tui.get_mode().len + 5 else tui.get_mode().len - 1 };
}

fn is_mini_mode() bool {
    return if (tui.current().mini_mode) |_| true else false;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (is_mini_mode())
        self.render_mode(theme)
    else
        self.render_logo(theme);
    return false;
}

fn render_mode(self: *Self, theme: *const Widget.Theme) void {
    tui.set_base_style(&self.plane, " ", theme.statusbar_hover);
    self.plane.on_styles(nc.style.bold);
    self.plane.erase();
    self.plane.home();
    var buf: [31:0]u8 = undefined;
    _ = self.plane.putstr(std.fmt.bufPrintZ(&buf, "   {s} ", .{tui.get_mode()}) catch return) catch {};
    if (theme.statusbar_hover.bg) |bg| self.plane.set_fg_rgb(bg) catch {};
    if (theme.statusbar.bg) |bg| self.plane.set_bg_rgb(bg) catch {};
    _ = self.plane.putstr("") catch {};
}

fn render_logo(self: *Self, theme: *const Widget.Theme) void {
    tui.set_base_style(&self.plane, " ", theme.statusbar_hover);
    self.plane.on_styles(nc.style.bold);
    self.plane.erase();
    self.plane.home();
    var buf: [31:0]u8 = undefined;
    _ = self.plane.putstr(std.fmt.bufPrintZ(&buf, " {s} ", .{tui.get_mode()}) catch return) catch {};
}
