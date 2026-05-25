const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const tp = @import("thespian");

const renderer = @import("renderer");
const Plane = renderer.Plane;
const Layer = renderer.Layer;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Box = @import("Box.zig");

const Self = @This();

pub const Direction = Widget.Direction;
pub const Layout = Widget.Layout;

const WidgetState = struct {
    widget: Widget,
    layout: Layout = .dynamic,
};

plane: Plane,
parent: Plane,
allocator: Allocator,
widgets: ArrayList(WidgetState),
layout_: Layout,
layout_empty: bool = true,
direction: Direction,
deco_box: Widget.Box,
trailing_layer: ?*Layer = null,
ctx: ?*anyopaque = null,
on_render: *const fn (ctx: ?*anyopaque, theme: *const Widget.Theme) void = on_render_default,
render_decoration: ?*const fn (self: *Self, theme: *const Widget.Theme, widget_style: *const Widget.Style) void = render_decoration_default,
after_render: *const fn (ctx: ?*anyopaque, theme: *const Widget.Theme) void = on_render_default,
prepare_resize: *const fn (ctx: ?*anyopaque, self: *Self, box: Widget.Box) Widget.Box = prepare_resize_default,
after_resize: *const fn (ctx: ?*anyopaque, self: *Self, box: Widget.Box) void = after_resize_default,
on_layout: *const fn (ctx: ?*anyopaque, self: *Self) Widget.Layout = on_layout_default,
widget_type: Widget.Type,

pub fn createH(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout) error{OutOfMemory}!*Self {
    return createHStyled(allocator, parent, name, layout_, .none);
}

pub fn createHStyled(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout, widget_type: Widget.Type) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = try init(allocator, parent, name, .horizontal, layout_, Box{}, widget_type);
    self.plane.hide();
    return self;
}

pub fn createV(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout) !*Self {
    return createVStyled(allocator, parent, name, layout_, .none);
}

pub fn createVStyled(allocator: Allocator, parent: Plane, name: [:0]const u8, layout_: Layout, widget_type: Widget.Type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = try init(allocator, parent, name, .vertical, layout_, Box{}, widget_type);
    self.plane.hide();
    return self;
}

pub fn createBox(allocator: Allocator, parent: Plane, name: [:0]const u8, dir: Direction, layout_: Layout, box: Box) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = try init(allocator, parent, name, dir, layout_, box);
    self.plane.hide();
    return self;
}

