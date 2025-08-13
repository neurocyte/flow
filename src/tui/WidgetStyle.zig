padding: Margin = Margin.@"0",
border: Border = Border.blank,

pub const Type = enum {
    none,
    palette,
    panel,
    home,
};

pub const Padding = struct {
    pub const Unit = u16;
};

pub const Margin = struct {
    const Unit = Padding.Unit;

    top: Unit,
    bottom: Unit,
    left: Unit,
    right: Unit,

    const @"0": Margin = .{ .top = 0, .bottom = 0, .left = 0, .right = 0 };
    const @"1": Margin = .{ .top = 1, .bottom = 1, .left = 1, .right = 1 };
    const @"2": Margin = .{ .top = 2, .bottom = 2, .left = 2, .right = 2 };
    const @"3": Margin = .{ .top = 3, .bottom = 3, .left = 3, .right = 3 };
    const @"1/2": Margin = .{ .top = 1, .bottom = 1, .left = 2, .right = 2 };
    const @"2/1": Margin = .{ .top = 2, .bottom = 2, .left = 1, .right = 1 };
    const @"2/3": Margin = .{ .top = 2, .bottom = 2, .left = 3, .right = 3 };
    const @"2/4": Margin = .{ .top = 2, .bottom = 2, .left = 4, .right = 4 };

    const @"top/bottom/1": Margin = .{ .top = 1, .bottom = 1, .left = 0, .right = 0 };
    const @"top/bottom/2": Margin = .{ .top = 2, .bottom = 2, .left = 0, .right = 0 };
    const @"left/right/1": Margin = .{ .top = 0, .bottom = 0, .left = 1, .right = 1 };
    const @"left/right/2": Margin = .{ .top = 0, .bottom = 0, .left = 2, .right = 2 };
};

pub const Border = struct {
    nw: []const u8,
    n: []const u8,
    ne: []const u8,
    e: []const u8,
    se: []const u8,
    s: []const u8,
    sw: []const u8,
    w: []const u8,

    const blank: Border = .{ .nw = " ", .n = " ", .ne = " ", .e = " ", .se = " ", .s = " ", .sw = " ", .w = " " };
    const box: Border = .{ .nw = "┌", .n = "─", .ne = "┐", .e = "│", .se = "┘", .s = "─", .sw = "└", .w = "│" };
    const @"rounded box": Border = .{ .nw = "╭", .n = "─", .ne = "╮", .e = "│", .se = "╯", .s = "─", .sw = "╰", .w = "│" };
    const @"double box": Border = .{ .nw = "╔", .n = "═", .ne = "╗", .e = "║", .se = "╝", .s = "═", .sw = "╚", .w = "║" };
    const @"single/double box (top/bottom)": Border = .{ .nw = "╓", .n = "─", .ne = "╖", .e = "║", .se = "╜", .s = "─", .sw = "╙", .w = "║" };
    const @"single/double box (left/right)": Border = .{ .nw = "╒", .n = "═", .ne = "╕", .e = "│", .se = "╛", .s = "═", .sw = "╘", .w = "│" };
    const @"dotted box (braille)": Border = .{ .nw = "⡏", .n = "⠉", .ne = "⢹", .e = "⢸", .se = "⣸", .s = "⣀", .sw = "⣇", .w = "⡇" };
    const @"thick box (half)": Border = .{ .nw = "▛", .n = "▀", .ne = "▜", .e = "▐", .se = "▟", .s = "▄", .sw = "▙", .w = "▌" };
    const @"thick box (sextant)": Border = .{ .nw = "🬕", .n = "🬂", .ne = "🬨", .e = "▐", .se = "🬷", .s = "🬭", .sw = "🬲", .w = "▌" };
    const @"thick box (octant)": Border = .{ .nw = "𜵊", .n = "🮂", .ne = "𜶘", .e = "▐", .se = "𜷕", .s = "▂", .sw = "𜷀", .w = "▌" };
    const @"extra thick box": Border = .{ .nw = "█", .n = "▀", .ne = "█", .e = "█", .se = "█", .s = "▄", .sw = "█", .w = "█" };
    const @"round thick box": Border = .{ .nw = "█", .n = "▀", .ne = "█", .e = "█", .se = "█", .s = "▄", .sw = "█", .w = "█" };
};

pub const default_static: @This() = .{};
pub const default = &default_static;

pub const boxed_static: @This() = .{
    .padding = Margin.@"1",
    .border = Border.box,
};
pub const boxed = &boxed_static;

pub const thick_boxed_static: @This() = .{
    .padding = Margin.@"1/2",
    .border = Border.@"thick box (octant)",
};
pub const thick_boxed = &thick_boxed_static;

pub const bars_top_bottom_static: @This() = .{
    .padding = Margin.@"top/bottom/1",
    .border = Border.@"thick box (octant)",
};
pub const bars_top_bottom = &bars_top_bottom_static;

pub const bars_left_right_static: @This() = .{
    .padding = Margin.@"left/right/1",
    .border = Border.box,
};
pub const bars_left_right = &bars_left_right_static;

pub fn from_type(style_type: Type) *const @This() {
    return switch (style_type) {
        .none => default,
        .palette => thick_boxed,
        .panel => default,
        .home => default,
    };
}

const Widget = @import("Widget.zig");

pub fn theme_style_from_type(style_type: Type, theme: *const Widget.Theme) Widget.Theme.Style {
    return switch (style_type) {
        .none => theme.editor,
        .palette => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor_widget.bg },
        .panel => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor.bg },
        .home => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor.bg },
    };
}
