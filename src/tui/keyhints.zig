const std = @import("std");
const keybind = @import("keybind");
const command = @import("command");
const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const widget_type: Widget.Type = .hint_window;

var show_page: usize = 0;

pub fn render_current_input_mode(allocator: std.mem.Allocator, select_mode: keybind.SelectMode, theme: *const Widget.Theme) void {
    const mode = tui.input_mode() orelse return;
    const bindings = blk: {
        const b = mode.current_key_event_sequence_bindings(allocator, select_mode) catch return;
        break :blk if (b.len > 0) b else mode.current_bindings(allocator, select_mode) catch return;
    };
    defer allocator.free(bindings);
    return render(mode, bindings, theme, .full);
}

pub fn render_current_key_event_sequence(allocator: std.mem.Allocator, select_mode: keybind.SelectMode, theme: *const Widget.Theme) void {
    const mode = tui.input_mode() orelse return;
    const bindings = mode.current_key_event_sequence_bindings(allocator, select_mode) catch return;
    defer allocator.free(bindings);
    return render(mode, bindings, theme, .no_key_event_prefix);
}

pub fn scroll() void {
    show_page += 1;
}

const RenderMode = enum { full, no_key_event_prefix };

fn render(mode: *keybind.Mode, bindings: []const keybind.Binding, theme: *const Widget.Theme, render_mode: RenderMode) void {
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
    const max_screen_height = scr.h -| widget_style.padding.top -| widget_style.padding.bottom -| 1;
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
        .y = scr.h -| max_items -| 1 -| widget_style.padding.top -| widget_style.padding.bottom,
    };
    const deco_box = box.from_client_box(widget_style.padding);

    const top_layer_ = tui.top_layer(deco_box.to_layer()) orelse return;
    widget_style.render_decoration(deco_box, widget_type, top_layer_, theme);

    if (bindings.len > max_items) {
        if (widget_style.padding.bottom > 0) {
            top_layer_.cursor_move_yx(@intCast(top_layer_.window.height -| 1), @intCast(max_len -| 13)) catch return;
            _ = top_layer_.print("{s} {d}/{d} {s}", .{
                widget_style.border.sib,
                top,
                bindings.len,
                widget_style.border.sie,
            }) catch {};
            top_layer_.cursor_move_yx(@intCast(top_layer_.window.height -| 1), @intCast(4)) catch return;
            _ = top_layer_.print("{s} C-A-? for more {s}", .{
                widget_style.border.sib,
                widget_style.border.sie,
            }) catch {};
        }
    }
    if (widget_style.padding.top > 0) {
        top_layer_.cursor_move_yx(@intCast(0), @intCast(3)) catch return;
        _ = top_layer_.print("{s} {s}/{s} {s}", .{
            widget_style.border.nib,
            keybind.get_namespace(),
            mode.bindings.config_section,
            widget_style.border.nie,
        }) catch {};
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

    const plane = top_layer_;

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
        plane.cursor_move_yx(@intCast(y), 0) catch break;
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
            const id = binding.commands[0].command_id orelse
                command.get_id(binding.commands[0].command) orelse
                break :blk binding.commands[0].command;
            break :blk command.get_description(id) orelse break :blk "[n/a]";
        };

        plane.cursor_move_yx(@intCast(y), @intCast(padding)) catch break;
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
        const id = binding.commands[0].command_id orelse command.get_id(binding.commands[0].command) orelse continue;
        const description = command.get_description(id) orelse continue;
        const text = if (description.len > 0) description else binding.commands[0].command;
        max = @max(max, text.len);
    }
    return max;
}