fn init(allocator: Allocator, parent: Plane, name: [:0]const u8, dir: Direction, layout_: Layout, box_: Box, widget_type: Widget.Type) !Self {
    var self: Self = .{
        .plane = undefined,
        .parent = parent,
        .allocator = allocator,
        .widgets = .empty,
        .layout_ = layout_,
        .direction = dir,
        .widget_type = widget_type,
        .deco_box = undefined,
    };
    const padding = tui.get_widget_style(self.widget_type).padding;
    self.deco_box = box_.from_client_box(padding);
    self.plane = try Plane.init(&self.deco_box.opts(name), parent);
    return self;
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn layout(self: *Self) Widget.Layout {
    return self.on_layout(self.ctx, self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.allocator);
    self.widgets.deinit(self.allocator);
    if (self.trailing_layer) |layer| layer.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn add(self: *Self, w_: Widget) !void {
    _ = try self.addP(w_);
}

pub fn addP(self: *Self, w_: Widget) !*Widget {
    var w: *WidgetState = try self.widgets.addOne(self.allocator);
    w.* = .{
        .widget = w_,
        .layout = w_.layout(),
    };
    return &w.widget;
}

fn count_trailing_statics(self: *const Self) usize {
    var count: usize = 0;
    var i = self.widgets.items.len;
    var saw_dynamic = false;
    while (i > 0) {
        i -= 1;
        switch (self.widgets.items[i].layout) {
            .static => count += 1,
            .dynamic => {
                saw_dynamic = true;
                break;
            },
        }
    }
    return if (saw_dynamic) count else 0;
}

pub fn get(self: *const Self, name_: []const u8) ?Widget {
    for (self.widgets.items) |*w|
        if (w.widget.get(name_)) |p|
            return p;
    return null;
}

pub fn get_at(self: *const Self, n: usize) ?*Widget {
    return if (n < self.widgets.items.len) &self.widgets.items[n].widget else null;
}

pub fn remove(self: *Self, w: Widget) void {
    for (self.widgets.items, 0..) |p, i| if (p.widget.ptr == w.ptr) {
        self.widgets.orderedRemove(i).widget.deinit(self.allocator);
        return;
    };
}

pub fn remove_all(self: *Self) void {
    for (self.widgets.items) |*w|
        w.widget.deinit(self.allocator);
    self.widgets.clearRetainingCapacity();
}

pub fn pop(self: *Self) ?Widget {
    return if (self.widgets.pop()) |ws| ws.widget else null;
}

pub fn empty(self: *const Self) bool {
    return self.widgets.items.len == 0;
}

pub fn swap(self: *Self, n: usize, w: Widget) Widget {
    const old = self.widgets.items[n];
    self.widgets.items[n].widget = w;
    self.widgets.items[n].layout = w.layout();
    return old.widget;
}

pub fn delete(self: *Self, n: usize) void {
    self.widgets.orderedRemove(n).widget.deinit(self.allocator);
}

pub fn replace(self: *Self, n: usize, w: Widget) void {
    const old = self.swap(n, w);
    old.deinit(self.allocator);
}

pub fn send(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    for (self.widgets.items) |*w|
        if (try w.widget.send(from, m))
            return true;
    return false;
}

pub fn update(self: *Self) void {
    for (self.widgets.items) |*w|
        w.widget.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const widget_style = tui.get_widget_style(self.widget_type);
    const padding = widget_style.padding;
    for (self.widgets.items) |*w| if (!w.layout.eql(w.widget.layout())) {
        self.refresh_layout(padding);
        break;
    };

    self.on_render(self.ctx, theme);
    if (self.render_decoration) |render_decoration| render_decoration(self, theme, widget_style);

    const client_box = self.deco_box.to_client_box(padding);
    const widget_count = self.widgets.items.len;
    const trailing_count = self.count_trailing_statics();
    const main_count = widget_count - trailing_count;
    const use_layer = trailing_count > 0 and self.subcell_remainder_a() > 0;

    var more = false;
    for (self.widgets.items[0..main_count]) |*w| {
        const widget_box = w.widget.box();
        if (client_box.y + client_box.h <= widget_box.y) break;
        if (client_box.x + client_box.w <= widget_box.x) break;
        if (w.widget.render(theme)) more = true;
    }

    if (trailing_count > 0) {
        if (use_layer) if (self.trailing_layer) |layer| {
            _ = tui.submit_layer(self.build_trailing_target(layer, &client_box, trailing_count));
        };
        for (self.widgets.items[main_count..]) |*w| {
            if (w.widget.render(theme)) more = true;
        }
    }

    self.after_render(self.ctx, theme);
    return more;
}

fn build_trailing_target(self: *Self, layer: *Layer, client_box: *const Widget.Box, trailing_count: usize) Layer.Target {
    const trailing_cells = self.sum_trailing_cells(trailing_count);
    const remainder = self.subcell_remainder_a();
    const leading_cell = self.get_loc_a_const(client_box) + self.get_size_a_const(client_box) -| trailing_cells;

    var target: Layer.Target = .{
        .src = layer,
        .dst = tui.plane().window,
    };

    const cw: i32 = @max(@as(i32, @intCast(self.plane.cell_x())), 1);
    const ch: i32 = @max(@as(i32, @intCast(self.plane.cell_y())), 1);
    var parent_ox: i32 = 0;
    var parent_oy: i32 = 0;
    if (self.plane.parent_surface) |s| parent_ox, parent_oy = s.global_origin_px();

    const loc_b: i32 = @intCast(self.get_loc_b_const(client_box));
    const lead: i32 = @intCast(leading_cell);

    const local_pix_a: i32 = lead * (switch (self.direction) {
        .vertical => ch,
        .horizontal => cw,
    }) + @as(i32, remainder);
    const local_pix_b: i32 = loc_b * (switch (self.direction) {
        .vertical => cw,
        .horizontal => ch,
    });

    const global_pix_a: i32 = (switch (self.direction) {
        .vertical => parent_oy,
        .horizontal => parent_ox,
    }) + local_pix_a;
    const global_pix_b: i32 = (switch (self.direction) {
        .vertical => parent_ox,
        .horizontal => parent_oy,
    }) + local_pix_b;

    const a_cell: i32 = @divFloor(global_pix_a, switch (self.direction) {
        .vertical => ch,
        .horizontal => cw,
    });
    const a_offset: i16 = @intCast(@mod(global_pix_a, switch (self.direction) {
        .vertical => ch,
        .horizontal => cw,
    }));
    const b_cell: i32 = @divFloor(global_pix_b, switch (self.direction) {
        .vertical => cw,
        .horizontal => ch,
    });
    const b_offset: i16 = @intCast(@mod(global_pix_b, switch (self.direction) {
        .vertical => cw,
        .horizontal => ch,
    }));

    switch (self.direction) {
        .vertical => {
            target.y = a_cell;
            target.yoffset = a_offset;
            target.x = b_cell;
            target.xoffset = b_offset;
        },
        .horizontal => {
            target.x = a_cell;
            target.xoffset = a_offset;
            target.y = b_cell;
            target.yoffset = b_offset;
        },
    }
    return target;
}

fn sum_trailing_cells(self: *const Self, trailing_count: usize) usize {
    var sum: usize = 0;
    const main_count = self.widgets.items.len - trailing_count;
    for (self.widgets.items[main_count..]) |*w| switch (w.layout) {
        .static => |val| sum += val,
        .dynamic => {},
    };
    return sum;
}

fn subcell_remainder_a(self: *Self) i16 {
    const screen = self.plane.window.screen;
    const cells: u16 = switch (self.direction) {
        .vertical => screen.height,
        .horizontal => screen.width,
    };
    const pixels: u16 = switch (self.direction) {
        .vertical => screen.height_pix,
        .horizontal => screen.width_pix,
    };
    if (cells == 0 or pixels == 0) return 0;
    const tail_cell: usize = switch (self.direction) {
        .vertical => self.deco_box.y + self.deco_box.h,
        .horizontal => self.deco_box.x + self.deco_box.w,
    };
    if (tail_cell != cells) return 0;
    const cell_size: u16 = pixels / cells;
    const remainder: u16 = pixels - cell_size * cells;
    return @intCast(remainder);
}

fn on_render_default(_: ?*anyopaque, _: *const Widget.Theme) void {}

fn render_decoration_default(self: *Self, theme: *const Widget.Theme, widget_style: *const Widget.Style) void {
    widget_style.render_decoration(self.deco_box, self.widget_type, &self.plane, theme);
}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "H", tp.more }))
        return false;

    for (self.widgets.items) |*w|
        if (try w.widget.send(from_, m))
            return true;
    return false;
}

