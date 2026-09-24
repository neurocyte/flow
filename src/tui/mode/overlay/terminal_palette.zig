const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const command = @import("command");

const tui = @import("../../tui.zig");
const Widget = @import("../../Widget.zig");
const Vt = @import("../../Vt.zig");
const PanelArea = @import("../../PanelArea.zig");
const tab_render = @import("../../tab_render.zig");
const module_name = @typeName(@This());
pub const Type = @import("palette.zig").Create(@This());

pub const label = "Select terminal";
pub const name = " terminal";
pub const description = "terminal";
pub const preserve_entry_order = true;
pub const icon = "  ";
const terminal_icon = "";
pub const modal_dim = false;
pub const placement = .panel;

const label_len = label.len + 3 + icon.len;
const indicator_separator = 1;

pub const Entry = struct {
    label: []const u8,
    idx: usize,
    command: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    icon: []const u8 = "",
    color: u24 = 0,
    state: Vt.State = .idle,
    keybind: []const u8 = "",
    command_action: CommandAction = .run,
};

pub const CommandAction = enum { run, describe };

fn entry_state(vt: *Vt) Vt.State {
    const mv = tui.mainview() orelse return vt.get_state(.hidden);
    return vt.get_state(if (mv.is_terminal_visible(vt)) .visible else .hidden);
}

fn add_entry(palette: *Type, vt: *Vt, idx: usize, longest: *usize) !void {
    const title = try palette.allocator.dupe(u8, vt.get_title());
    var entry_icon: []const u8 = "";
    var entry_color: u24 = 0;
    if (vt.get_profile()) |profile| {
        entry_icon = try palette.allocator.dupe(u8, profile.icon);
        entry_color = profile.color;
    }
    (try palette.entries.addOne(palette.allocator)).* = .{
        .label = title,
        .idx = idx,
        .icon = entry_icon,
        .color = entry_color,
        .state = entry_state(vt),
    };
    longest.* = @max(longest.*, title.len);
}

fn add_profile_entry(palette: *Type, profile: anytype, longest: *usize, longest_hint: *usize) !void {
    const profile_name = try palette.allocator.dupe(u8, profile.name);
    const entry_icon = try palette.allocator.dupe(u8, profile.icon);
    const keybind = try palette.allocator.dupe(u8, profile.keybind);
    (try palette.entries.addOne(palette.allocator)).* = .{
        .label = profile_name,
        .idx = 0,
        .profile = profile_name, // aliases label; serialized separately, freed once via label
        .icon = entry_icon,
        .color = profile.color,
        .keybind = keybind,
    };
    longest.* = @max(longest.*, profile_name.len);
    if (keybind.len > 0)
        longest_hint.* = @max(longest_hint.*, profile_name.len + tui.egc_chunk_width(keybind, 0, 1) + 1);
}

pub fn load_entries(palette: *Type) !usize {
    var longest: usize = 0;
    const mr_idx = Vt.Manager.most_recent_index();
    if (mr_idx) |mri| {
        if (Vt.Manager.by_index(mri)) |vt| try add_entry(palette, vt, mri, &longest);
    }
    var idx: usize = 0;
    while (Vt.Manager.by_index(idx)) |vt| : (idx += 1) {
        if (mr_idx == idx) continue;
        try add_entry(palette, vt, idx, &longest);
    }
    const hints = palette.mode.keybind_hints;
    var longest_hint: usize = 0;
    longest_hint = @max(longest_hint, try add_palette_command(palette, "terminal_new", hints, "", .run));

    const profiles = try Vt.available_profiles(palette.allocator);
    defer Vt.free_profiles(palette.allocator, profiles);
    for (profiles) |profile| try add_profile_entry(palette, profile, &longest, &longest_hint);

    longest_hint = @max(longest_hint, try add_palette_command(palette, "palette_menu_insert", hints, "Edit profile", .describe));
    return longest_hint - @min(longest_hint, longest) + 3 + indicator_separator;
}

pub fn deinit(palette: *Type) void {
    for (palette.entries.items) |entry| {
        palette.allocator.free(entry.label);
        palette.allocator.free(entry.icon);
        palette.allocator.free(entry.keybind);
    }
}

