const std = @import("std");
const Allocator = std.mem.Allocator;
const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Button = @import("Button.zig");
const Menu = @import("Menu.zig");

menu: *const Menu,

pub const ButtonType = Button.Options(@This()).ButtonType;

pub const label = " ≡ ";
pub const width = 3;

pub fn create(allocator: Allocator, parent: Plane, menu: *const Menu) error{OutOfMemory}!Widget {
    return Button.create_widget(@This(), allocator, parent, .{
        .ctx = .{ .menu = menu },
        .label = label,
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
    });
}

fn on_click(self: *@This(), btn: *ButtonType, _: Widget.Pos) void {
    tui.open_menu(self.menu, anchor(btn), null) catch |e| std.log.err("menu: {t}", .{e});
}

pub fn anchor(btn: *const ButtonType) tui.MenuPopup.Anchor {
    const y, const x = btn.plane.global_yx();
    return .{
        .y = y + btn.plane.dim_y(),
        .x = x,
        .flip_x = x + btn.plane.dim_x(),
    };
}

pub fn find_visible() ?*ButtonType {
    const mv = tui.mainview() orelse return null;
    var ctx: FindVisible = .{};
    _ = mv.walk(&ctx, FindVisible.walk);
    return ctx.found;
}

const FindVisible = struct {
    found: ?*ButtonType = null,

    fn walk(ctx_: *anyopaque, w: Widget, _: Widget.WalkEvent) bool {
        const btn = w.dynamic_cast(ButtonType) orelse return false;
        if (btn.plane.dim_x() == 0 or btn.plane.dim_y() == 0) return false;
        const ctx: *FindVisible = @ptrCast(@alignCast(ctx_));
        ctx.found = btn;
        return true;
    }
};

pub fn layout(_: *@This(), _: *ButtonType) Widget.Layout {
    return .{ .static = width };
}

pub fn render(_: *@This(), btn: *ButtonType, theme: *const Widget.Theme) bool {
    return render_button(btn, theme);
}

pub fn render_button(btn: anytype, theme: *const Widget.Theme) bool {
    btn.plane.set_base_style(theme.editor);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(if (btn.active)
        theme.editor_cursor
    else if (btn.hover)
        theme.statusbar_hover
    else
        theme.tab_inactive);
    btn.plane.fill(" ");
    btn.plane.home();
    _ = btn.plane.putstr(btn.opts.label) catch {};
    return false;
}