fn get_size_a_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.h,
        .horizontal => pos.w,
    };
}

fn get_size_a(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.h,
        .horizontal => &pos.w,
    };
}

fn get_size_b_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.w,
        .horizontal => pos.h,
    };
}

fn get_size_b(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.w,
        .horizontal => &pos.h,
    };
}

fn get_loc_a_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.y,
        .horizontal => pos.x,
    };
}

fn get_loc_a(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.y,
        .horizontal => &pos.x,
    };
}

fn get_loc_b_const(self: *Self, pos: *const Widget.Box) usize {
    return switch (self.direction) {
        .vertical => pos.x,
        .horizontal => pos.y,
    };
}

fn get_loc_b(self: *Self, pos: *Widget.Box) *usize {
    return switch (self.direction) {
        .vertical => &pos.x,
        .horizontal => &pos.y,
    };
}

fn refresh_layout(self: *Self, padding: Widget.Style.Margin) void {
    return self.handle_resize(self.deco_box.to_client_box(padding));
}

pub fn handle_resize(self: *Self, box: Widget.Box) void {
    const padding = tui.get_widget_style(self.widget_type).padding;
    const client_box_ = self.prepare_resize(self.ctx, self, box.to_client_box(padding));
    self.deco_box = client_box_.from_client_box(padding);
    self.do_resize(padding);
    self.after_resize(self.ctx, self, self.deco_box.to_client_box(padding));
}