fn add_palette_command(
    palette: *Type,
    command_name: []const u8,
    hints: *const tui.KeybindHints,
    label_override: []const u8,
    action: CommandAction,
) !usize {
    const id = command.get_id(command_name) orelse return 0;
    var width: usize = 0;
    if (command.get_icon(id)) |icon_| width += tui.egc_chunk_width(icon_, 0, 1);
    if (label_override.len > 0)
        width += tui.egc_chunk_width(label_override, 0, 1)
    else if (command.get_description(id)) |desc|
        width += tui.egc_chunk_width(desc, 0, 1);
    if (hints.get(command_name)) |hint| width += tui.egc_chunk_width(hint, 0, 1);
    (try palette.entries.addOne(palette.allocator)).* = .{
        .label = try palette.allocator.dupe(u8, label_override),
        .idx = 0,
        .command = command_name,
        .command_action = action,
    };
    return width;
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

pub fn on_render_menu(palette: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    var entry: Entry = undefined;
    var iter = button.opts.label; // label contains cbor entry object and matches
    if (!(cbor.matchValue(&iter, cbor.extract(&entry)) catch false))
        entry.label = "#ERROR#";

    const style_base = theme.editor_widget;
    const style_label =
        if (button.active)
            theme.editor_cursor
        else if (button.hover or selected)
            theme.editor_selection
        else if (entry.command) |_|
            theme.input_placeholder
        else
            theme.editor_widget;

    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    button.plane.fill(" ");
    button.plane.home();

    button.plane.set_style(style_hint);
    tui.render_pointer(&button.plane, selected);

    const profile_icon = if (entry.icon.len > 0) entry.icon else terminal_icon;
    const metrics = button.plane.metrics(1);
    const icon_width = metrics.egc_chunk_width(metrics, profile_icon, 0);

    button.plane.set_style(style_label);
    if (entry.command) |command_name| blk: {
        button.plane.set_style(style_hint);
        var label_: std.Io.Writer.Allocating = .init(palette.allocator);
        defer label_.deinit();

        const id = command.get_id(command_name) orelse break :blk;
        if (command.get_icon(id)) |icon_|
            label_.writer.print("{s} ", .{icon_}) catch {};
        if (entry.label.len > 0)
            label_.writer.print("{s}", .{entry.label}) catch {}
        else if (command.get_description(id)) |desc|
            label_.writer.print("{s}", .{desc}) catch {};
        _ = button.plane.print("{s} ", .{label_.written()}) catch {};

        const hints = if (tui.input_mode()) |m| m.keybind_hints else @panic("no keybind hints");
        if (hints.get(command_name)) |hint|
            _ = button.plane.print_aligned_right(0, "{s} ", .{hint}) catch {};
    } else {
        render_colored_icon(&button.plane, profile_icon, entry.color, icon_width);
        _ = button.plane.print(" ", .{}) catch {};
        _ = button.plane.print("{s} ", .{entry.label}) catch {};
        if (entry.keybind.len > 0) {
            button.plane.set_style(style_hint);
            _ = button.plane.print_aligned_right(0, "{s} ", .{entry.keybind}) catch {};
            button.plane.set_style(style_label);
        }
        render_indicator(&button.plane, theme, entry.state, style_label);
    }

    const match_offset: usize = 2 + if (icon_width > 0) @as(usize, icon_width + 2) else 0;
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            tui.render_match_cell(&button.plane, 0, index + match_offset, theme) catch break;
        } else break;
    }
    return false;
}

fn render_indicator(plane: *@import("renderer").Plane, theme: *const Widget.Theme, state: Vt.State, style_label: Widget.Theme.Style) void {
    const indicator: tab_render.Indicator = switch (state) {
        .idle => return,
        .alt_screen => .alt_screen,
        .activity => .activity,
        .busy => .busy,
        .bell => .bell,
        .exited => .exited,
        .exited_error => .exited_error,
    };
    const mv = tui.mainview() orelse return;
    const glyph = tab_render.indicator_glyph(mv.panel_tab_style(), indicator);
    if (glyph.fg) |color|
        plane.set_style(.{ .fg = color.from_theme(theme) });
    _ = plane.print_aligned_right(0, " {s}\u{00A0}", .{glyph.glyph}) catch {};
    plane.set_style(style_label);
}

fn render_colored_icon(plane: *@import("renderer").Plane, glyph: []const u8, glyph_color: u24, icon_width: usize) void {
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    if (!(glyph_color == 0xFFFFFF or glyph_color == 0x000000 or glyph_color == 0x000001))
        cell.set_fg_rgb(glyph_color) catch {};
    _ = plane.cell_load(&cell, glyph) catch {};
    _ = plane.putc(&cell) catch {};
    if (icon_width == 1)
        plane.cursor_move_rel(0, 1) catch {};
}

pub fn edit_selected(palette: *Type, button: ?*Type.ButtonType) !void {
    const button_ = button orelse return;
    var entry: Entry = undefined;
    var iter = button_.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&entry)) catch false)) return;
    const profile = entry.profile orelse return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| palette.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "open_terminal_profile", .{profile} }) catch |e| palette.logger.err(module_name, e);
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    var entry: Entry = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&entry)) catch false)) return;
    const activate = menu.*.opts.ctx.activate;
    menu.*.opts.ctx.activate = .normal;
    const target: PanelArea.Target = switch (activate) {
        .normal => .focused_group,
        .alternate => .new_group,
    };
    if (entry.command) |command_name| if (entry.command_action == .describe) {
        const hints = if (tui.input_mode()) |m| m.keybind_hints else return;
        if (hints.get(command_name)) |hint|
            std.log.info("select a profile and press {s}", .{hint});
        return;
    };
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    if (entry.command) |command_name| {
        tp.self_pid().send(.{ "cmd", command_name, .{ "", target } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    } else if (entry.profile) |profile_name| {
        tp.self_pid().send(.{ "cmd", "terminal_new", .{ profile_name, target } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    } else {
        tp.self_pid().send(.{ "cmd", "terminal_select", .{ entry.idx, target } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    }
}
