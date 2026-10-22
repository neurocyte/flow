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
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    if (enable_prefix_keyhints) {
        const key_events = mode.current_key_event_sequence_bindings(allocator, select_mode) catch return;
        defer allocator.free(key_events);
        if (key_events.len > 0) {
            var prefix_buf: [256]u8 = undefined;
            var prefix: std.Io.Writer = .fixed(&prefix_buf);
            prefix.print("{f}", .{keybind.current_key_event_sequence_fmt()}) catch {};
            const rows = build_rows(arena.allocator(), key_events, prefix.buffered().len, .hidden) catch return;
            return render(title.buffered(), prefix.buffered(), rows, theme);
        }
    }
    const bindings = switch (filter) {
        .prefix => return hide(),
        .mode => mode.current_mode_bindings(allocator, select_mode) catch return,
        .all => mode.current_bindings(allocator, select_mode) catch return,
        .global => keybind.current_global_bindings(allocator, select_mode) catch return,
    };
    defer allocator.free(bindings);
    const rows = build_rows(arena.allocator(), bindings, 0, if (filter == .all) .shown else .hidden) catch return;
    return render(switch (filter) {
        .mode => mode_title(&title_buf, mode.bindings.config_section),
        .global => "global",
        else => title.buffered(),
    }, "", rows, theme);
}

const Row = struct {
    keys: std.ArrayList([]const u8) = .empty,
    text: []const u8 = "",
    description: []const u8,
    source_modes: std.ArrayList([]const u8) = .empty,
    sources: []const u8 = "",
};

const Sources = enum { hidden, shown };

const max_listed_keys = 7;
const sided_modifiers = [_][]const u8{ "shft", "ctrl", "alt", "super", "hyper", "meta" };

/// one row per description, with the keys of all bindings that share it
fn build_rows(allocator: std.mem.Allocator, bindings: []const keybind.Binding, prefix_len: usize, sources: Sources) error{ OutOfMemory, WriteFailed }![]Row {
    var rows: std.ArrayList(Row) = .empty;
    for (bindings) |*binding| {
        const description = get_description(binding);
        const row = for (rows.items) |*row| {
            if (std.mem.eql(u8, row.description, description)) break row;
        } else blk: {
            const row = try rows.addOne(allocator);
            row.* = .{ .description = description };
            break :blk row;
        };
        const text = try std.fmt.allocPrint(allocator, "{f}", .{keybind.key_event_sequence_fmt(binding.key_events)});
        try row.keys.append(allocator, std.mem.trimStart(u8, text[@min(prefix_len, text.len)..], " "));
        if (sources == .shown) {
            const source_mode = if (binding.source_info.mode.len > 0) binding.source_info.mode else "global";
            if (index_of_string(row.source_modes.items, source_mode) == null)
                try row.source_modes.append(allocator, source_mode);
        }
    }
    for (rows.items) |*row| {
        try merge_sided_modifiers(allocator, &row.keys);
        row.text = try format_keys(allocator, row.keys.items);
        row.sources = try std.mem.join(allocator, ", ", row.source_modes.items);
    }
    return rows.items;
}

/// replace a left and a right modifier key with one unsided key (lctrl, rctrl -> ctrl)
fn merge_sided_modifiers(allocator: std.mem.Allocator, keys: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    for (sided_modifiers) |modifier| {
        var left_buf: [8]u8 = undefined;
        var right_buf: [8]u8 = undefined;
        const left = std.fmt.bufPrint(&left_buf, "l{s}", .{modifier}) catch unreachable;
        const right = std.fmt.bufPrint(&right_buf, "r{s}", .{modifier}) catch unreachable;
        const left_idx = index_of_string(keys.items, left) orelse continue;
        const right_idx = index_of_string(keys.items, right) orelse continue;
        keys.items[@min(left_idx, right_idx)] = try allocator.dupe(u8, modifier);
        _ = keys.orderedRemove(@max(left_idx, right_idx));
    }
}