fn prepare_resize_default(_: ?*anyopaque, _: *Self, box: Widget.Box) Widget.Box {
    return box;
}

fn after_resize_default(_: ?*anyopaque, _: *Self, _: Widget.Box) void {}

fn on_layout_default(_: ?*anyopaque, self: *Self) Widget.Layout {
    return self.layout_;
}

pub fn resize(self: *Self, box: Widget.Box) void {
    return self.handle_resize(box);
}

fn do_resize(self: *Self, padding: Widget.Style.Margin) void {
    const client_box = self.deco_box.to_client_box(padding);
    const deco_box = self.deco_box;
    self.plane.move_yx(@intCast(deco_box.y), @intCast(deco_box.x)) catch return;
    self.plane.resize_simple(@intCast(deco_box.h), @intCast(deco_box.w)) catch return;
    const total = self.get_size_a_const(&client_box);

    for (self.widgets.items) |*w| w.layout = w.widget.layout();
    const widget_count = self.widgets.items.len;
    const trailing_count = self.count_trailing_statics();
    const main_count = widget_count - trailing_count;

    const remainder = self.subcell_remainder_a();
    const use_layer = trailing_count > 0 and remainder > 0;

    var trailing_cells: usize = 0;
    for (self.widgets.items[main_count..]) |*w| switch (w.layout) {
        .static => |val| trailing_cells += val,
        .dynamic => {},
    };

    if (use_layer and self.trailing_layer == null)
        self.trailing_layer = Layer.init(self.allocator, .{ .h = 1, .w = 1 }) catch null;

    self.reparent_main();
    if (use_layer) if (self.trailing_layer) |layer|
        reparent_subtrees(self.widgets.items[main_count..], &layer.surface, &layer.screen);

    var avail = total;
    if (use_layer) avail = if (avail > trailing_cells) avail - trailing_cells else 0;
    var dynamics: usize = 0;
    const main_end_for_count = if (use_layer) main_count else widget_count;
    for (self.widgets.items[0..main_end_for_count]) |*w| switch (w.layout) {
        .dynamic => dynamics += 1,
        .static => |val| avail = if (avail > val) avail - val else 0,
    };

    if (use_layer and dynamics > 0 and avail + 1 <= total) avail += 1;

    self.layout_empty = avail == total and dynamics == 0 and trailing_count == 0;

    const dyn_size = avail / if (dynamics > 0) dynamics else 1;
    const rounded: usize = if (dyn_size * dynamics < avail) avail - dyn_size * dynamics else 0;
    var cur_loc: usize = self.get_loc_a_const(&client_box);
    var first = true;

    for (self.widgets.items[0..main_end_for_count]) |*w| {
        var w_pos: Box = .{};
        const size = switch (w.layout) {
            .dynamic => if (first) val: {
                first = false;
                break :val dyn_size + rounded;
            } else dyn_size,
            .static => |val| val,
        };
        self.get_size_a(&w_pos).* = size;
        self.get_loc_a(&w_pos).* = cur_loc;
        cur_loc += size;
        self.get_size_b(&w_pos).* = self.get_size_b_const(&client_box);
        self.get_loc_b(&w_pos).* = self.get_loc_b_const(&client_box);
        w.widget.resize(w_pos);
    }

    if (use_layer) if (self.trailing_layer) |layer| {
        const perp = self.get_size_b_const(&client_box);
        const layer_w: u16 = @intCast(switch (self.direction) {
            .vertical => perp,
            .horizontal => trailing_cells,
        });
        const layer_h: u16 = @intCast(switch (self.direction) {
            .vertical => trailing_cells,
            .horizontal => perp,
        });
        const cell_x: u16 = self.plane.cell_x();
        const cell_y: u16 = self.plane.cell_y();

        const screen = self.plane.window.screen;
        const perp_at_edge: bool = switch (self.direction) {
            .vertical => self.deco_box.x + perp == screen.width,
            .horizontal => self.deco_box.y + perp == screen.height,
        };
        const perp_pix: u16 = blk: {
            const cell_aligned: u16 = @as(u16, @intCast(perp)) * (switch (self.direction) {
                .vertical => cell_x,
                .horizontal => cell_y,
            });
            if (!perp_at_edge) break :blk cell_aligned;
            const screen_perp_pix: u16 = switch (self.direction) {
                .vertical => screen.width_pix,
                .horizontal => screen.height_pix,
            };
            break :blk @max(cell_aligned, screen_perp_pix);
        };
        const layer_w_pix: u16 = switch (self.direction) {
            .vertical => perp_pix,
            .horizontal => @as(u16, layer_w) * cell_x,
        };
        const layer_h_pix: u16 = switch (self.direction) {
            .vertical => @as(u16, layer_h) * cell_y,
            .horizontal => perp_pix,
        };
        layer.resize(layer_w, layer_h, layer_w_pix, layer_h_pix) catch return;
        var local_loc: usize = 0;
        for (self.widgets.items[main_count..]) |*w| {
            var w_pos: Box = .{};
            const size: usize = switch (w.layout) {
                .static => |val| val,
                .dynamic => 0,
            };
            self.get_size_a(&w_pos).* = size;
            self.get_loc_a(&w_pos).* = local_loc;
            local_loc += size;
            self.get_size_b(&w_pos).* = perp;
            self.get_loc_b(&w_pos).* = 0;
            w.widget.resize(w_pos);
        }
    };
}

