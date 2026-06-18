const std = @import("std");
const tp = @import("thespian");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const input = @import("input");
const MouseEvent = @import("MouseEvent");

const Widget = @import("Widget.zig");
const tui = @import("tui.zig");

pub fn Options(context: type) type {
    return struct {
        label: []const u8 = "button",
        pos: Widget.Box = .{ .y = 0, .x = 0, .w = 8, .h = 1 },
        ctx: Context,
        cursor: tui.renderer.MouseCursorShape = .pointer,

        on_click: ClickHandler = do_nothing,
        on_click2: ClickHandler = do_nothing,
        on_click3: ClickHandler = do_nothing,
        on_click4: ClickHandler = do_nothing,
        on_click5: ClickHandler = do_nothing,
        on_render: *const fn (ctx: *context, button: *ButtonType, theme: *const Widget.Theme) bool = on_render_default,
        on_layout: *const fn (ctx: *context, button: *ButtonType) Widget.Layout = on_layout_default,
        on_receive: *const fn (ctx: *context, button: *ButtonType, from: tp.pid_ref, m: tp.message) error{Exit}!bool = on_receive_default,
        on_event: ?EventHandler = null,

        pub const ButtonType = State(Context);
        pub const Context = context;
        pub const ClickHandler = *const fn (ctx: *context, button: *ButtonType, pos: Widget.Pos) void;

        pub fn do_nothing(_: *context, _: *ButtonType, _: Widget.Pos) void {}

        pub fn on_render_default(_: *context, self: *ButtonType, theme: *const Widget.Theme) bool {
            self.plane.set_base_style(if (self.active) theme.scrollbar_active else if (self.hover) theme.scrollbar_hover else theme.scrollbar);
            self.plane.erase();
            self.plane.home();
            _ = self.plane.print(" {s} ", .{self.opts.label}) catch {};
            return false;
        }

        pub fn on_layout_default(_: *context, self: *ButtonType) Widget.Layout {
            return .{ .static = self.opts.label.len + 2 };
        }

        pub fn on_receive_default(_: *context, _: *ButtonType, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
            return false;
        }
    };
}

pub fn create(ctx_type: type, allocator: std.mem.Allocator, parent: Plane, opts: Options(ctx_type)) error{OutOfMemory}!*Options(ctx_type).ButtonType {
    const Self = Options(ctx_type).ButtonType;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    var n = try Plane.init(&opts.pos.opts(@typeName(Self)), parent);
    errdefer n.deinit();
    self.* = .{
        .allocator = allocator,
        .parent = parent,
        .plane = n,
        .opts = opts,
    };
    self.opts.label = try self.allocator.dupe(u8, opts.label);
    errdefer allocator.free(self.opts.label);
    try self.init();
    return self;
}

pub fn create_widget(ctx_type: type, allocator: std.mem.Allocator, parent: Plane, opts: Options(ctx_type)) error{OutOfMemory}!Widget {
    return Widget.to(try create(ctx_type, allocator, parent, opts));
}

fn State(ctx_type: type) type {
    return struct {
        allocator: std.mem.Allocator,
        parent: Plane,
        plane: Plane,
        active: bool = false,
        hover: bool = false,
        drag_anchor: ?Widget.Pos = null,
        drag_anchor_offset: ?Widget.Pos = null,
        drag_pos: ?Widget.Pos = null,
        drag_pos_offset: ?Widget.Pos = null,
        opts: Options(ctx_type),

        const Self = @This();
        pub const Context = ctx_type;
        const child: type = switch (@typeInfo(Context)) {
            .pointer => |p| p.child,
            .@"struct" => Context,
            else => struct {},
        };

        pub fn init(self: *Self) error{OutOfMemory}!void {
            if (@hasDecl(child, "ctx_init")) return self.opts.ctx.ctx_init();
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (@hasDecl(child, "ctx_deinit")) self.opts.ctx.ctx_deinit();
            self.allocator.free(self.opts.label);
            self.plane.deinit();
            allocator.destroy(self);
        }

        pub fn update_label(self: *Self, label: []const u8) error{OutOfMemory}!void {
            self.allocator.free(self.opts.label);
            self.opts.label = try self.allocator.dupe(u8, label);
        }

        pub fn layout(self: *Self) Widget.Layout {
            return self.opts.on_layout(&self.opts.ctx, self);
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            return self.opts.on_render(&self.opts.ctx, self, theme);
        }

        pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var btn: MouseEvent.Button = .none;
            var coord: MouseEvent.Coord = undefined;
            if (try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.extract(&coord), tp.any })) {
                switch (btn) {
                    .left => {
                        self.active = true;
                        self.drag_anchor = self.to_rel_cursor(coord);
                        self.drag_anchor_offset = self.sub_cell_offset(coord);
                        tui.need_render(@src());
                    },
                    .wheel_up, .wheel_down => {
                        self.call_click_handler(btn, self.to_rel_cursor(coord));
                        return true;
                    },
                    else => {},
                }
                return true;
            } else if (try m.match(.{ MouseEvent.Type.release, tp.extract(&btn), tp.extract(&coord), tp.any })) {
                self.drag_anchor = null;
                self.drag_anchor_offset = null;
                self.drag_pos = null;
                self.drag_pos_offset = null;
                self.call_click_handler(btn, self.to_rel_cursor(coord));
                tui.need_render(@src());
                return true;
            } else if (try m.match(.{ MouseEvent.Type.drag, tp.extract(&btn), tp.extract(&coord), tp.any })) {
                self.drag_pos = self.to_abs_cursor(coord);
                self.drag_pos_offset = self.sub_cell_offset(coord);
                if (self.opts.on_event) |h| {
                    self.active = false;
                    h.send(from, m) catch {};
                }
                return true;
            } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
                tui.rdr().request_mouse_cursor(self.opts.cursor, self.hover);
                tui.need_render(@src());
                return true;
            }
            self.drag_anchor = null;
            self.drag_anchor_offset = null;
            self.drag_pos = null;
            self.drag_pos_offset = null;
            return self.opts.on_receive(&self.opts.ctx, self, from, m);
        }

        fn to_rel_cursor(self: *const Self, coord: MouseEvent.Coord) Widget.Pos {
            const cell = coord.to_cell(self.plane.mouse_geometry());
            return .{ .y = cell.row, .x = cell.col };
        }

        fn to_abs_cursor(self: *const Self, coord: MouseEvent.Coord) Widget.Pos {
            const cell = coord.to_cell(.{ .cell_width = self.plane.cell_x(), .cell_height = self.plane.cell_y() });
            return .{ .y = cell.row, .x = cell.col };
        }

        fn sub_cell_offset(self: *const Self, coord: MouseEvent.Coord) Widget.Pos {
            const cell = coord.to_cell(self.plane.mouse_geometry());
            return .{ .y = @intCast(cell.yoffset), .x = @intCast(cell.xoffset) };
        }

        fn call_click_handler(self: *Self, btn: MouseEvent.Button, pos: Widget.Pos) void {
            if (btn == .left) {
                if (!self.active) return;
                self.active = false;
            }
            if (!self.hover) return;
            switch (btn) {
                .left => self.opts.on_click(&self.opts.ctx, self, pos),
                .middle => self.opts.on_click2(&self.opts.ctx, self, pos),
                .right => self.opts.on_click3(&self.opts.ctx, self, pos),
                .wheel_up => self.opts.on_click4(&self.opts.ctx, self, pos),
                .wheel_down => self.opts.on_click5(&self.opts.ctx, self, pos),
                else => {},
            }
        }
    };
}