fn index_of_string(keys: []const []const u8, key: []const u8) ?usize {
    for (keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
    return null;
}

fn format_keys(allocator: std.mem.Allocator, keys: []const []const u8) error{OutOfMemory}![]const u8 {
    if (keys.len > max_listed_keys)
        return std.fmt.allocPrint(allocator, "{s}, .. {s}", .{ keys[0], keys[keys.len - 1] });
    return std.mem.join(allocator, ", ", keys);
}

fn get_description(binding: *const keybind.Binding) []const u8 {
    if (binding.description.len > 0) return binding.description;
    const id = binding.commands[0].command_id orelse
        command.get_id(binding.commands[0].command) orelse
        return binding.commands[0].command;
    const description = command.get_description(id) orelse return "[n/a]";
    return if (description.len > 0) description else binding.commands[0].command;
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

fn render(title: []const u8, key_events: []const u8, rows: []const Row, theme: *const Widget.Theme) void {
    home_box = null;
    // return if something is already rendering to the top layer
    if (tui.have_top_layer()) return;
    if (rows.len == 0) return;

    var max_prefix_len: usize = 0;
    var max_description_len: usize = 0;
    var max_sources_len: usize = 0;
    for (rows) |row| {
        max_prefix_len = @max(max_prefix_len, tui.egc_chunk_width(row.text, 0, 1));
        max_description_len = @max(max_description_len, tui.egc_chunk_width(row.description, 0, 1));
        max_sources_len = @max(max_sources_len, tui.egc_chunk_width(row.sources, 0, 1));
    }
    const sources_len = if (max_sources_len > 0) max_sources_len + 2 else 0;
    const max_len = max_prefix_len + max_description_len + sources_len + 2 + 2;
    const widget_style = tui.get_widget_style(widget_type);
    const scr = tui.screen();
    const padding_h = widget_style.padding.top + widget_style.padding.bottom;
    const bottom: usize, const max_screen_height: usize = blk: {
        const full: struct { usize, usize } = .{ scr.h -| 1, scr.h -| padding_h -| 3 };
        const panel_y = (tui.mainview() orelse break :blk full).panel_top_row() orelse break :blk full;
        const above = panel_y -| padding_h -| 2;
        if (above < @min(rows.len, min_rows_above_panel)) break :blk full;
        break :blk .{ panel_y, above };
    };
    const max_items = @min(rows.len, max_screen_height);
    const page_size = max_screen_height;
    var top = show_page * page_size;
    if (top >= rows.len) {
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

    if (rows.len > max_items) {
        if (widget_style.padding.bottom > 0) {
            top_layer_.cursor_move_yx(@intCast(top_layer_.window.height -| 1), @intCast(max_len -| 13));
            _ = top_layer_.print("{s} {d}/{d} {s}", .{
                widget_style.border.sib,
                top,
                rows.len,
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

    for (rows[top..], 0..) |row, y| {
        if (y >= max_items) break;
        plane.cursor_move_yx(@intCast(y), @intCast(1 + max_prefix_len - tui.egc_chunk_width(row.text, 0, 1)));
        _ = plane.print("{s}\u{00A0}", .{row.text}) catch {};
    }

    plane.set_style(style_label);

    for (rows[top..], 0..) |row, y| {
        if (y >= max_items) break;
        plane.cursor_move_yx(@intCast(y), @intCast(max_prefix_len + 3));
        _ = plane.print("{s}", .{row.description}) catch {};
    }

    if (max_sources_len == 0) return;
    plane.set_style(if (tui.find_scope_style(theme, "comment")) |sty| sty.style else style_label);

    for (rows[top..], 0..) |row, y| {
        if (y >= max_items) break;
        plane.cursor_move_yx(@intCast(y), @intCast(max_prefix_len + 3 + max_description_len + 2));
        _ = plane.print("{s}", .{row.sources}) catch {};
    }
}
