const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");
const log = @import("log");

const Widget = @import("Widget.zig");
const command = @import("command.zig");
const tui = @import("tui.zig");

pub fn Options(context: type) type {
    return struct {
        label: []const u8 = "button",
        pos: Widget.Box = .{ .y = 0, .x = 0, .w = 8, .h = 1 },
        ctx: context = {},

        on_click: *const fn (ctx: *context, button: *State(Context)) void = do_nothing,
        on_render: *const fn (ctx: *context, button: *State(Context), theme: *const Widget.Theme) bool = on_render_default,
        on_layout: *const fn (ctx: *context, button: *State(Context)) Widget.Layout = on_layout_default,

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
    };
}

pub fn create(ctx: anytype, a: std.mem.Allocator, parent: nc.Plane, opts: Options(@TypeOf(ctx))) !Widget {
    const Self = State(@TypeOf(ctx));
    const self = try a.create(Self);
    var n = try nc.Plane.init(&opts.pos.opts(@typeName(Self)), parent);
    errdefer n.deinit();
    self.* = .{
        .parent = parent,
        .plane = n,
        .opts = opts,
    };
    return Widget.to(self);
}

pub fn State(ctx_type: type) type {
    return struct {
        parent: nc.Plane,
        plane: nc.Plane,
        active: bool = false,
        hover: bool = false,
        opts: Options(ctx_type),

        const Self = @This();
        pub const Context = ctx_type;

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.plane.deinit();
            a.destroy(self);
        }

        pub fn layout(self: *Self) Widget.Layout {
            return self.opts.on_layout(&self.opts.ctx, self);
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            return self.opts.on_render(&self.opts.ctx, self, theme);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            if (try m.match(.{ "B", nc.event_type.PRESS, nc.key.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.active = true;
                return true;
            } else if (try m.match(.{ "B", nc.event_type.RELEASE, nc.key.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.opts.on_click(&self.opts.ctx, self);
                self.active = false;
                return true;
            } else if (try m.match(.{ "D", nc.event_type.RELEASE, nc.key.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.opts.on_click(&self.opts.ctx, self);
                self.active = false;
                return true;
            } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
                tui.current().request_mouse_cursor_pointer(self.hover);
                return true;
            }
            return false;
        }
    };
}
