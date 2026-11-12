const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Plane = @import("renderer").Plane;
const Layer = @import("renderer").Layer;
const MouseEvent = @import("MouseEvent");

const tui = @import("tui.zig");

const Self = @This();

const use_layer = build_options.gui;

layer: if (use_layer) *Layer else void,
plane: Plane = undefined,

pub const Options = struct {
    margin_cols: usize = 0,
    /// composite into the layer of the view, submit after it
    parent: ?Layer.Handle = null,
};

pub fn init(allocator: Allocator, id: *?Layer.Id) error{OutOfMemory}!Self {
    if (!use_layer) return .{ .layer = {} };
    const id_ = id.* orelse blk: {
        const new_id = Layer.next_id();
        id.* = new_id;
        break :blk new_id;
    };
    const layer = try Layer.init(allocator, .{ .h = 1, .w = 1, .id = id_ });
    return .{ .layer = layer, .plane = layer.plane() };
}

pub fn deinit(self: *Self) void {
    if (use_layer) self.layer.deinit();
}

pub fn prepare(self: *Self, view: *const Plane, rows: usize, cols: usize) void {
    if (!use_layer) {
        self.plane = view.*;
        return;
    }
    const root = tui.plane();
    const cw: usize = @intCast(root.cell_x());
    const ch: usize = @intCast(root.cell_y());
    self.layer.resize(@intCast(cols), @intCast(rows), @intCast(cols * cw), @intCast(rows * ch)) catch return;
    self.plane = self.layer.plane();
}

pub fn submit(self: *Self, view: *const Plane, pos: MouseEvent.Cell, view_px: struct { usize, usize }, opts: Options) void {
    if (!use_layer) return;
    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    const abs_x, const abs_y = view.global_origin_px();
    var x = abs_x;
    var y = abs_y;
    var z: Layer.Level = .main;
    if (view.layer) |l| {
        z = @fromBackingInt(@intCast(@backingInt(l.z_index) + 1));
        if (opts.parent != null) {
            const px, const py = l.global_origin_px();
            x -= px;
            y -= py;
            z = l.z_index;
        }
    }
    const w: i32 = if (view_px[0] > 0) @intCast(view_px[0]) else @as(i32, @intCast(view.dim_x())) * cw;
    const h: i32 = if (view_px[1] > 0) @intCast(view_px[1]) else @as(i32, @intCast(view.dim_y())) * ch;
    const margin: i32 = @as(i32, @intCast(opts.margin_cols)) * cw;
    const clip: Layer.Frame = .{ .x = x + margin, .y = y, .w = @max(0, w - margin), .h = h };
    const ox = x - pos.xoffset;
    const oy = y - pos.yoffset;
    self.layer.clip = .{ .x = abs_x + margin, .y = abs_y, .w = clip.w, .h = clip.h };
    self.layer.z_index = z;
    _ = tui.submit_layer(.{
        .src = self.layer,
        .dst = root.window,
        .parent = opts.parent,
        .x = @divFloor(ox, cw),
        .y = @divFloor(oy, ch),
        .xoffset = @intCast(@mod(ox, cw)),
        .yoffset = @intCast(@mod(oy, ch)),
        .z_index = z,
        .blend = .replace,
        .clip = clip,
    });
}

pub fn geometry(self: *const Self, view: *const Plane) MouseEvent.Geometry {
    if (!use_layer) return view.mouse_geometry();
    return self.plane.mouse_geometry();
}

pub fn over_level(self: *const Self, view: *const Plane) Layer.Level {
    if (!use_layer) return if (view.layer) |l| l.z_index else .root;
    return @fromBackingInt(@intCast(@backingInt(self.layer.z_index) + 1));
}
