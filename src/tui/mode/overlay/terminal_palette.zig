const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");

const Vt = @import("../../Vt.zig");
const module_name = @typeName(@This());
pub const Type = @import("palette.zig").Create(@This());

pub const label = "Select terminal";
pub const name = " terminal";
pub const description = "terminal";
pub const icon = "  ";

pub const Entry = struct {
    label: []const u8,
    idx: usize,
};

fn add_entry(palette: *Type, vt: *Vt, idx: usize) !void {
    (try palette.entries.addOne(palette.allocator)).* = .{
        .label = try palette.allocator.dupe(u8, vt.get_title()),
        .idx = idx,
    };
}

pub fn load_entries(palette: *Type) !usize {
    const mr_idx = Vt.Manager.most_recent_index();
    if (mr_idx) |mri| {
        if (Vt.Manager.by_index(mri)) |vt| try add_entry(palette, vt, mri);
    }
    var idx: usize = 0;
    while (Vt.Manager.by_index(idx)) |vt| : (idx += 1) {
        if (mr_idx == idx) continue;
        try add_entry(palette, vt, idx);
    }
    return if (palette.entries.items.len == 0) label.len + 3 else 10;
}

pub fn deinit(palette: *Type) void {
    for (palette.entries.items) |entry| palette.allocator.free(entry.label);
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.idx);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, tp.string) catch false)) return;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "terminal_select", .{idx} }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}
