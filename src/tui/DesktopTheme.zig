const std = @import("std");
const Widget = @import("Widget.zig");

theme: []const u8,
opacity: f32 = 0.95,
color_scheme: Widget.Theme.Type = .dark,

const T = @This();
pub const themes: std.StaticStringMap(T) = .initComptime(.{
    .{ "ayaka", T{
        .theme = "ayu-dark",
        .opacity = 0.6,
    } },
    .{ "catppuccin", T{
        .theme = "mocha",
    } },
    .{ "catppuccin-latte", T{
        .theme = "latte",
        .color_scheme = .light,
    } },
    .{ "ethereal", T{
        .theme = "ethereal",
    } },
    .{ "everforest", T{
        .theme = "everforest-dark",
    } },
    .{ "flexoki", T{
        .theme = "railscasts-light",
        .color_scheme = .light,
        .opacity = 1.0,
    } },
    .{ "gruvbox", T{
        .theme = "gruvbox-dark-hard",
    } },
    .{ "hackerman", T{
        .theme = "1984-cyberpunk",
        .opacity = 1.0,
    } },
    .{ "kanagawa", T{
        .theme = "kanagawa-wave",
        .opacity = 1.0,
    } },
    .{ "lumon", T{
        .theme = "1984-cyberpunk",
        .opacity = 1.0,
    } },
    .{ "matte-black", T{
        .theme = "3024-dark",
        .opacity = 1.0,
    } },
    .{ "miasma", T{
        .theme = "ashes-dark",
        .opacity = 1.0,
    } },
    .{ "nord", T{
        .theme = "nord",
        .opacity = 0.85,
    } },
    .{ "osaka-jade", T{
        .theme = "apathy-dark",
    } },
    .{ "retro-82", T{
        .theme = "base16-retro-82",
    } },
    .{ "ristretto", T{
        .theme = "gruvbox-material-dark",
        .opacity = 0.85,
    } },
    .{ "rose-pine", T{
        .theme = "rose-pine-dawn",
        .color_scheme = .light,
        .opacity = 1.0,
    } },
    .{ "vantablack", T{
        .theme = "CRT-gray",
        .opacity = 1.0,
    } },
    .{ "whit", T{
        .theme = "CRT-paper",
        .opacity = 1.0,
        .color_scheme = .light,
    } },
});
