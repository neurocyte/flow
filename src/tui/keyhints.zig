const std = @import("std");
const keybind = @import("keybind");
const command = @import("command");
const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const widget_type: Widget.Type = .hint_window;
const min_rows_above_panel = 5;

var show_page: usize = 0;
var home_box: ?Widget.Box = null;
var dodging: bool = false;

pub const Filter = enum { prefix, mode, all, global };

pub fn render_input_mode(input_mode: ?*const keybind.Mode, allocator: std.mem.Allocator, filter: Filter, enable_prefix_keyhints: bool, select_mode: keybind.SelectMode, theme: *const Widget.Theme) void {
    const mode = input_mode orelse return;
    var title_buf: [256]u8 = undefined;
    var title: std.Io.Writer = .fixed(&title_buf);
    title.print("{s}/{s}", .{ keybind.get_namespace(), mode.bindings.config_section }) catch {};
    if (enable_prefix_keyhints) {
        const key_events = mode.current_key_event_sequence_bindings(allocator, select_mode) catch return;
        defer allocator.free(key_events);
        if (key_events.len > 0) return render(title.buffered(), key_events, theme, .no_key_event_prefix);
    }
    const bindings = switch (filter) {
        .prefix => return hide(),
        .mode => mode.current_mode_bindings(allocator, select_mode) catch return,
        .all => mode.current_bindings(allocator, select_mode) catch return,
        .global => keybind.current_global_bindings(allocator, select_mode) catch return,
    };
    defer allocator.free(bindings);
    return render(switch (filter) {
        .mode => mode_title(&title_buf, mode.bindings.config_section),
        .global => "global",
        else => title.buffered(),
    }, bindings, theme, .full);
}

fn mode_title(buf: []u8, config_section: []const u8) []const u8 {
    const name = if (std.mem.lastIndexOfScalar(u8, config_section, '/')) |pos| config_section[pos + 1 ..] else config_section;
    const len = @min(name.len, buf.len);
    @memcpy(buf[0..len], name[0..len]);
    std.mem.replaceScalar(u8, buf[0..len], '_', ' ');
    return buf[0..len];
}

pub fn scroll() void {
    show_page += 1;
}

pub fn reset_scroll() void {
    show_page = 0;
}

pub fn hide() void {
    home_box = null;
}

pub fn mouse_moved() void {
    const box = home_box orelse return;
    if (dodging != is_mouse_over(box)) tui.need_render(@src());
}

fn is_mouse_over(box: Widget.Box) bool {
    const cell = tui.mouse_cell() orelse return false;
    if (cell.row < 0 or cell.col < 0) return false;
    return box.is_abs_coord_inside(@intCast(cell.row), @intCast(cell.col));
}

const RenderMode = enum { full, no_key_event_prefix };

