const Style = @import("theme").Style;
const nc = @import("notcurses");

pub const set_fg_rgb = nc.channels_set_fg_rgb;
pub const set_bg_rgb = nc.channels_set_bg_rgb;

pub fn set_fg_opaque(channels_: *u64) void {
    nc.channels_set_fg_alpha(channels_, nc.ALPHA_OPAQUE) catch {};
}

pub fn set_bg_opaque(channels_: *u64) void {
    nc.channels_set_bg_alpha(channels_, nc.ALPHA_OPAQUE) catch {};
}

pub fn set_fg_transparent(channels_: *u64) void {
    nc.channels_set_fg_alpha(channels_, nc.ALPHA_TRANSPARENT) catch {};
}

pub fn set_bg_transparent(channels_: *u64) void {
    nc.channels_set_bg_alpha(channels_, nc.ALPHA_TRANSPARENT) catch {};
}

pub inline fn fg_from_style(channels_: *u64, style_: Style) void {
    if (style_.fg) |fg| {
        set_fg_rgb(channels_, fg) catch {};
        set_fg_opaque(channels_);
    }
}

pub inline fn bg_from_style(channels_: *u64, style_: Style) void {
    if (style_.bg) |bg| {
        set_bg_rgb(channels_, bg) catch {};
        set_bg_opaque(channels_);
    }
}

pub inline fn from_style(channels_: *u64, style_: Style) void {
    fg_from_style(channels_, style_);
    bg_from_style(channels_, style_);
}
