//! a one-row overlay layer in the bottom row of an area, for short status text

const std = @import("std");
const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

name: [:0]const u8,
layer: ?*tui.WidgetLayerBox = null,

pub const Align = enum { left, right };

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.layer) |layer| layer.deinit(allocator);
    self.layer = null;
}

/// the area of `plane`, with its pixel frame
pub fn area_of(plane: Plane) Widget.Box {
    const x, const y = plane.global_origin_px();
    var box: Widget.Box = .from(plane);
    box.frame = .{
        .x = x,
        .y = y,
        .w = @as(i32, @intCast(plane.dim_x())) * plane.cell_x(),
        .h = @as(i32, @intCast(plane.dim_y())) * plane.cell_y(),
    };
    return box;
}

/// draw ` text ` in the bottom row of `area`, cut with "…" to the width of `area`
pub fn render(self: *Self, allocator: std.mem.Allocator, theme: *const Widget.Theme, area: Widget.Box, alignment: Align, text: []const u8, style: Widget.Theme.Style) error{ NoSpace, OutOfMemory }!void {
    const screen_plane = tui.plane();
    const cw: i32 = screen_plane.cell_x();
    const ch: i32 = screen_plane.cell_y();
    const frame = area.resolve_frame(cw, ch);
    if (frame.y < 0 or frame.h < ch or frame.w <= 0) return error.NoSpace;

    const needed = 1 + tui.egc_chunk_width(text, 0, 8) + 1;
    const text_width_px: i32 = @as(i32, @intCast(needed)) * cw;
    const width_px = @min(text_width_px, frame.w);
    const x_px = switch (alignment) {
        .left => frame.x,
        .right => frame.x + frame.w - width_px,
    };
    const w_cells: usize = @intCast(@max(1, @divFloor(width_px + cw - 1, cw)));

    const layer = self.layer orelse blk: {
        const layer = try tui.WidgetLayerBox.create(allocator, tui.plane(), .{ .name = self.name });
        layer.shadow = .{ .edges = .{ .bottom = false, .right = false } };
        self.layer = layer;
        break :blk layer;
    };
    // a line that touches the right window edge gets no shadow on that edge
    if (layer.shadow) |*shadow| shadow.edges.right = x_px + width_px < tui.window_frame().w;
    layer.handle_resize(.{
        .w = w_cells,
        .h = 1,
        .frame = .{ .x = x_px, .y = frame.y + frame.h - ch, .w = width_px, .h = ch },
    });

    var plane = layer.inner_plane();
    plane.set_base_style(theme.statusbar);
    plane.erase();
    plane.home();
    plane.set_style(theme.statusbar);
    plane.fill(" ");
    plane.home();
    plane.set_style(style);
    _ = plane.print(" {s} ", .{text}) catch {};
    if (text_width_px > width_px) {
        plane.cursor_move_yx(0, @intCast(w_cells -| 2));
        _ = plane.print("… ", .{}) catch {};
    }
    _ = layer.widget().render(theme);
}
