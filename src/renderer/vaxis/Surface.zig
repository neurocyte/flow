origin_px_x: i32 = 0,
origin_px_y: i32 = 0,

pub fn global_origin_px(self: *const @This()) struct { i32, i32 } {
    return .{ self.origin_px_x, self.origin_px_y };
}