const ReparentCtx = struct {
    surface: ?*const Plane.Surface,
    screen: *renderer.vaxis.Screen,
};

fn reparent_walker(ctx_: *anyopaque, w: Widget) bool {
    const ctx: *const ReparentCtx = @ptrCast(@alignCast(ctx_));
    w.plane.window.screen = ctx.screen;
    w.plane.parent_surface = ctx.surface;
    return false;
}

fn reparent_subtrees(items: []WidgetState, surface: ?*const Plane.Surface, screen: *renderer.vaxis.Screen) void {
    var ctx: ReparentCtx = .{ .surface = surface, .screen = screen };
    for (items) |*w| _ = w.widget.walk(@ptrCast(&ctx), reparent_walker);
}

fn reparent_main(self: *Self) void {
    const trailing_count = self.count_trailing_statics();
    const main_end = self.widgets.items.len - trailing_count;
    reparent_subtrees(self.widgets.items[0..main_end], self.plane.parent_surface, self.plane.window.screen);
    if (self.subcell_remainder_a() == 0)
        reparent_subtrees(self.widgets.items[main_end..], self.plane.parent_surface, self.plane.window.screen);
}

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn) bool {
    for (self.widgets.items) |*w|
        if (w.widget.walk(ctx, f)) return true;
    return f(ctx, Widget.to(self));
}

pub fn focus(self: *Self) void {
    for (self.widgets.items) |*w| w.widget.focus();
}

pub fn unfocus(self: *Self) void {
    for (self.widgets.items) |*w| w.widget.unfocus();
}

pub fn hover(self: *Self) bool {
    for (self.widgets.items) |*w| if (w.widget.hover()) return true;
    return false;
}
