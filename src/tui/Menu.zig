const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");

const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Button = @import("Button.zig");
const tui = @import("tui.zig");

a: std.mem.Allocator,
menu: *WidgetList,
menu_widget: Widget,

const Self = @This();

pub fn create(a: std.mem.Allocator, parent: Widget) !*Self {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .menu = try WidgetList.createV(a, parent, @typeName(Self), .dynamic),
        .menu_widget = self.menu.widget(),
    };
    return self;
}

pub fn add_item(self: *Self, label: []const u8, on_click: *const fn (_: void, _: *Button.State(void)) void) !void {
    try self.menu.add(try Button.create({}, self.a, self.menu.parent, .{
        .on_layout = menu_layout,
        .label = label,
        .on_click = on_click,
        .on_render = render_menu_item,
    }));
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    self.menu.deinit(a);
    a.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    return self.menu.render(theme);
}

pub fn resize(self: *Self, box_: Widget.Box) void {
    var box = box_;
    box.h = self.menu.widgets.items.len;
    self.menu.resize(box);
}

pub fn update(self: *Self) void {
    self.menu.update();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    return self.menu.walk(walk_ctx, f, &self.menu_widget);
}

fn menu_layout(_: void, _: *Button.State(void)) Widget.Layout {
    return .{ .static = 1 };
}

fn render_menu_item(_: void, button: *Button.State(void), theme: *const Widget.Theme) bool {
    tui.set_base_style(&button.plane, " ", if (button.active) theme.editor_cursor else if (button.hover) theme.editor_selection else theme.editor);
    button.plane.erase();
    button.plane.home();
    const style_subtext = if (tui.find_scope_style(theme, "comment")) |sty| sty.style else theme.editor;
    const style_text = if (tui.find_scope_style(theme, "keyword")) |sty| sty.style else theme.editor;
    const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else theme.editor;
    const sep = std.mem.indexOfScalar(u8, button.opts.label, ':') orelse button.opts.label.len;
    tui.set_style(&button.plane, style_subtext);
    tui.set_style(&button.plane, style_text);
    _ = button.plane.print(" {s}", .{button.opts.label[0..sep]}) catch {};
    tui.set_style(&button.plane, style_keybind);
    _ = button.plane.print("{s}", .{button.opts.label[sep + 1 ..]}) catch {};
    return false;
}
