padding: Margin = Margin.@"0",
border: Border = Border.blank,

pub const WidgetType = @import("config").WidgetType;
pub const WidgetStyle = @import("config").WidgetStyle;
pub const tui = @import("tui.zig");
const Plane = @import("renderer").Plane;
const Box = @import("Box.zig");

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
    const @"left/1": Margin = .{ .top = 0, .bottom = 0, .left = 1, .right = 0 };
    const @"right/1": Margin = .{ .top = 0, .bottom = 0, .left = 0, .right = 1 };
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

    nib: []const u8, // north insert begin
    nie: []const u8, // north insert end
    sib: []const u8, // south insert begin
    sie: []const u8, // south insert end

    const blank: Border = .{ .nw = " ", .n = " ", .ne = " ", .e = " ", .se = " ", .s = " ", .sw = " ", .w = " ", .nib = " ", .nie = " ", .sib = " ", .sie = " " };
    const box: Border = .{ .nw = "┌", .n = "─", .ne = "┐", .e = "│", .se = "┘", .s = "─", .sw = "└", .w = "│", .nib = "┤", .nie = "├", .sib = "┤", .sie = "├" };
    const @"rounded box": Border = .{ .nw = "╭", .n = "─", .ne = "╮", .e = "│", .se = "╯", .s = "─", .sw = "╰", .w = "│", .nib = "┤", .nie = "├", .sib = "┤", .sie = "├" };
    const @"double box": Border = .{ .nw = "╔", .n = "═", .ne = "╗", .e = "║", .se = "╝", .s = "═", .sw = "╚", .w = "║", .nib = "╡", .nie = "╞", .sib = "╡", .sie = "╞" };
    const @"single/double box (top/bottom)": Border = .{ .nw = "╓", .n = "─", .ne = "╖", .e = "║", .se = "╜", .s = "─", .sw = "╙", .w = "║", .nib = "┤", .nie = "├", .sib = "┤", .sie = "├" };
    const @"single/double box (left/right)": Border = .{ .nw = "╒", .n = "═", .ne = "╕", .e = "│", .se = "╛", .s = "═", .sw = "╘", .w = "│", .nib = "╡", .nie = "╞", .sib = "╡", .sie = "╞" };
    const @"dotted box (braille)": Border = .{ .nw = "⡏", .n = "⠉", .ne = "⢹", .e = "⢸", .se = "⣸", .s = "⣀", .sw = "⣇", .w = "⡇", .nib = "⢹", .nie = "⡏", .sib = "⣸", .sie = "⣇" };
    const @"thick box (half)": Border = .{ .nw = "▛", .n = "▀", .ne = "▜", .e = "▐", .se = "▟", .s = "▄", .sw = "▙", .w = "▌", .nib = "▌", .nie = "▐", .sib = "▌", .sie = "▐" };
    const @"thick box (sextant)": Border = .{ .nw = "🬕", .n = "🬂", .ne = "🬨", .e = "▐", .se = "🬷", .s = "🬭", .sw = "🬲", .w = "▌", .nib = "▌", .nie = "▐", .sib = "▌", .sie = "▐" };
    const @"thick box (octant)": Border = .{ .nw = "𜵊", .n = "🮂", .ne = "𜶘", .e = "▐", .se = "𜷕", .s = "▂", .sw = "𜷀", .w = "▌", .nib = "▌", .nie = "▐", .sib = "▌", .sie = "▐" };
    const @"extra thick box": Border = .{ .nw = "█", .n = "▀", .ne = "█", .e = "█", .se = "█", .s = "▄", .sw = "█", .w = "█", .nib = "▌", .nie = "▐", .sib = "▌", .sie = "▐" };
    const @"round thick box": Border = .{ .nw = "█", .n = "▀", .ne = "█", .e = "█", .se = "█", .s = "▄", .sw = "█", .w = "█", .nib = "▌", .nie = "▐", .sib = "▌", .sie = "▐" };
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

const bar_left: @This() = .{
    .padding = Margin.@"left/1",
    .border = Border.@"thick box (octant)",
};

const bar_right: @This() = .{
    .padding = Margin.@"right/1",
    .border = Border.@"thick box (octant)",
};

pub fn from_tag(tag: WidgetStyle) *const @This() {
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
        .bar_left => &bar_left,
        .bar_right => &bar_right,
    };
}

const Theme = @import("Widget.zig").Theme;

pub fn theme_style_from_type(style_type: WidgetType, theme: *const Theme) Theme.Style {
    return switch (style_type) {
        .none => theme.editor,
        .palette => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor_widget.bg },
        .panel => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor.bg },
        .dropdown => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor.bg },
        .home => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor.bg },
        .pane_left => switch (tui.config().pane_style) {
            .panel => .{ .fg = theme.editor_widget.bg, .bg = theme.panel.bg },
            .editor => .{ .fg = theme.editor_widget.bg, .bg = theme.editor.bg },
        },
        .pane_right => switch (tui.config().pane_style) {
            .panel => .{ .fg = theme.editor_widget.bg, .bg = theme.panel.bg },
            .editor => .{ .fg = theme.editor_widget.bg, .bg = theme.editor.bg },
        },
        .hint_window => .{ .fg = theme.editor_widget_border.fg, .bg = theme.editor_widget.bg },
    };
}

pub fn render_decoration(widget_style: *const @This(), box: Box, widget_type: WidgetType, plane: *Plane, theme: *const Theme) void {
    const style = theme_style_from_type(widget_type, theme);
    const padding = widget_style.padding;
    const border = widget_style.border;

    plane.set_style(style);
    plane.fill(" ");

    if (padding.top > 0 and padding.left > 0) put_at_pos(plane, 0, 0, border.nw);
    if (padding.top > 0 and padding.right > 0) put_at_pos(plane, 0, box.w - 1, border.ne);
    if (padding.bottom > 0 and padding.left > 0 and box.h > 0) put_at_pos(plane, box.h - 1, 0, border.sw);
    if (padding.bottom > 0 and padding.right > 0 and box.h > 0) put_at_pos(plane, box.h - 1, box.w - 1, border.se);

    {
        const start: usize = if (padding.left > 0) 1 else 0;
        const end: usize = if (padding.right > 0 and box.w > 0) box.w - 1 else box.w;
        if (padding.top > 0) for (start..end) |x| put_at_pos(plane, 0, x, border.n);
        if (padding.bottom > 0) for (start..end) |x| put_at_pos(plane, box.h - 1, x, border.s);
    }

    {
        const start: usize = if (padding.top > 0) 1 else 0;
        const end: usize = if (padding.bottom > 0 and box.h > 0) box.h - 1 else box.h;
        if (padding.left > 0) for (start..end) |y| put_at_pos(plane, y, 0, border.w);
        if (padding.right > 0) for (start..end) |y| put_at_pos(plane, y, box.w - 1, border.e);
    }
}

inline fn put_at_pos(plane: *Plane, y: usize, x: usize, egc: []const u8) void {
    plane.cursor_move_yx(@intCast(y), @intCast(x));
    plane.putchar(egc);
}
