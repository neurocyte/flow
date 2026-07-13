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

var cell_size_override_x: std.atomic.Value(u16) = .init(0);
var cell_size_override_y: std.atomic.Value(u16) = .init(0);

pub fn set_cell_size(x: u16, y: u16) void {
    cell_size_override_x.store(x, .release);
    cell_size_override_y.store(y, .release);
}

pub fn cell_size_override(comptime axis: enum { x, y }) u16 {
    return switch (axis) {
        .x => cell_size_override_x.load(.acquire),
        .y => cell_size_override_y.load(.acquire),
    };
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

pub inline fn cell_x(self: *const Layer) u15 {
    const override = cell_size_override(.x);
    if (override > 0) return std.math.lossyCast(u15, override);
    if (self.screen.width == 0) return 1;
    const xextra = self.screen.width_pix % self.screen.width;
    const xcell = (self.screen.width_pix - xextra) / self.screen.width;
    return std.math.lossyCast(u15, @max(1, xcell));
}

pub inline fn cell_y(self: *const Layer) u15 {
    const override = Layer.cell_size_override(.y);
    if (override > 0) return std.math.lossyCast(u15, override);
    if (self.screen.height == 0) return 1;
    const yextra = self.screen.height_pix % self.screen.height;
    const ycell = (self.screen.height_pix - yextra) / self.screen.height;
    return std.math.lossyCast(u15, @max(1, ycell));
}

pub fn global_origin_px(self: *const Layer) struct { i32, i32 } {
    return .{ self.origin_px_x, self.origin_px_y };
}

pub const Handle = TypedInt.Tagged(u32, "LHDL"); // Layer HanDL

/// Pixel rectangle
pub const Frame = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn is_set(self: Frame) bool {
        return self.w != 0 and self.h != 0;
    }

    pub fn right(self: Frame) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Frame) i32 {
        return self.y + self.h;
    }

    /// Shrink by pixel amount (negative values grow)
    pub fn inset(self: Frame, left: i32, top: i32, right_px: i32, bottom_px: i32) Frame {
        return .{
            .x = self.x + left,
            .y = self.y + top,
            .w = self.w - left - right_px,
            .h = self.h - top - bottom_px,
        };
    }

    /// Align bottom edge with `other`
    pub fn align_bottom(self: Frame, other: Frame) Frame {
        return .{ .x = self.x, .y = other.bottom() - self.h, .w = self.w, .h = self.h };
    }

    /// Alight right edge with `other`
    pub fn align_right(self: Frame, other: Frame) Frame {
        return .{ .x = other.right() - self.w, .y = self.y, .w = self.w, .h = self.h };
    }
};

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

    radius: u16 = 0, // corner rounding radius in pixels (0 = square)
    corners: Corners = .all, // which corners use `radius`
    shadow: ?Shadow = null,
    fill: bool = false, // stretch to cover the whole destination (GUI only)

    // explicit destination pixel size (GUI only) 0 = use source
    dst_w: u16 = 0,
    dst_h: u16 = 0,

    // scissor rectangle in absolute destination-attachment pixels (GUI) / clamped to cells (terminal)
    clip: ?Frame = null,

    pub const Blend = enum {
        replace, // dst = src
        src_over, // dst = src·a + dst·(1−a)
        src_over_blur, // src_over after Kawase-blurring dst under src footprint

        pub const default = .replace;
    };

    pub const Corners = packed struct {
        top_left: bool = true,
        top_right: bool = true,
        bottom_right: bool = true,
        bottom_left: bool = true,

        pub const all: Corners = .{};
        pub const top: Corners = .{ .top_left = true, .top_right = true, .bottom_right = false, .bottom_left = false };
        pub const bottom: Corners = .{ .top_left = false, .top_right = false, .bottom_right = true, .bottom_left = true };
        pub const left: Corners = .{ .top_left = true, .top_right = false, .bottom_right = false, .bottom_left = true };
        pub const right: Corners = .{ .top_left = false, .top_right = true, .bottom_right = true, .bottom_left = false };
        pub const none: Corners = .{ .top_left = false, .top_right = false, .bottom_right = false, .bottom_left = false };
    };

    pub const Shadow = struct {
        color: u24 = 0x1a1a1a,
        alpha: u8 = 0xee,
        range: u16 = 15, // distance in pixels
        x_offset: i16 = 0, // displacement in pixels
        y_offset: i16 = 0,
        power: u8 = 3, // falloff curve exponent (1..4)
        edges: Edges = .all, // which edges emit a shadow band
        bleed: Edges = .none,

        pub const Edges = packed struct {
            top: bool = true,
            right: bool = true,
            bottom: bool = true,
            left: bool = true,

            pub const all: Edges = .{};
            pub const none: Edges = .{ .top = false, .right = false, .bottom = false, .left = false };
        };
    };
};

pub const Level = enum(i32) {
    background = -1,
    root = 0,
    main = 1,
    statusbar = 20,
    modal = 39,
    overlay = 40,
    top = 99,
    _,

    pub const default = .root;
};
