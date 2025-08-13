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

const compact: @This() = .{};

const spacious: @This() = .{
    .padding = Margin.@"1",
    .border = Border.blank,
};

const boxed: @This() = .{
    .padding = Margin.@"1",
    .border = Border.box,
};

const rounded_boxed: @This() = .{
    .padding = Margin.@"1",
    .border = Border.@"rounded box",
};

const double_boxed: @This() = .{
    .padding = Margin.@"1",
    .border = Border.@"double box",
};

const single_double_top_bottom_boxed: @This() = .{
    .padding = Margin.@"1",
    .border = Border.@"single/double box (top/bottom)",
};

const single_double_left_right_boxed: @This() = .{
    .padding = Margin.@"1",
    .border = Border.@"single/double box (left/right)",
};

const dotted_boxed: @This() = .{
    .padding = Margin.@"1",
    .border = Border.@"dotted box (braille)",
};

const thick_boxed: @This() = .{
    .padding = Margin.@"1/2",
    .border = Border.@"thick box (octant)",
};

const extra_thick_boxed: @This() = .{
    .padding = Margin.@"1/2",
    .border = Border.@"extra thick box",
};

const bars_top_bottom: @This() = .{
    .padding = Margin.@"top/bottom/1",
    .border = Border.@"thick box (octant)",
};

const bars_left_right: @This() = .{
    .padding = Margin.@"left/right/1",
    .border = Border.@"thick box (octant)",
};

pub fn from_type(style_type: Type) *const @This() {
    return switch (style_type) {
        .none => none_style,
        .palette => palette_style,
        .panel => panel_style,
        .home => home_style,
    };
}

pub const Styles = enum {
    compact,
    spacious,
    boxed,
    double_boxed,
    rounded_boxed,
    single_double_top_bottom_boxed,
    single_double_left_right_boxed,
    dotted_boxed,
    thick_boxed,
    extra_thick_boxed,
    bars_top_bottom,
    bars_left_right,
};

pub fn from_tag(tag: Styles) *const @This() {
    return switch (tag) {
        .compact => &compact,
        .spacious => &spacious,
        .boxed => &boxed,
        .double_boxed => &double_boxed,
        .rounded_boxed => &rounded_boxed,
        .single_double_top_bottom_boxed => &single_double_top_bottom_boxed,
        .single_double_left_right_boxed => &single_double_left_right_boxed,
        .dotted_boxed => &dotted_boxed,
        .thick_boxed => &thick_boxed,
        .extra_thick_boxed => &extra_thick_boxed,
        .bars_top_bottom => &bars_top_bottom,
        .bars_left_right => &bars_left_right,
    };
}

pub fn next_tag(tag: Styles) Styles {
    const new_value = @intFromEnum(tag) + 1;
    return if (new_value > @intFromEnum(Styles.bars_left_right)) .compact else @enumFromInt(new_value);
}

pub fn set_type_style(style_type: Type, tag: Styles) void {
    const ref = type_style(style_type);
    ref.* = from_tag(tag);
}

pub fn set_next_style(style_type: Type) void {
    const tag_ref = type_tag(style_type);
    const new_tag = next_tag(tag_ref.*);
    const style_ref = type_style(style_type);
    tag_ref.* = new_tag;
    style_ref.* = from_tag(new_tag);
}

var none_style: *const @This() = from_tag(none_tag_default);
var palette_style: *const @This() = from_tag(palette_tag_default);
var panel_style: *const @This() = from_tag(panel_tag_default);
var home_style: *const @This() = from_tag(home_tag_default);

fn type_style(style_type: Type) **const @This() {
    return switch (style_type) {
        .none => &none_style,
        .palette => &palette_style,
        .panel => &panel_style,
        .home => &home_style,
    };
}

const none_tag_default: Styles = .compact;
const palette_tag_default: Styles = .compact;
const panel_tag_default: Styles = .compact;
const home_tag_default: Styles = .compact;

var none_tag: Styles = none_tag_default;
var palette_tag: Styles = palette_tag_default;
var panel_tag: Styles = panel_tag_default;
var home_tag: Styles = home_tag_default;

fn type_tag(style_type: Type) *Styles {
    return switch (style_type) {
        .none => &none_tag,
        .palette => &palette_tag,
        .panel => &panel_tag,
        .home => &home_tag,
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
