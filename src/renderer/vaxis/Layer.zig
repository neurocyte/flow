const std = @import("std");
const vaxis = @import("vaxis");

pub const Plane = @import("Plane.zig");
const GraphemeCache = @import("GraphemeCache.zig");

const Layer = @This();

allocator: std.mem.Allocator,
screen: vaxis.Screen,
cache_storage: GraphemeCache.Storage = .{},

pub const Options = struct {
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
    };
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

pub fn plane(self: *Layer) Plane {
    const name = "layer";
    var result: Plane = .{
        .window = self.window(),
        .cache = self.cache_storage.cache(),
        .name_buf = undefined,
        .name_len = name.len,
    };
    @memcpy(result.name_buf[0..name.len], name);
    return result;
}

pub const Target = struct {
    src: *Layer,
    dst: vaxis.Window,
    parent: ?*Layer = null,

    y: i32 = 0, // row offset into `dst`
    x: i32 = 0, // col offset into `dst`
    yoffset: i16 = 0, // cell y pixel offset
    xoffset: i16 = 0, // cell x pixel offset

    blend: Blend = .src_over,
    alpha: u8 = 0xFF,

    pub const Blend = enum {
        replace, // dst = src
        src_over, // dst = src·a + dst·(1−a)
    };

    pub fn draw(self: *const @This()) void {
        if (self.x >= self.dst.width) return;
        if (self.y >= self.dst.height) return;

        const src_y = 0;
        const src_x = 0;
        const src_h: usize = self.src.screen.height;
        const src_w = self.src.screen.width;

        const dst_dim_y: i32 = @intCast(self.dst.height);
        const dst_dim_x: i32 = @intCast(self.dst.width);
        const dst_y = self.y;
        const dst_x = self.x;
        const dst_w = @min(src_w, dst_dim_x - dst_x);

        for (src_y..src_h) |src_row_| {
            const src_row: i32 = @intCast(src_row_);
            const src_row_offset = src_row * src_w;
            const dst_row_offset = (dst_y + src_row) * self.dst.screen.width;
            if (dst_y + src_row >= dst_dim_y) return;
            @memcpy(
                self.dst.screen.buf[@intCast(dst_row_offset + dst_x)..@intCast(dst_row_offset + dst_x + dst_w)],
                self.src.screen.buf[@intCast(src_row_offset + src_x)..@intCast(src_row_offset + dst_w)],
            );
        }
    }
};
