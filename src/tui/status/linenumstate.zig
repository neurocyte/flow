const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");

const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const tui = @import("../tui.zig");
const command = @import("../command.zig");

line: usize = 0,
lines: usize = 0,
column: usize = 0,
buf: [256]u8 = undefined,
rendered: [:0]const u8 = "",

const Self = @This();

pub fn create(allocator: Allocator, parent: Plane, event_handler: ?Widget.EventHandler) @import("widget.zig").CreateError!Widget {
    return Button.create_widget(Self, allocator, parent, .{
        .ctx = .{},
        .label = "",
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
        .on_receive = receive,
        .on_event = event_handler,
    });
}

fn on_click(_: *Self, _: *Button.State(Self)) void {
    command.executeName("goto", .{}) catch {};
}

pub fn layout(self: *Self, _: *Button.State(Self)) Widget.Layout {
    return .{ .static = self.rendered.len };
}

pub fn render(self: *Self, btn: *Button.State(Self), theme: *const Widget.Theme) bool {
    btn.plane.set_base_style(" ", if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
    btn.plane.erase();
    btn.plane.home();
    _ = btn.plane.putstr(self.rendered) catch {};
    return false;
}

fn format(self: *Self) void {
    var fbs = std.io.fixedBufferStream(&self.buf);
    const writer = fbs.writer();
    std.fmt.format(writer, " Ln {d}, Col {d} ", .{ self.line + 1, self.column + 1 }) catch {};
    self.rendered = @ptrCast(fbs.getWritten());
    self.buf[self.rendered.len] = 0;
}

pub fn receive(self: *Self, _: *Button.State(Self), _: tp.pid_ref, m: tp.message) error{Exit}!bool {
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
