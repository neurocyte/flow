const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");

const Widget = @import("../../Widget.zig");
const tui = @import("../../tui.zig");

pub const Type = @import("palette.zig").Create(@This());

pub const label = "Search themes";
pub const name = " theme";
pub const description = "theme";

pub const Entry = struct {
    label: []const u8,
    name: []const u8,
};

pub const Match = struct {
    name: []const u8,
    score: i32,
    matches: []const usize,
};

var previous_theme: ?[]const u8 = null;
pub fn load_entries(palette: *Type) !void {
    var idx: usize = 0;
    previous_theme = tui.current().theme.name;
    for (Widget.themes) |theme| {
        idx += 1;
        (try palette.entries.addOne()).* = .{
            .label = theme.description,
            .name = theme.name,
        };
        if (previous_theme) |theme_name| if (std.mem.eql(u8, theme.name, theme_name)) {
            palette.initial_selected = idx;
        };
    }
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value = std.ArrayList(u8).init(palette.allocator);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.name);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var description_: []const u8 = undefined;
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &description_) catch false)) return;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    if (previous_theme) |prev| if (std.mem.eql(u8, prev, name_))
        return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("theme_palette", e);
    tp.self_pid().send(.{ "cmd", "set_theme", .{name_} }) catch |e| menu.*.opts.ctx.logger.err("theme_palette", e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonState) !void {
    const button = button_ orelse return cancel(palette);
    var description_: []const u8 = undefined;
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &description_) catch false)) return;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    tp.self_pid().send(.{ "cmd", "set_theme", .{name_} }) catch |e| palette.logger.err("theme_palette upated", e);
}

pub fn cancel(palette: *Type) !void {
    if (previous_theme) |name_| if (!std.mem.eql(u8, name_, tui.current().theme.name)) {
        previous_theme = null;
        tp.self_pid().send(.{ "cmd", "set_theme", .{name_} }) catch |e| palette.logger.err("theme_palette cancel", e);
    };
}
