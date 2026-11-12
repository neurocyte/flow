const Allocator = @import("std").mem.Allocator;
const renderer = @import("renderer");
const Layer = renderer.Layer;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

layer: ?*Layer = null,

pub const Edges = struct {
    head: bool,
    tail: bool,
};

pub fn deinit(self: *Self) void {
    if (self.layer) |layer| layer.deinit();
    self.layer = null;
}

pub fn submit(
    self: *Self,
    allocator: Allocator,
    view: Layer.Frame,
    direction: Widget.Direction,
    edges: Edges,
    cells: u16,
    color: Widget.Theme.Color,
    z_index: Layer.Level,
) void {
    if (cells == 0) return;
    if (!edges.head and !edges.tail) return;

    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();

    const across_px: i32 = switch (direction) {
        .horizontal => view.h,
        .vertical => view.w,
    };
    if (across_px <= 0) return;
    const w_px: u16 = @intCast(switch (direction) {
        .horizontal => cw,
        .vertical => across_px,
    });
    const h_px: u16 = @intCast(switch (direction) {
        .horizontal => across_px,
        .vertical => ch,
    });
    const across_cells: u16 = @intCast(@max(1, @divTrunc(across_px, switch (direction) {
        .horizontal => ch,
        .vertical => cw,
    })));

    const fade = self.layer orelse blk: {
        const new = Layer.init(allocator, .{ .h = 1, .w = 1 }) catch return;
        self.layer = new;
        break :blk new;
    };
    fade.resize(
        switch (direction) {
            .horizontal => 1,
            .vertical => across_cells,
        },
        switch (direction) {
            .horizontal => across_cells,
            .vertical => 1,
        },
        w_px,
        h_px,
    ) catch return;
    fade.background = color.color;
    var plane = fade.plane();
    plane.set_base_style(.{ .bg = color });
    plane.erase();

    const steps: i32 = @intCast(cells);
    var i: i32 = 0;
    while (i < steps) : (i += 1) {
        const alpha: u8 = @intCast(@divTrunc(255 * (steps - i), steps + 1));
        if (edges.head) submit_sliver(fade, view, direction, i, alpha, z_index, cw, ch);
        if (edges.tail) submit_sliver(fade, view, direction, -(i + 1), alpha, z_index, cw, ch);
    }
}

fn submit_sliver(
    fade: *Layer,
    view: Layer.Frame,
    direction: Widget.Direction,
    slot: i32,
    alpha: u8,
    z_index: Layer.Level,
    cw: i32,
    ch: i32,
) void {
    const along_px: i32 = switch (direction) {
        .horizontal => if (slot >= 0) view.x + slot * cw else view.right() + slot * cw,
        .vertical => if (slot >= 0) view.y + slot * ch else view.bottom() + slot * ch,
    };
    const px: i32, const py: i32 = switch (direction) {
        .horizontal => .{ along_px, view.y },
        .vertical => .{ view.x, along_px },
    };
    _ = tui.submit_layer(.{
        .src = fade,
        .dst = tui.plane().window,
        .x = @divFloor(px, cw),
        .y = @divFloor(py, ch),
        .xoffset = @intCast(@mod(px, cw)),
        .yoffset = @intCast(@mod(py, ch)),
        .blend = .src_over,
        .alpha = alpha,
        .z_index = @fromBackingInt(@intCast(@backingInt(z_index) + 1)),
        .clip = view,
    });
}
