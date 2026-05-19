const std = @import("std");
const vaxis = @import("vaxis");
const TypedInt = @import("TypedInt");

pub const Plane = @import("Plane.zig");
const GraphemeCache = @import("GraphemeCache.zig");

const Layer = @This();

pub const Id = TypedInt.Tagged(u64, "LYID"); // LaYer ID

var next_id_counter: u64 = 1;

pub fn next_id() Id {
    defer next_id_counter += 1;
    return @enumFromInt(next_id_counter);
}

allocator: std.mem.Allocator,
id: Id,
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
        .id = next_id(),
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

pub const Handle = TypedInt.Tagged(u32, "LHDL"); // Layer HanDL

pub const Target = struct {
    src: *Layer,
    dst: vaxis.Window,
    parent: ?Handle = null,

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
};
