const std = @import("std");
const Allocator = std.mem.Allocator;
const Plane = @import("renderer").Plane;
const Layer = @import("renderer").Layer;
const MouseEvent = @import("MouseEvent");

const tui = @import("tui.zig");

const Self = @This();

layer: *Layer,
plane: Plane,

pub fn init(allocator: Allocator, id: *?Layer.Id) error{OutOfMemory}!Self {
    const id_ = id.* orelse blk: {
        const new_id = Layer.next_id();
        id.* = new_id;
        break :blk new_id;
    };
    const layer = try Layer.init(allocator, .{ .h = 1, .w = 1, .id = id_ });
    return .{ .layer = layer, .plane = layer.plane() };
}

pub fn deinit(self: *Self) void {
    self.layer.deinit();
}

pub fn prepare(self: *Self, view: *const Plane, rows: usize) void {
    const root = tui.plane();
    const cols = view.dim_x();
    const cw: usize = @intCast(root.cell_x());
    const ch: usize = @intCast(root.cell_y());
    self.layer.resize(@intCast(cols), @intCast(rows), @intCast(cols * cw), @intCast(rows * ch)) catch return;
    self.plane = self.layer.plane();
}

pub fn submit(self: *Self, view: *const Plane, pos: MouseEvent.Cell, view_px: struct { usize, usize }) void {
    const root = tui.plane();
    const cw: i32 = root.cell_x();
    const ch: i32 = root.cell_y();
    const x, const y = view.global_origin_px();
    const w: i32 = if (view_px[0] > 0) @intCast(view_px[0]) else @as(i32, @intCast(view.dim_x())) * cw;
    const h: i32 = if (view_px[1] > 0) @intCast(view_px[1]) else @as(i32, @intCast(view.dim_y())) * ch;
    const frame: Layer.Frame = .{ .x = x, .y = y, .w = w, .h = h };
    const ox = x - pos.xoffset;
    const oy = y - pos.yoffset;
    self.layer.origin_px_x = ox;
    self.layer.origin_px_y = oy;
    self.layer.clip = frame;
    self.layer.z_index = if (view.layer) |l| @fromBackingInt(@intCast(@backingInt(l.z_index) + 1)) else .main;
    _ = tui.submit_layer(.{
        .src = self.layer,
        .dst = root.window,
        .x = @divFloor(ox, cw),
        .y = @divFloor(oy, ch),
        .xoffset = @intCast(@mod(ox, cw)),
        .yoffset = @intCast(@mod(oy, ch)),
        .z_index = self.layer.z_index,
        .blend = .replace,
        .clip = frame,
    });
}
