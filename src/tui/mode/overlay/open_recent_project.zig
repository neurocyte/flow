const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const project_manager = @import("project_manager");
const command = @import("command");

pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());

pub const label = "Search projects";
pub const name = " project";
pub const description = "project";

pub const Entry = struct {
    label: []const u8,
    open: bool,
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

pub fn load_entries_with_args(palette: *Type, ctx: command.Context) !usize {
    var items_cbor: []const u8 = undefined;
    if (!(cbor.match(ctx.args.buf, .{ "PRJ", "recent_projects", tp.extract_cbor(&items_cbor) }) catch false))
        return error.InvalidRecentProjects;

    var iter: []const u8 = items_cbor;
    var len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var name_: []const u8 = undefined;
        var open: bool = false;
        if (try cbor.decodeArrayHeader(&iter) != 2)
            return error.InvalidMessageField;
        if (!try cbor.matchValue(&iter, cbor.extract(&name_)))
            return error.InvalidMessageField;
        if (!try cbor.matchValue(&iter, cbor.extract(&open)))
            return error.InvalidMessageField;
        (try palette.entries.addOne(palette.allocator)).* = .{ .label = try palette.allocator.dupe(u8, name_), .open = open };
    }
    return 1;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, if (entry.open) "-" else "");
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &name_) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("open_recent_project", e);
    tp.self_pid().send(.{ "cmd", "change_project", .{name_} }) catch |e| menu.*.opts.ctx.logger.err("open_recent_project", e);
}

pub fn delete_item(menu: *Type.MenuState, button: *Type.ButtonState) bool {
    var name_: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &name_) catch false)) return false;
    command.executeName("close_project", command.fmt(.{name_})) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    return true; //refresh list
}
