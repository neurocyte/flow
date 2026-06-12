pub const StyleBits = packed struct(u6) {
    struck: bool = false,
    bold: bool = false,
    undercurl: bool = false,
    underline: bool = false,
    italic: bool = false,
    transparent_fg: bool = false,
};

pub const struck: StyleBits = .{ .struck = true };
pub const bold: StyleBits = .{ .bold = true };
pub const undercurl: StyleBits = .{ .undercurl = true };
pub const underline: StyleBits = .{ .underline = true };
pub const italic: StyleBits = .{ .italic = true };
pub const transparent_fg: StyleBits = .{ .transparent_fg = true };
pub const normal: StyleBits = .{};
