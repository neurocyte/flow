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

var root_caps: ?*const vaxis.Vaxis.Capabilities = null;

pub fn set_root_caps(caps: *const vaxis.Vaxis.Capabilities) void {
    root_caps = caps;
}

fn root_width_method() vaxis.gwidth.Method {
    return if (root_caps) |caps| caps.widthMethod() else .wcwidth;
}

allocator: std.mem.Allocator,
id: Id,
screen: vaxis.Screen,
cache_storage: GraphemeCache.Storage = .{},
z_index: Level = .main,
origin_px_x: i32 = 0,
origin_px_y: i32 = 0,

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
    self.screen.width_method = root_width_method();
    return self;
}

pub fn deinit(self: *Layer) void {
    self.screen.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn resize(self: *Layer, w: u16, h: u16, w_pix: u16, h_pix: u16) std.mem.Allocator.Error!void {
    if (self.screen.width == w and self.screen.height == h and
        self.screen.width_pix == w_pix and self.screen.height_pix == h_pix) return;
    self.screen.deinit(self.allocator);
    self.screen = try vaxis.Screen.init(self.allocator, .{
        .rows = h,
        .cols = w,
        .x_pixel = w_pix,
        .y_pixel = h_pix,
    });
    self.screen.width_method = root_width_method();
    self.cache_storage = .{};
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
        .layer = self,
    };
    @memcpy(result.name_buf[0..name.len], name);
    return result;
}

pub fn global_origin_px(self: *const Layer) struct { i32, i32 } {
    return .{ self.origin_px_x, self.origin_px_y };
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

    blend: Blend = .replace,
    alpha: u8 = 0xFF,
    z_index: Level = .main,

    pub const Blend = enum {
        replace, // dst = src
        src_over, // dst = src·a + dst·(1−a)
        src_over_blur, // src_over after Kawase-blurring dst under src footprint

        pub const default = .replace;
    };
};

pub const Level = enum(i32) {
    background = -1,
    root = 0,
    main = 1,
    statusbar = 2,
    modal = 3,
    overlay = 4,
    top = 99,
    _,

    pub const default = .root;
};
