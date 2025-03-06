const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const syntax = @import("syntax");

const Widget = @import("../../Widget.zig");
const tui = @import("../../tui.zig");

pub const Type = @import("palette.zig").Create(@This());

pub const label = "Select file type";
pub const name = " file type";
pub const description = "file type";

pub const Entry = struct {
    label: []const u8,
    name: []const u8,
    icon: []const u8,
    color: u24,
};

pub const Match = struct {
    name: []const u8,
    score: i32,
    matches: []const usize,
};

var previous_file_type: ?[]const u8 = null;

pub fn load_entries(palette: *Type) !usize {
    var longest_hint: usize = 0;
    var idx: usize = 0;
    previous_file_type = blk: {
        if (tui.get_active_editor()) |editor|
            if (editor.syntax) |editor_syntax|
                break :blk editor_syntax.file_type.name;
        break :blk null;
    };

    for (syntax.FileType.file_types) |file_type| {
        idx += 1;
        (try palette.entries.addOne()).* = .{
            .label = file_type.description,
            .name = file_type.name,
            .icon = file_type.icon,
            .color = file_type.color,
        };
        if (previous_file_type) |file_type_name| if (std.mem.eql(u8, file_type.name, file_type_name)) {
            palette.initial_selected = idx;
        };
        longest_hint = @max(longest_hint, file_type.name.len);
    }
    return longest_hint;
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value = std.ArrayList(u8).init(palette.allocator);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.icon);
    try cbor.writeValue(writer, entry.color);
    try cbor.writeValue(writer, entry.name);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonState, theme: *const Widget.Theme, selected: bool) bool {
    const style_base = theme.editor_widget;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        button.plane.fill(" ");
        button.plane.home();
    }

    button.plane.set_style(style_hint);
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}", .{pointer}) catch {};

    var iter = button.opts.label;
    var description_: []const u8 = undefined;
    var icon: []const u8 = undefined;
    var color: u24 = undefined;
    if (!(cbor.matchString(&iter, &description_) catch false)) @panic("invalid file_type description");
    if (!(cbor.matchString(&iter, &icon) catch false)) @panic("invalid file_type icon");
    if (!(cbor.matchInt(u24, &iter, &color) catch false)) @panic("invalid file_type color");
    if (tui.config().show_fileicons) {
        tui.render_file_icon(&button.plane, icon, color);
        _ = button.plane.print(" ", .{}) catch {};
    }
    button.plane.set_style(style_label);
    _ = button.plane.print("{s} ", .{description_}) catch {};

    var name_: []const u8 = undefined;
    if (!(cbor.matchString(&iter, &name_) catch false))
        name_ = "";
    button.plane.set_style(style_hint);
    _ = button.plane.print_aligned_right(0, "{s} ", .{name_}) catch {};

    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            tui.render_match_cell(&button.plane, 0, index + 4, theme) catch break;
        } else break;
    }
    return false;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var description_: []const u8 = undefined;
    var icon: []const u8 = undefined;
    var color: u24 = undefined;
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &description_) catch false)) return;
    if (!(cbor.matchString(&iter, &icon) catch false)) return;
    if (!(cbor.matchInt(u24, &iter, &color) catch false)) return;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    if (previous_file_type) |prev| if (std.mem.eql(u8, prev, name_))
        return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("file_type_palette", e);
    tp.self_pid().send(.{ "cmd", "set_file_type", .{name_} }) catch |e| menu.*.opts.ctx.logger.err("file_type_palette", e);
}
