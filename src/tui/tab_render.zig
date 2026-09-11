const Plane = @import("renderer").Plane;

const Widget = @import("Widget.zig");
const Tabs = @import("status/tabs.zig");

const Style = Tabs.Style;
const put_glyph = Tabs.put_glyph;

pub const State = struct {
    hover: bool = false,
    active: bool = false,
    focused: bool = true,
    dragging: bool = false,
};

pub const Content = struct {
    icon: []const u8 = "",
    icon_color: ?u24 = null,
    label: []const u8,
    indicator: enum { clean, dirty } = .clean,
    hover_action: enum { close, save } = .close,
};

pub const Hit = struct {
    close_pos: ?i32 = null,
    save_pos: ?i32 = null,
};

const Mode = enum { selected, active, inactive, unfocused_active, unfocused_inactive };

pub fn render(plane: *Plane, s: *const Style, theme: *const Widget.Theme, state: State, c: Content) Hit {
    const mode: Mode = if (state.hover or state.dragging)
        .selected
    else if (state.active)
        if (state.focused) .active else .unfocused_active
    else if (state.focused) .inactive else .unfocused_inactive;

    plane.set_base_style(theme.editor);
    plane.erase();
    plane.home();
    fill(plane, s.inactive_fg, s.inactive_bg, theme);
    switch (mode) {
        .selected => if (state.active) fill(plane, s.selected_fg, s.selected_bg, theme),
        .active, .unfocused_active => fill(plane, s.active_fg, s.active_bg, theme),
        .inactive, .unfocused_inactive => {},
    }
    const corner_bg: Tabs.GlyphBackground = if (state.dragging) .transparent else .normal;
    const hover = state.hover and !state.dragging;
    return switch (mode) {
        inline else => |m| render_mode(m, plane, s, theme, corner_bg, hover, c),
    };
}

/// Width of everything except the icon and label
pub fn chrome_width(plane: Plane, s: *const Style, active: bool, indicator_width: usize) usize {
    const len_padding = plane.egc_chunk_width(s.padding, 0, 1) * (s.padding_left + s.padding_right);
    const len_indicator = indicator_width + 1; // +1 for the leading space
    return len_padding + len_indicator + if (active)
        plane.egc_chunk_width(s.active_left, 0, 1) +
            plane.egc_chunk_width(s.active_right, 0, 1)
    else
        plane.egc_chunk_width(s.inactive_left, 0, 1) +
            plane.egc_chunk_width(s.inactive_right, 0, 1);
}

fn fill(plane: *Plane, fg: Tabs.colors, bg: Tabs.colors, theme: *const Widget.Theme) void {
    plane.set_style(.{ .fg = fg.from_theme(theme), .bg = bg.from_theme(theme) });
    plane.fill(" ");
    plane.home();
}

fn render_mode(
    comptime mode: Mode,
    plane: *Plane,
    s: *const Style,
    theme: *const Widget.Theme,
    corner_bg: Tabs.GlyphBackground,
    hover: bool,
    c: Content,
) Hit {
    const p = @tagName(mode);
    plane.set_style(.{
        .fg = @field(s, p ++ "_left_fg").from_theme(theme),
        .bg = @field(s, p ++ "_left_bg").from_theme(theme),
    });
    put_glyph(plane, @field(s, p ++ "_left"), @field(s, p ++ "_left_fg_transparent"), corner_bg);

    const fg = @field(s, p ++ "_fg").from_theme(theme);
    plane.set_style(.{ .fg = fg, .bg = @field(s, p ++ "_bg").from_theme(theme) });
    const hit = render_content(plane, s, theme, hover, fg, c);

    plane.set_style(.{
        .fg = @field(s, p ++ "_right_fg").from_theme(theme),
        .bg = @field(s, p ++ "_right_bg").from_theme(theme),
    });
    put_glyph(plane, @field(s, p ++ "_right"), @field(s, p ++ "_right_fg_transparent"), corner_bg);
    return hit;
}

fn render_content(plane: *Plane, s: *const Style, theme: *const Widget.Theme, hover: bool, fg: ?Widget.Theme.Color, c: Content) Hit {
    var hit: Hit = .{};
    render_padding(plane, s, .left);
    if (c.icon.len > 0) {
        if (c.icon_color) |color|
            plane.set_style(.{ .fg = .{ .color = color } });
        _ = plane.putstr(c.icon) catch {};
        if (c.icon_color) |_|
            plane.set_style(.{ .fg = fg });
        _ = plane.putstr("  ") catch {};
    }
    _ = plane.putstr(c.label) catch {};
    _ = plane.putstr(" ") catch {};
    if (hover) switch (c.hover_action) {
        .save => {
            if (s.save_icon_fg) |color|
                plane.set_style(.{ .fg = color.from_theme(theme) });
            hit.save_pos = plane.cursor_x();
            put_glyph(plane, s.save_icon, s.save_icon_fg_transparent, .normal);
        },
        .close => {
            plane.set_style(.{ .fg = s.close_icon_fg.from_theme(theme) });
            hit.close_pos = plane.cursor_x();
            put_glyph(plane, s.close_icon, s.close_icon_fg_transparent, .normal);
        },
    } else switch (c.indicator) {
        .dirty => {
            if (s.dirty_indicator_fg) |color|
                plane.set_style(.{ .fg = color.from_theme(theme) });
            put_glyph(plane, s.dirty_indicator, s.dirty_indicator_fg_transparent, .normal);
        },
        .clean => {
            if (s.clean_indicator_fg) |color|
                plane.set_style(.{ .fg = color.from_theme(theme) });
            put_glyph(plane, s.clean_indicator, s.clean_indicator_fg_transparent, .normal);
        },
    }
    plane.set_style(.{ .fg = fg });
    render_padding(plane, s, .right);
    return hit;
}

fn render_padding(plane: *Plane, s: *const Style, side: enum { left, right }) void {
    var padding: usize = switch (side) {
        .left => s.padding_left,
        .right => s.padding_right,
    };
    const old_fgt = plane.style.glyph_alpha_from_bg;
    defer plane.style.glyph_alpha_from_bg = old_fgt;
    plane.style.glyph_alpha_from_bg = s.padding_fg_transparent;
    while (padding > 0) : (padding -= 1) _ = plane.putstr(s.padding) catch {};
}
