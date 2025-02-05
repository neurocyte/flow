pub const StyleBits = packed struct(u5) {
    struck: bool = false,
    bold: bool = false,
    undercurl: bool = false,
    underline: bool = false,
    italic: bool = false,
};

pub const struck: StyleBits = .{ .struck = true };
pub const bold: StyleBits = .{ .bold = true };
pub const undercurl: StyleBits = .{ .undercurl = true };
pub const underline: StyleBits = .{ .underline = true };
pub const italic: StyleBits = .{ .italic = true };
pub const normal: StyleBits = .{};
