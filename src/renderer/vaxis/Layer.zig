const std = @import("std");
const vaxis = @import("vaxis");

pub const Plane = @import("Plane.zig");
const GraphemeCache = @import("GraphemeCache.zig");

const Layer = @This();

allocator: std.mem.Allocator,
screen: vaxis.Screen,
cache_storage: GraphemeCache.Storage = .{},
y_off: i32 = 0,
x_off: i32 = 0,
plane_: Plane,

pub const Options = struct {
    y: i32 = 0,
    x: i32 = 0,
    h: u16 = 0,
    w: u16 = 0,
};

pub fn init(allocator: std.mem.Allocator, opts: Options) std.mem.Allocator.Error!*Layer {
    const self = try allocator.create(Layer);
    self.* = .{
        .allocator = allocator,
        .screen = try vaxis.Screen.init(allocator, .{
            .rows = opts.h,
            .cols = opts.w,
            .x_pixel = 0,
            .y_pixel = 0,
        }),
        .y_off = opts.y,
        .x_off = opts.x,
        .plane_ = undefined,
    };
    const name = "layer";
    self.plane_ = .{
        .window = self.window(),
        .cache = self.cache_storage.cache(),
        .name_buf = undefined,
        .name_len = name.len,
    };
    @memcpy(self.plane_.name_buf[0..name.len], name);
    return self;
}

pub fn deinit(self: *Layer) void {
    self.screen.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn window(self: *Layer) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = self.screen.width,
        .height = self.screen.height,
        .screen = &self.screen,
    };
}

pub fn plane(self: *Layer) *Plane {
    return &self.plane_;
}

pub fn draw(self: *const Layer, plane_: Plane) void {
    if (self.x_off >= plane_.window.width) return;
    if (self.y_off >= plane_.window.height) return;

    const src_y = 0;
    const src_x = 0;
    const src_h: usize = self.screen.height;
    const src_w = self.screen.width;

    const dst_dim_y: i32 = @intCast(plane_.dim_y());
    const dst_dim_x: i32 = @intCast(plane_.dim_x());
    const dst_y = self.y_off;
    const dst_x = self.x_off;
    const dst_w = @min(src_w, dst_dim_x - dst_x);

    for (src_y..src_h) |src_row_| {
        const src_row: i32 = @intCast(src_row_);
        const src_row_offset = src_row * src_w;
        const dst_row_offset = (dst_y + src_row) * plane_.window.screen.width;
        if (dst_y + src_row >= dst_dim_y) return;
        @memcpy(
            plane_.window.screen.buf[@intCast(dst_row_offset + dst_x)..@intCast(dst_row_offset + dst_x + dst_w)],
            self.screen.buf[@intCast(src_row_offset + src_x)..@intCast(src_row_offset + dst_w)],
        );
    }
}
