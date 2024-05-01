const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");
const root = @import("root");

const Plane = @import("renderer").Plane;
const style = @import("renderer").style;

const Widget = @import("../Widget.zig");
const Menu = @import("../Menu.zig");
const Button = @import("../Button.zig");
const command = @import("../command.zig");
const ed = @import("../editor.zig");
const tui = @import("../tui.zig");

pub fn create(a: Allocator, parent: Plane) !Widget {
    return Button.create_widget(void, a, parent, .{
        .ctx = {},
        .label = tui.get_mode(),
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
    });
}

pub fn layout(_: *void, btn: *Button.State(void)) Widget.Layout {
    const name = tui.get_mode();
    const width = btn.plane.egc_chunk_width(name, 0);
    const padding: usize = if (is_mini_mode()) 3 else 2;
    return .{ .static = width + padding };
}

fn is_mini_mode() bool {
    return if (tui.current().mini_mode) |_| true else false;
}

fn is_overlay_mode() bool {
    return if (tui.current().input_mode_outer) |_| true else false;
}

pub fn render(_: *void, self: *Button.State(void), theme: *const Widget.Theme) bool {
    self.plane.set_base_style(" ", if (self.active) theme.editor_cursor else if (self.hover) theme.editor_selection else theme.statusbar_hover);
    self.plane.on_styles(style.bold);
    self.plane.erase();
    self.plane.home();
    var buf: [31:0]u8 = undefined;
    _ = self.plane.putstr(std.fmt.bufPrintZ(&buf, " {s} ", .{tui.get_mode()}) catch return false) catch {};
    if (is_mini_mode())
        render_separator(self, theme);
    return false;
}

fn render_separator(self: *Button.State(void), theme: *const Widget.Theme) void {
    if (theme.statusbar_hover.bg) |bg| self.plane.set_fg_rgb(bg) catch {};
    if (theme.statusbar.bg) |bg| self.plane.set_bg_rgb(bg) catch {};
    _ = self.plane.putstr("") catch {};
}

fn on_click(_: *void, _: *Button.State(void)) void {
    command.executeName(if (is_mini_mode())
        "exit_mini_mode"
    else if (is_overlay_mode())
        "exit_overlay_mode"
    else
        "toggle_input_mode", .{}) catch {};
}
