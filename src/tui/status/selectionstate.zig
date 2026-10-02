const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");
const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;

const tui = @import("../tui.zig");
const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const MenuButton = @import("../MenuButton.zig");
const ed = @import("../editor.zig");

matches: usize = 0,
cursels: usize = 0,
selection: ?ed.Selection = null,
buf: [256]u8 = undefined,
rendered: [:0]const u8 = "",

const Self = @This();
const ButtonType = Button.Options(Self).ButtonType;

pub fn create(allocator: Allocator, parent: Plane, event_handler: ?EventHandler, _: ?[]const u8) @import("widget.zig").CreateError!Widget {
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

fn on_click(_: *Self, btn: *ButtonType, _: Widget.Pos) void {
    tui.open_menu(&@import("../menu/Main.zig").selection, MenuButton.anchor(btn), null) catch |e|
        std.log.err("selection menu: {t}", .{e});
}

pub fn layout(self: *Self, _: *ButtonType) Widget.Layout {
    return if (tui.screen().w < 100)
        .{ .static = 0 }
    else
        .{ .static = self.rendered.len };
}

pub fn render(self: *Self, btn: *ButtonType, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    btn.plane.set_base_style(theme.editor);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
    btn.plane.fill(" ");
    btn.plane.home();
    _ = btn.plane.putstr(self.rendered) catch {};
    return false;
}

fn format(self: *Self) void {
    var writer: std.Io.Writer = .fixed(&self.buf);
    writer.writeAll(" ") catch {};
    if (self.matches > 1) {
        writer.print("({d} matches)", .{self.matches}) catch {};
        if (self.selection) |_|
            writer.writeAll(" ") catch {};
    }
    if (self.cursels > 1) {
        writer.print("({d} cursors)", .{self.cursels}) catch {};
        if (self.selection) |_|
            writer.writeAll(" ") catch {};
    }
    if (self.selection) |sel_| {
        var sel = sel_;
        sel.normalize();
        const lines = sel.end.row - sel.begin.row;
        if (lines == 0) {
            writer.print("({d} columns selected)", .{sel.end.col - sel.begin.col}) catch {};
        } else {
            writer.print("({d} lines selected)", .{if (sel.end.col == 0) lines else lines + 1}) catch {};
        }
    }
    writer.writeAll(" ") catch {};
    self.rendered = @ptrCast(writer.buffered());
    self.buf[self.rendered.len] = 0;
}

pub fn receive(self: *Self, _: *ButtonType, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
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
