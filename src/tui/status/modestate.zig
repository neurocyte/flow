const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");
const root = @import("root");
const Buffer = @import("Buffer");

const Widget = @import("../Widget.zig");
const Menu = @import("../Menu.zig");
const Button = @import("../Button.zig");
const command = @import("../command.zig");
const ed = @import("../editor.zig");
const tui = @import("../tui.zig");

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    return Button.create({}, a, parent, .{
        .label = tui.get_mode(),
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
    });
}

pub fn layout(_: *void, _: *Button.State(void)) Widget.Layout {
    const name = tui.get_mode();
    const width = Buffer.egc_chunk_width(name, 0);
    const padding: usize = if (is_mini_mode()) 3 else 2;
    return .{ .static = width + padding };
}

fn is_mini_mode() bool {
    return if (tui.current().mini_mode) |_| true else false;
}

pub fn render(state: *void, self: *Button.State(void), theme: *const Widget.Theme) bool {
    tui.set_base_style(&self.plane, " ", if (self.active) theme.editor_cursor else if (self.hover) theme.editor_selection else theme.statusbar_hover);
    self.plane.on_styles(nc.style.bold);
    self.plane.erase();
    self.plane.home();
    var buf: [31:0]u8 = undefined;
    _ = self.plane.putstr(std.fmt.bufPrintZ(&buf, " {s} ", .{tui.get_mode()}) catch return false) catch {};
    if (is_mini_mode())
        render_separator(state, self, theme);
    return false;
}

fn render_separator(_: *void, self: *Button.State(void), theme: *const Widget.Theme) void {
    if (theme.statusbar_hover.bg) |bg| self.plane.set_fg_rgb(bg) catch {};
    if (theme.statusbar.bg) |bg| self.plane.set_bg_rgb(bg) catch {};
    _ = self.plane.putstr("") catch {};
}

fn on_click(_: *void, _: *Button.State(void)) void {
    command.executeName("toggle_input_mode", .{}) catch {};
}
