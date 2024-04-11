const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");

const Widget = @import("Widget.zig");
const command = @import("command.zig");
const tui = @import("tui.zig");

pub fn Options(context: type) type {
    return struct {
        label: []const u8 = "button",
        pos: Widget.Box = .{ .y = 0, .x = 0, .w = 8, .h = 1 },
        ctx: Context,

        on_click: *const fn (ctx: *context, button: *State(Context)) void = do_nothing,
        on_click2: *const fn (ctx: *context, button: *State(Context)) void = do_nothing,
        on_click3: *const fn (ctx: *context, button: *State(Context)) void = do_nothing,
        on_render: *const fn (ctx: *context, button: *State(Context), theme: *const Widget.Theme) bool = on_render_default,
        on_layout: *const fn (ctx: *context, button: *State(Context)) Widget.Layout = on_layout_default,
        on_receive: *const fn (ctx: *context, button: *State(Context), from: tp.pid_ref, m: tp.message) error{Exit}!bool = on_receive_default,

        pub const Context = context;
        pub fn do_nothing(_: *context, _: *State(Context)) void {}

        pub fn on_render_default(_: *context, self: *State(Context), theme: *const Widget.Theme) bool {
            tui.set_base_style(&self.plane, " ", if (self.active) theme.scrollbar_active else if (self.hover) theme.scrollbar_hover else theme.scrollbar);
            self.plane.erase();
            self.plane.home();
            _ = self.plane.print(" {s} ", .{self.opts.label}) catch {};
            return false;
        }

        pub fn on_layout_default(_: *context, self: *State(Context)) Widget.Layout {
            return .{ .static = self.opts.label.len + 2 };
        }

        pub fn on_receive_default(_: *context, _: *State(Context), _: tp.pid_ref, _: tp.message) error{Exit}!bool {
            return false;
        }
    };
}

pub fn create(ctx_type: type, a: std.mem.Allocator, parent: nc.Plane, opts: Options(ctx_type)) !*State(ctx_type) {
    const Self = State(ctx_type);
    const self = try a.create(Self);
    var n = try nc.Plane.init(&opts.pos.opts(@typeName(Self)), parent);
    errdefer n.deinit();
    self.* = .{
        .parent = parent,
        .plane = n,
        .opts = opts,
        .label = std.ArrayList(u8).init(a),
    };
    try self.label.appendSlice(self.opts.label);
    self.opts.label = self.label.items;
    return self;
}

pub fn create_widget(ctx_type: type, a: std.mem.Allocator, parent: nc.Plane, opts: Options(ctx_type)) !Widget {
    return Widget.to(try create(ctx_type, a, parent, opts));
}

pub fn State(ctx_type: type) type {
    return struct {
        parent: nc.Plane,
        plane: nc.Plane,
        active: bool = false,
        hover: bool = false,
        label: std.ArrayList(u8),
        opts: Options(ctx_type),

        const Self = @This();
        pub const Context = ctx_type;

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.label.deinit();
            self.plane.deinit();
            a.destroy(self);
        }

        pub fn layout(self: *Self) Widget.Layout {
            return self.opts.on_layout(&self.opts.ctx, self);
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            return self.opts.on_render(&self.opts.ctx, self, theme);
        }

        pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var btn: u32 = 0;
            if (try m.match(.{ "B", nc.event_type.PRESS, tp.extract(&btn), tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.active = true;
                tui.need_render();
                return true;
            } else if (try m.match(.{ "B", nc.event_type.RELEASE, tp.extract(&btn), tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.call_click_handler(btn);
                self.active = false;
                tui.need_render();
                return true;
            } else if (try m.match(.{ "D", nc.event_type.RELEASE, tp.extract(&btn), tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.call_click_handler(btn);
                self.active = false;
                tui.need_render();
                return true;
            } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
                tui.current().request_mouse_cursor_pointer(self.hover);
                tui.need_render();
                return true;
            }
            return self.opts.on_receive(&self.opts.ctx, self, from, m);
        }

        fn call_click_handler(self: *Self, btn: u32) void {
            if (!self.hover) return;
            switch (btn) {
                nc.key.BUTTON1 => self.opts.on_click(&self.opts.ctx, self),
                nc.key.BUTTON2 => self.opts.on_click2(&self.opts.ctx, self),
                nc.key.BUTTON3 => self.opts.on_click3(&self.opts.ctx, self),
                else => {},
            }
        }
    };
}
