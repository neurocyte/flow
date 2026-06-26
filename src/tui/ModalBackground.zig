const std = @import("std");
const tp = @import("thespian");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const renderer = @import("renderer");
const Plane = renderer.Plane;
const Layer = renderer.Layer;
const MouseEvent = @import("MouseEvent");

const dim_color: u24 = 0x000000;

pub const Effect = enum { none, dim };

pub fn Options(context: type) type {
    return struct {
        ctx: Context,

        effect: Effect = .dim,
        dim_target: u8 = 192,

        on_click: *const fn (ctx: context, self: *State(Context)) void = on_click_exit_overlay_mode,
        on_click2: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_click3: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_click4: *const fn (ctx: context, self: *State(Context)) void = do_nothing,
        on_click5: *const fn (ctx: context, self: *State(Context)) void = do_nothing,

        pub const Context = context;
        pub fn do_nothing(_: context, _: *State(Context)) void {}

        fn on_click_exit_overlay_mode(_: context, _: *State(Context)) void {
            tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch {};
        }
    };
}

pub fn create(ctx_type: type, allocator: std.mem.Allocator, parent: Widget, opts: Options(ctx_type)) !*State(ctx_type) {
    const self = try allocator.create(State(ctx_type));
    errdefer allocator.destroy(self);
    const layer = try Layer.init(allocator, .{ .h = 1, .w = 1 });
    errdefer layer.deinit();
    self.* = .{
        .allocator = allocator,
        .plane = parent.plane.*,
        .layer = layer,
        .opts = opts,
        .target_alpha = 255 -| opts.dim_target,
        .fade_time_ms = tui.config().animation_max_lag,
        .frame_rate = @intCast(tp.env.get().num("frame-rate")),
    };
    layer.z_index = .modal;
    self.plane.layer = layer;
    return self;
}

pub fn State(ctx_type: type) type {
    return struct {
        allocator: std.mem.Allocator,
        plane: Plane,
        layer: *Layer,
        opts: options_type,
        target_alpha: u8,
        alpha: u8 = 0,
        fade_time_ms: usize,
        frame_rate: usize,
        hover: bool = false,

        const Self = @This();
        const options_type = Options(ctx_type);

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.plane.deinit();
            self.layer.deinit();
            allocator.destroy(self);
        }

        pub fn widget(self: *Self) Widget {
            return Widget.to(self);
        }

        fn fill_dim(self: *Self) void {
            var plane = self.layer.plane();
            plane.set_base_style(.{ .bg = .{ .color = dim_color } });
            plane.erase();
        }

        pub fn render(self: *Self, _: *const Widget.Theme) bool {
            if (!tui.config().enable_modal_dim) return false;
            if (self.opts.effect == .none) return false;

            const root = tui.plane();
            const screen = root.window.screen;
            self.layer.resize(screen.width, screen.height, screen.width_pix, screen.height_pix) catch return false;
            self.layer.z_index = .modal;
            self.layer.origin_px_x = 0;
            self.layer.origin_px_y = 0;

            self.fill_dim();

            _ = tui.submit_layer(.{
                .src = self.layer,
                .dst = root.window,
                .x = 0,
                .y = 0,
                .alpha = self.alpha,
                .z_index = .modal,
                .blend = .src_over,
            });

            if (self.alpha < self.target_alpha) {
                self.alpha = @min(self.target_alpha, self.alpha +| self.fade_step());
                return true;
            }
            return false;
        }

        fn fade_step(self: *Self) u8 {
            const frame_time_ms = @max(@divTrunc(@as(i64, 1000), @as(i64, @intCast(self.frame_rate))), 1);
            const fade_steps = @max(self.fade_time_ms / @as(usize, @intCast(frame_time_ms)), 1);
            return @intCast(@max(self.target_alpha / fade_steps, 1));
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
