const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");

const Widget = @import("../../Widget.zig");
const tui = @import("../../tui.zig");

pub const Type = @import("palette.zig").Create(@This());

pub const label = "Select font face";
pub const name = " font";
pub const description = "font";

pub const Entry = struct {
    label: []const u8,
};

pub const Match = struct {
    label: []const u8,
    score: i32,
    matches: []const usize,
};

var previous_fontface: ?[]const u8 = null;

pub fn deinit(palette: *Type) void {
    if (previous_fontface) |fontface|
        palette.allocator.free(fontface);
    previous_fontface = null;
    for (palette.entries.items) |entry|
        palette.allocator.free(entry.label);
}

pub fn load_entries(palette: *Type) !usize {
    var idx: usize = 0;
    previous_fontface = try palette.allocator.dupe(u8, tui.current().fontface);
    const fontfaces = tui.current().fontfaces orelse return 0;
    tui.current().fontfaces = null;
    for (fontfaces.items) |fontface| {
        idx += 1;
        (try palette.entries.addOne()).* = .{ .label = fontface };
        if (previous_fontface) |previous_fontface_| if (std.mem.eql(u8, fontface, previous_fontface_)) {
            palette.initial_selected = idx;
        };
    }
    return 0;
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value = std.ArrayList(u8).init(palette.allocator);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var label_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &label_) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("fontface_palette", e);
    tp.self_pid().send(.{ "cmd", "set_fontface", .{label_} }) catch |e| menu.*.opts.ctx.logger.err("fontface_palette", e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonState) !void {
    const button = button_ orelse return cancel(palette);
    var label_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &label_) catch false)) return;
    tp.self_pid().send(.{ "cmd", "set_fontface", .{label_} }) catch |e| palette.logger.err("fontface_palette upated", e);
}

pub fn cancel(palette: *Type) !void {
    if (previous_fontface) |prev|
        tp.self_pid().send(.{ "cmd", "set_fontface", .{prev} }) catch |e| palette.logger.err("fontface_palette cancel", e);
}
