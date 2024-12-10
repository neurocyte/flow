const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const project_manager = @import("project_manager");

pub const Type = @import("palette.zig").Create(@This());

pub const label = "Search projects";
pub const name = " project";
pub const description = "project";

pub const Entry = struct {
    label: []const u8,
};

pub const Match = struct {
    name: []const u8,
    score: i32,
    matches: []const usize,
};

pub fn deinit(palette: *Type) void {
    for (palette.entries.items) |entry|
        palette.allocator.free(entry.label);
}

pub fn load_entries(palette: *Type) !usize {
    const rsp = try project_manager.request_recent_projects(palette.allocator);
    defer palette.allocator.free(rsp.buf);
    var iter: []const u8 = rsp.buf;
    var len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var name_: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract(&name_))) {
            (try palette.entries.addOne()).* = .{ .label = try palette.allocator.dupe(u8, name_) };
        } else return error.InvalidMessageField;
    }
    return 1;
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
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("open_recent_project", e);
    tp.self_pid().send(.{ "cmd", "change_project", .{name_} }) catch |e| menu.*.opts.ctx.logger.err("open_recent_project", e);
}
