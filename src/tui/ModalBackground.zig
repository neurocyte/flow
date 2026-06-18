const std = @import("std");
const tp = @import("thespian");
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Plane = @import("renderer").Plane;
const input = @import("input");
const MouseEvent = @import("MouseEvent");

pub fn Options(context: type) type {
    return struct {
        ctx: Context,

        dim: u8 = 255,
        dim_target: u8 = 192,

        on_click: *const fn (ctx: context, self: *State(Context)) void = on_click_exit_overlay_mode,
        on_click2: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_click3: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_click4: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_click5: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_render: *const fn (ctx: context, self: *State(Context), theme: *const Widget.Theme) bool = on_render_dim,
        on_layout: *const fn (ctx: context) Widget.Layout = on_layout_default,
        on_resize: *const fn (ctx: context, state: *State(Context), box: Widget.Box) void = on_resize_default,

        pub const Context = context;
        pub fn do_nothing(_: context, _: *State(Context)) void {}

        fn on_click_exit_overlay_mode(_: context, _: *State(Context)) void {
            tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch {};
        }

        pub fn on_render_default(_: context, _: *State(Context), _: *const Widget.Theme) bool {
            return false;
        }

        pub fn on_render_dim(_: context, self: *State(Context), _: *const Widget.Theme) bool {
            const frame_time_ms = @divTrunc(1000, self.frame_rate);
            const fade_steps = @max(self.fade_time_ms / frame_time_ms, 1);
            const step_size: u8 = @intCast((255 - self.opts.dim_target) / fade_steps);
            const height = self.plane.dim_y();
            const width = self.plane.dim_x();
            for (0..height) |y| for (0..width) |x|
                dim_cell(&self.plane, y, x, self.opts.dim) catch {};
            if (self.opts.dim > self.opts.dim_target) {
                self.opts.dim -= step_size;
                return true;
            }
            return false;
        }

        pub fn on_layout_default(_: context) Widget.Layout {
            return .dynamic;
        }

        pub fn on_resize_default(_: context, _: *State(Context), _: Widget.Box) void {}
    };
}

pub fn create(ctx_type: type, allocator: std.mem.Allocator, parent: Widget, opts: Options(ctx_type)) !*State(ctx_type) {
    const self = try allocator.create(State(ctx_type));
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = parent.plane.*,
        .opts = opts,
        .fade_time_ms = tui.config().animation_max_lag,
        .frame_rate = @intCast(tp.env.get().num("frame-rate")),
    };
    return self;
}

pub fn State(ctx_type: type) type {
    return struct {
        allocator: std.mem.Allocator,
        plane: Plane,
        opts: options_type,
        fade_time_ms: usize,
        frame_rate: usize,
        hover: bool = false,

        const Self = @This();
        const options_type = Options(ctx_type);

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            if (!tui.config().enable_modal_dim) return false;
            return self.opts.on_render(self.opts.ctx, self, theme);
        }

        pub fn widget(self: *Self) Widget {
            return Widget.to(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var btn: MouseEvent.Button = .none;
            if (try m.match(.{ MouseEvent.Type.press, tp.more })) {
                return true;
            } else if (try m.match(.{ MouseEvent.Type.release, tp.extract(&btn), tp.more })) {
                self.call_click_handler(btn);
                return true;
            } else if (try m.match(.{ MouseEvent.Type.drag, tp.more })) {
                return true;
            } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
                tui.rdr().request_mouse_cursor_default(self.hover);
                return true;
            }
            return false;
        }

        fn call_click_handler(self: *Self, btn: MouseEvent.Button) void {
            if (!self.hover) return;
            switch (btn) {
                .left => self.opts.on_click(self.opts.ctx, self),
                .middle => self.opts.on_click2(self.opts.ctx, self),
                .right => self.opts.on_click3(self.opts.ctx, self),
                .wheel_up => self.opts.on_click4(self.opts.ctx, self),
                .wheel_down => self.opts.on_click5(self.opts.ctx, self),
                else => {},
            }
        }
    };
}

fn dim_cell(plane: *Plane, y: usize, x: usize, dim_target: u8) !void {
    plane.cursor_move_yx(@intCast(y), @intCast(x));
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    cell.dim(dim_target);
    _ = plane.putc(&cell) catch {};
}
