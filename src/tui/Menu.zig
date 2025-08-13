const std = @import("std");
const EventHandler = @import("EventHandler");

const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Button = @import("Button.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const Plane = @import("renderer").Plane;
const tui = @import("tui.zig");

pub const Container = WidgetList;
pub const scroll_lines = 3;

pub fn Options(context: type) type {
    return struct {
        ctx: Context,
        style: Widget.Style.Type,

        on_click: *const fn (ctx: context, button: *Button.State(*State(Context))) void = do_nothing,
        on_click4: *const fn (menu: **State(Context), button: *Button.State(*State(Context))) void = do_nothing_click,
        on_click5: *const fn (menu: **State(Context), button: *Button.State(*State(Context))) void = do_nothing_click,
        on_render: *const fn (ctx: context, button: *Button.State(*State(Context)), theme: *const Widget.Theme, selected: bool) bool = on_render_default,
        on_layout: *const fn (ctx: context, button: *Button.State(*State(Context))) Widget.Layout = on_layout_default,
        prepare_resize: *const fn (ctx: context, menu: *State(Context), box: Widget.Box) Widget.Box = prepare_resize_default,
        after_resize: *const fn (ctx: context, menu: *State(Context), box: Widget.Box) void = after_resize_default,
        on_scroll: ?EventHandler = null,

        pub const Context = context;
        pub fn do_nothing(_: context, _: *Button.State(*State(Context))) void {}
        pub fn do_nothing_click(_: **State(Context), _: *Button.State(*State(Context))) void {}

        pub fn on_render_default(_: context, button: *Button.State(*State(Context)), theme: *const Widget.Theme, selected: bool) bool {
            const style_base = theme.editor;
            const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else style_base;
            button.plane.set_base_style(style_base);
            button.plane.erase();
            button.plane.home();
            if (button.active or button.hover or selected) {
                button.plane.set_style(style_label);
                button.plane.fill(" ");
                button.plane.home();
            }
            _ = button.plane.print(" {s} ", .{button.opts.label}) catch {};
            return false;
        }

        pub fn on_layout_default(_: context, _: *Button.State(*State(Context))) Widget.Layout {
            return .{ .static = 1 };
        }

        pub fn prepare_resize_default(_: context, state: *State(Context), box_: Widget.Box) Widget.Box {
            var box = box_;
            box.h = if (box_.h == 0) state.menu.widgets.items.len else box_.h;
            return box;
        }

        pub fn after_resize_default(_: context, _: *State(Context), _: Widget.Box) void {}
    };
}

pub fn create(ctx_type: type, allocator: std.mem.Allocator, parent: Plane, opts: Options(ctx_type)) !*State(ctx_type) {
    const self = try allocator.create(State(ctx_type));
    errdefer allocator.destroy(self);
    const container = try WidgetList.createHStyled(allocator, parent, @typeName(@This()), .dynamic, opts.style);
    self.* = .{
        .allocator = allocator,
        .menu = try WidgetList.createV(allocator, container.plane, @typeName(@This()), .dynamic),
        .container = container,
        .container_widget = container.widget(),
        .frame_widget = null,
        .scrollbar = if (tui.config().show_scrollbars)
            if (opts.on_scroll) |on_scroll| (try scrollbar_v.create(allocator, parent, null, on_scroll)).dynamic_cast(scrollbar_v).? else null
        else
            null,
        .opts = opts,
    };
    self.menu.ctx = self;
    self.menu.on_render = State(ctx_type).on_render_menu;
    container.ctx = self;
    container.prepare_resize = State(ctx_type).prepare_resize;
    container.after_resize = State(ctx_type).after_resize;
    try container.add(self.menu.widget());
    if (self.scrollbar) |sb| try container.add(sb.widget());
    return self;
}

pub fn State(ctx_type: type) type {
    return struct {
        allocator: std.mem.Allocator,
        menu: *WidgetList,
        container: *WidgetList,
        container_widget: Widget,
        frame_widget: ?Widget,
        scrollbar: ?*scrollbar_v,
        opts: options_type,
        selected: ?usize = null,
        render_idx: usize = 0,
        selected_active: bool = false,
        header_count: usize = 0,

        const Self = @This();
        const options_type = Options(ctx_type);
        const button_type = Button.State(*Self);

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.menu.deinit(allocator);
            allocator.destroy(self);
        }

        pub fn add_header(self: *Self, w_: Widget) !*Widget {
            self.header_count += 1;
            try self.menu.add(w_);
            return &self.menu.widgets.items[self.menu.widgets.items.len - 1].widget;
        }

        pub fn add_item(self: *Self, label: []const u8) !void {
            try self.menu.add(try Button.create(*Self, self.allocator, self.menu.parent, .{
                .ctx = self,
                .on_layout = self.opts.on_layout,
                .label = label,
                .on_click = self.opts.on_click,
                .on_click4 = self.opts.on_click4,
                .on_click5 = self.opts.on_click5,
                .on_render = self.opts.on_render,
            }));
        }

        pub fn add_item_with_handler(self: *Self, label: []const u8, on_click: *const fn (_: **Self, _: *Button.State(*Self)) void) !void {
            try self.menu.add(try Button.create_widget(*Self, self.allocator, self.menu.parent, .{
                .ctx = self,
                .on_layout = on_layout,
                .label = label,
                .on_click = on_click,
                .on_click4 = self.opts.on_click4,
                .on_click5 = self.opts.on_click5,
                .on_render = on_render,
            }));
        }

        pub fn reset_items(self: *Self) void {
            for (self.menu.widgets.items, 0..) |*w, i|
                if (i >= self.header_count)
                    w.widget.deinit(self.allocator);
            self.menu.widgets.shrinkRetainingCapacity(self.header_count);
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            return self.menu.render(theme);
        }

        fn on_render_menu(ctx: ?*anyopaque, _: *const Widget.Theme) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.render_idx = 0;
        }

        fn prepare_resize(ctx: ?*anyopaque, _: *WidgetList, box: Widget.Box) Widget.Box {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.opts.prepare_resize(self.*.opts.ctx, self, box);
        }

        fn after_resize(ctx: ?*anyopaque, _: *WidgetList, box: Widget.Box) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.opts.after_resize(self.*.opts.ctx, self, box);
        }

        pub fn on_layout(self: **Self, button: *Button.State(*Self)) Widget.Layout {
            return self.*.opts.on_layout(self.*.opts.ctx, button);
        }

        pub fn on_render(self: **Self, button: *Button.State(*Self), theme: *const Widget.Theme) bool {
            defer self.*.render_idx += 1;
            std.debug.assert(self.*.render_idx < self.*.menu.widgets.items.len);
            return self.*.opts.on_render(self.*.opts.ctx, button, theme, self.*.render_idx == self.*.selected);
        }

        pub fn resize(self: *Self, box: Widget.Box) void {
            self.container.resize(box);
        }

        pub fn update(self: *Self) void {
            self.menu.update();
        }

        pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
            return self.menu.walk(walk_ctx, f, if (self.frame_widget) |*frame| frame else &self.container_widget);
        }

        pub fn count(self: *Self) usize {
            return self.menu.widgets.items.len;
        }

        pub fn select_down(self: *Self) void {
            const current = self.selected orelse {
                if (self.count() > 0)
                    self.selected = 0;
                return;
            };
            self.selected = if (self.count() < self.header_count + 1)
                null
            else
                @min(current + 1, self.count() - self.header_count - 1);
        }

        pub fn select_up(self: *Self) void {
            if (self.selected) |current| {
                self.selected = if (self.count() > 0) @min(self.count() - 1, @max(current, 1) - 1) else null;
            }
        }

        pub fn select_first(self: *Self) void {
            self.selected = if (self.count() > 0) 0 else null;
        }

        pub fn select_last(self: *Self) void {
            self.selected = if (self.count() > 0) self.count() - self.header_count - 1 else null;
        }

        pub fn activate_selected(self: *Self) void {
            const button = self.get_selected() orelse return;
            button.opts.on_click(&button.opts.ctx, button);
        }

        pub fn get_selected(self: *Self) ?*button_type {
            const selected = self.selected orelse return null;
            self.selected_active = true;
            const pos = selected + self.header_count;
            return if (pos < self.menu.widgets.items.len)
                self.menu.widgets.items[pos].widget.dynamic_cast(button_type)
            else
                null;
        }
    };
}
