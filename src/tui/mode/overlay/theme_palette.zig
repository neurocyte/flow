const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");

const Widget = @import("../../Widget.zig");
const tui = @import("../../tui.zig");

pub const Type = @import("palette.zig").Create(@This());

pub const label = "Search themes";
pub const name = " theme";
pub const description = "theme";
pub const modal_dim = false;
pub const placement = .top_right;

pub const Entry = struct {
    label: []const u8,
    name: []const u8,
};

pub const Match = struct {
    name: []const u8,
    score: i32,
    matches: []const usize,
};

pub const ValueType = struct {
    previous_theme: ?[]const u8 = null,
};
pub const defaultValue: ValueType = .{};

pub fn load_entries(palette: *Type) !usize {
    var longest_hint: usize = 0;
    var idx: usize = 0;
    try set_previous_theme(palette, tui.theme().name);
    for (Widget.themes) |theme| {
        idx += 1;
        (try palette.entries.addOne(palette.allocator)).* = .{
            .label = theme.description,
            .name = theme.name,
        };
        if (get_previous_theme(palette)) |theme_name| if (std.mem.eql(u8, theme.name, theme_name)) {
            palette.initial_selected = idx;
        };
        longest_hint = @max(longest_hint, theme.name.len);
    }
    palette.quick_activate_enabled = false;
    return longest_hint;
}

pub fn deinit(palette: *Type) void {
    clear_previous_theme(palette);
}

fn clear_previous_theme(palette: *Type) void {
    tp.trace(tp.channel.debug, .{ "clear_previous_theme", palette.value.previous_theme });
    if (palette.value.previous_theme) |old| palette.allocator.free(old);
    palette.value.previous_theme = null;
}

fn set_previous_theme(palette: *Type, theme: []const u8) error{OutOfMemory}!void {
    tp.trace(tp.channel.debug, .{ "set_previous_theme", palette.value.previous_theme, theme });
    clear_previous_theme(palette);
    palette.value.previous_theme = try palette.allocator.dupe(u8, theme);
}

fn get_previous_theme(palette: *Type) ?[]const u8 {
    tp.trace(tp.channel.debug, .{ "get_previous_theme", palette.value.previous_theme });
    return palette.value.previous_theme;
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.name);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const palette = menu.*.opts.ctx;
    var description_: []const u8 = undefined;
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &description_) catch false)) return;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    if (get_previous_theme(palette)) |prev| if (std.mem.eql(u8, prev, name_))
        return;
    tp.self_pid().send(.{ "cmd", "set_theme", .{name_} }) catch |e| palette.logger.err("theme_palette", e);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| palette.logger.err("theme_palette", e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(palette);
    var description_: []const u8 = undefined;
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &description_) catch false)) return;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    tp.self_pid().send(.{ "cmd", "set_theme", .{name_} }) catch |e| palette.logger.err("theme_palette upated", e);
}

pub fn cancel(palette: *Type) !void {
    if (get_previous_theme(palette)) |name_| if (!std.mem.eql(u8, name_, tui.theme().name)) {
        tp.self_pid().send(.{ "cmd", "set_theme", .{name_} }) catch |e| palette.logger.err("theme_palette cancel", e);
        clear_previous_theme(palette);
    };
}