fn render(title: []const u8, bindings: []const keybind.Binding, theme: *const Widget.Theme, render_mode: RenderMode) void {
    home_box = null;
    // return if something is already rendering to the top layer
    if (tui.have_top_layer()) return;
    if (bindings.len == 0) return;

    var key_events_buf: [256]u8 = undefined;
    const key_events = switch (render_mode) {
        .no_key_event_prefix => blk: {
            var writer = std.Io.Writer.fixed(&key_events_buf);
            writer.print("{f}", .{keybind.current_key_event_sequence_fmt()}) catch {};
            break :blk writer.buffered();
        },
        .full => &.{},
    };

    const max_prefix_len = get_max_prefix_len(bindings) - key_events.len;
    const max_description_len = get_max_description_len(bindings);
    const max_len = max_prefix_len + max_description_len + 2 + 2;
    const widget_style = tui.get_widget_style(widget_type);
    const scr = tui.screen();
    const padding_h = widget_style.padding.top + widget_style.padding.bottom;
    const bottom: usize, const max_screen_height: usize = blk: {
        const full: struct { usize, usize } = .{ scr.h -| 1, scr.h -| padding_h -| 3 };
        const panel = (tui.mainview() orelse break :blk full).panel_box() orelse break :blk full;
        const above = panel.y -| padding_h -| 2;
        if (above < @min(bindings.len, min_rows_above_panel)) break :blk full;
        break :blk .{ panel.y, above };
    };
    const max_items = @min(bindings.len, max_screen_height);
    const page_size = max_screen_height;
    var top = show_page * page_size;
    if (top >= bindings.len) {
        top = 0;
        show_page = 0;
    }
    var box: Widget.Box = .{
        .h = max_items,
        .w = max_len + widget_style.padding.left -| widget_style.padding.right,
        .x = scr.w -| max_len -| 2 -| widget_style.padding.left -| widget_style.padding.right,
        .y = bottom -| max_items -| padding_h,
    };
    var deco_box = box.from_client_box(widget_style.padding);
    home_box = deco_box;
    dodging = is_mouse_over(deco_box);
    if (dodging) deco_box.x = scr.w -| (deco_box.x + deco_box.w);

    var top_layer_ = tui.top_layer(deco_box, 0, 0, .overlay) orelse return;
    widget_style.render_decoration(deco_box, widget_type, &top_layer_, theme);

    if (bindings.len > max_items) {
        if (widget_style.padding.bottom > 0) {
            top_layer_.cursor_move_yx(@intCast(top_layer_.window.height -| 1), @intCast(max_len -| 13));
            _ = top_layer_.print("{s} {d}/{d} {s}", .{
                widget_style.border.sib,
                top,
                bindings.len,
                widget_style.border.sie,
            }) catch {};
            top_layer_.cursor_move_yx(@intCast(top_layer_.window.height -| 1), @intCast(4));
            _ = top_layer_.print("{s} {s} for more {s}", .{
                widget_style.border.sib,
                keybind.current_namespace().scroll_hints_text,
                widget_style.border.sie,
            }) catch {};
        }
    }
    if (widget_style.padding.top > 0) {
        top_layer_.cursor_move_yx(@intCast(0), @intCast(3));
        if (key_events.len > 0) {
            _ = top_layer_.print("{s} {s} prefix: {s} {s}", .{
                widget_style.border.nib,
                title,
                key_events,
                widget_style.border.nie,
            }) catch {};
        } else {
            _ = top_layer_.print("{s} {s} {s}", .{
                widget_style.border.nib,
                title,
                widget_style.border.nie,
            }) catch {};
        }
    }

    // workaround vaxis.Layer issue
    const top_layer_window = top_layer_.window;
    defer {
        top_layer_.window.y_off = top_layer_window.y_off;
        top_layer_.window.x_off = top_layer_window.x_off;
        top_layer_.window.height = top_layer_window.height;
        top_layer_.window.width = top_layer_window.width;
    }
    top_layer_.window.y_off += widget_style.padding.top;
    top_layer_.window.x_off += widget_style.padding.left;
    top_layer_.window.height -= widget_style.padding.top + widget_style.padding.bottom;
    top_layer_.window.width -= widget_style.padding.left + widget_style.padding.right;

    const plane = &top_layer_;

    const style_base = theme.editor_widget;
    const style_label = theme.editor_widget;
    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    plane.set_base_style(style_base);
    plane.erase();
    plane.home();
    plane.set_style(style_label);
    plane.fill(" ");
    plane.home();
    plane.set_style(style_hint);

    for (bindings[top..], 0..) |binding, y| {
        if (y >= max_items) break;
        var keybind_buf: [256]u8 = undefined;
        const keybind_txt = blk: {
            var writer = std.Io.Writer.fixed(&keybind_buf);
            writer.print("{f}", .{keybind.key_event_sequence_fmt(binding.key_events)}) catch break :blk "";
            break :blk writer.buffered();
        };
        plane.cursor_move_yx(@intCast(y), 0);
        switch (render_mode) {
            .no_key_event_prefix => _ = plane.print("{s}", .{keybind_txt[key_events.len..]}) catch {},
            .full => _ = plane.print(" {s}", .{keybind_txt}) catch {},
        }
    }

    plane.set_style(style_label);

    for (bindings[top..], 0..) |binding, y| {
        if (y >= max_items) break;
        const padding = max_prefix_len + 3;

        const description = blk: {
            if (binding.description.len > 0) break :blk binding.description;
            const id = binding.commands[0].command_id orelse
                command.get_id(binding.commands[0].command) orelse
                break :blk binding.commands[0].command;
            break :blk command.get_description(id) orelse break :blk "[n/a]";
        };

        plane.cursor_move_yx(@intCast(y), @intCast(padding));
        _ = plane.print("{s}", .{if (description.len > 0) description else binding.commands[0].command}) catch {};
    }
}

fn get_max_prefix_len(bindings: anytype) usize {
    var max: usize = 0;
    for (bindings) |binding| {
        var keybind_buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&keybind_buf);
        writer.print("{f}", .{keybind.key_event_sequence_fmt(binding.key_events)}) catch continue;
        max = @max(max, writer.buffered().len);
    }
    return max;
}

fn get_max_description_len(bindings: anytype) usize {
    var max: usize = 0;
    for (bindings) |binding| {
        if (binding.description.len > 0) {
            max = @max(max, binding.description.len);
            continue;
        }
        const id = binding.commands[0].command_id orelse command.get_id(binding.commands[0].command) orelse continue;
        const description = command.get_description(id) orelse continue;
        const text = if (description.len > 0) description else binding.commands[0].command;
        max = @max(max, text.len);
    }
    return max;
}
