const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");

const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Button = @import("Button.zig");
const tui = @import("tui.zig");

pub fn Options(context: type) type {
    return struct {
        ctx: Context,

        on_click: *const fn (ctx: context, button: *Button.State(*State(Context))) void = do_nothing,
        on_render: *const fn (ctx: context, button: *Button.State(*State(Context)), theme: *const Widget.Theme) bool = on_render_default,
        on_layout: *const fn (ctx: context, button: *Button.State(*State(Context))) Widget.Layout = on_layout_default,

        pub const Context = context;
        pub fn do_nothing(_: context, _: *Button.State(*State(Context))) void {}

        pub fn on_render_default(_: context, button: *Button.State(*State(Context)), theme: *const Widget.Theme) bool {
            const style_base = if (button.active) theme.editor_cursor else if (button.hover) theme.editor_selection else theme.editor;
            const bg_alpha: c_uint = if (button.active or button.hover) nc.ALPHA_OPAQUE else nc.ALPHA_TRANSPARENT;
            try tui.set_base_style_alpha(button.plane, " ", style_base, nc.ALPHA_TRANSPARENT, bg_alpha);
            button.plane.erase();
            button.plane.home();
            _ = button.plane.print(" {s} ", .{button.opts.label}) catch {};
            return false;
        }

        pub fn on_layout_default(_: context, _: *Button.State(*State(Context))) Widget.Layout {
            return .{ .static = 1 };
        }
    };
}

pub fn create(ctx_type: type, a: std.mem.Allocator, parent: Widget, opts: Options(ctx_type)) !*State(ctx_type) {
    const self = try a.create(State(ctx_type));
    self.* = .{
        .a = a,
        .menu = try WidgetList.createV(a, parent, @typeName(@This()), .dynamic),
        .menu_widget = self.menu.widget(),
        .opts = opts,
    };
    return self;
}

pub fn State(ctx_type: type) type {
    return struct {
        a: std.mem.Allocator,
        menu: *WidgetList,
        menu_widget: Widget,
        opts: Options(ctx_type),

        const Self = @This();

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.menu.deinit(a);
            a.destroy(self);
        }

        pub fn add_item(self: *Self, label: []const u8) !void {
            try self.menu.add(try Button.create(*Self, self.a, self.menu.parent, .{
                .ctx = self,
                .on_layout = self.opts.on_layout,
                .label = label,
                .on_click = self.opts.on_click,
                .on_render = self.opts.on_render,
            }));
        }

        pub fn add_item_with_handler(self: *Self, label: []const u8, on_click: *const fn (_: *Self, _: *Button.State(*Self)) void) !void {
            try self.menu.add(try Button.create(*Self, self.a, self.menu.parent, .{
                .ctx = self,
                .on_layout = on_layout,
                .label = label,
                .on_click = on_click,
                .on_render = on_render,
            }));
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            return self.menu.render(theme);
        }

        pub fn on_layout(self: *Self, button: *Button.State(*Self)) Widget.Layout {
            return self.opts.on_layout(self.opts.ctx, button);
        }

        pub fn on_render(self: *Self, button: *Button.State(*Self), theme: *const Widget.Theme) bool {
            return self.opts.on_render(self.opts.ctx, button, theme);
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
    };
}
