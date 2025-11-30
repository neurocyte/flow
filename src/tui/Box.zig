const Plane = @import("renderer").Plane;
const Layer = @import("renderer").Layer;
const WidgetStyle = @import("WidgetStyle.zig");

const Self = @This();

y: usize = 0,
x: usize = 0,
h: usize = 1,
w: usize = 1,

pub fn opts(self: Self, name_: [:0]const u8) Plane.Options {
    return self.opts_flags(name_, Plane.option.none);
}

pub fn opts_vscroll(self: Self, name_: [:0]const u8) Plane.Options {
    return self.opts_flags(name_, Plane.option.VSCROLL);
}

fn opts_flags(self: Self, name_: [:0]const u8, flags: Plane.option) Plane.Options {
    return Plane.Options{
        .y = @intCast(self.y),
        .x = @intCast(self.x),
        .rows = @intCast(self.h),
        .cols = @intCast(self.w),
        .name = name_,
        .flags = flags,
    };
}

pub fn from(n: Plane) Self {
    return .{
        .y = @intCast(n.abs_y()),
        .x = @intCast(n.abs_x()),
        .h = @intCast(n.dim_y()),
        .w = @intCast(n.dim_x()),
    };
}

pub fn from_client_box(self: Self, padding: WidgetStyle.Margin) Self {
    const total_y_padding = padding.top + padding.bottom;
    const total_x_padding = padding.left + padding.right;
    const y = if (self.y < padding.top) padding.top else self.y;
    const x = if (self.x < padding.left) padding.left else self.x;
    var box = self;
    box.y = y - padding.top;
    box.h += total_y_padding;
    box.x = x - padding.left;
    box.w += total_x_padding;
    return box;
}

pub fn to_client_box(self: Self, padding: WidgetStyle.Margin) Self {
    const total_y_padding = padding.top + padding.bottom;
    const total_x_padding = padding.left + padding.right;
    var box = self;
    box.y += padding.top;
    box.h -= if (box.h > total_y_padding) total_y_padding else box.h;
    box.x += padding.left;
    box.w -= if (box.w > total_x_padding) total_x_padding else box.w;
    return box;
}

pub fn to_layer(self: Self) Layer.Options {
    return .{
        .y = @intCast(self.y),
        .x = @intCast(self.x),
        .h = @intCast(self.h),
        .w = @intCast(self.w),
    };
}

pub fn is_abs_coord_inside(self: Self, y: usize, x: usize) bool {
    return y >= self.y and y < self.y + self.h and x >= self.x and x < self.x + self.w;
}
