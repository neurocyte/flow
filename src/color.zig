const pow = @import("std").math.pow;

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub inline fn from_u24(v: u24) RGB {
        const r = @as(u8, @intCast(v >> 16 & 0xFF));
        const g = @as(u8, @intCast(v >> 8 & 0xFF));
        const b = @as(u8, @intCast(v & 0xFF));
        return .{ .r = r, .g = g, .b = b };
    }

    pub inline fn to_u24(v: RGB) u24 {
        const r = @as(u24, @intCast(v.r)) << 16;
        const g = @as(u24, @intCast(v.g)) << 8;
        const b = @as(u24, @intCast(v.b));
        return r | b | g;
    }

    pub inline fn from_u8s(v: [3]u8) RGB {
        return .{ .r = v[0], .g = v[1], .b = v[2] };
    }

    pub fn from_string(s: []const u8) ?RGB {
        const nib = struct {
            fn f(c: u8) ?u8 {
                return switch (c) {
                    '0'...'9' => c - '0',
                    'A'...'F' => c - 'A' + 10,
                    'a'...'f' => c - 'a' + 10,
                    else => null,
                };
            }
        }.f;

        if (s.len != 7) return null;
        if (s[0] != '#') return null;
        const r = (nib(s[1]) orelse return null) << 4 | (nib(s[2]) orelse return null);
        const g = (nib(s[3]) orelse return null) << 4 | (nib(s[4]) orelse return null);
        const b = (nib(s[5]) orelse return null) << 4 | (nib(s[6]) orelse return null);
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn to_u8s(v: RGB) [3]u8 {
        return [_]u8{ v.r, v.g, v.b };
    }

    pub fn to_string(v: RGB, s: *[7]u8) []u8 {
        const nib = struct {
            fn f(n: u8) u8 {
                return switch (n & 0b1111) {
                    0...9 => '0' + n,
                    0xA...0xF => 'A' + n,
                    else => unreachable,
                };
            }
        }.f;

        s[0] = '#';
        s[1] = nib(v.r >> 4);
        s[2] = nib(v.r);
        s[3] = nib(v.g >> 4);
        s[4] = nib(v.g);
        s[5] = nib(v.b >> 4);
        s[6] = nib(v.b);
        return s;
    }

    pub fn contrast(a_: RGB, b_: RGB) f32 {
        const a = RGBf.from_RGB(a_).luminance();
        const b = RGBf.from_RGB(b_).luminance();
        return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
    }

    pub fn max_contrast(v: RGB, a: RGB, b: RGB) RGB {
        return if (contrast(v, a) > contrast(v, b)) a else b;
    }
};

pub const RGBf = struct {
    r: f32,
    g: f32,
    b: f32,

    pub inline fn from_RGB(v: RGB) RGBf {
        return .{ .r = tof(v.r), .g = tof(v.g), .b = tof(v.b) };
    }

    pub fn luminance(v: RGBf) f32 {
        return linear(v.r) * RED + linear(v.g) * GREEN + linear(v.b) * BLUE;
    }

    inline fn tof(c: u8) f32 {
        return @as(f32, @floatFromInt(c)) / 255.0;
    }

    inline fn linear(v: f32) f32 {
        return if (v <= 0.03928) v / 12.92 else pow(f32, (v + 0.055) / 1.055, GAMMA);
    }

    const RED = 0.2126;
    const GREEN = 0.7152;
    const BLUE = 0.0722;
    const GAMMA = 2.4;
};

pub fn max_contrast(v: u24, a: u24, b: u24) u24 {
    return RGB.max_contrast(RGB.from_u24(v), RGB.from_u24(a), RGB.from_u24(b)).to_u24();
}

pub fn apply_alpha(base: RGB, over: RGB, alpha_u8: u8) RGB {
    const alpha: f64 = @as(f64, @floatFromInt(alpha_u8)) / @as(f64, @floatFromInt(0xFF));
    return .{
        .r = component_apply_alpha(base.r, over.r, alpha),
        .g = component_apply_alpha(base.g, over.g, alpha),
        .b = component_apply_alpha(base.b, over.b, alpha),
    };
}

inline fn component_apply_alpha(base_u8: u8, over_u8: u8, alpha: f64) u8 {
    const base: f64 = @floatFromInt(base_u8);
    const over: f64 = @floatFromInt(over_u8);
    const result = ((1 - alpha) * base) + (alpha * over);
    return @intFromFloat(result);
}
