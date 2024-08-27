const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("root");

const command = @import("../../command.zig");

pub const Type = @import("palette.zig").Create(@This());

pub const label = "Search commands";

pub const Entry = struct {
    name: []const u8,
    id: command.ID,
    used_time: i64,
};

pub fn load_entries(palette: *Type) !void {
    for (command.commands.items) |cmd_| if (cmd_) |p| {
        (try palette.entries.addOne()).* = .{ .name = p.name, .id = p.id, .used_time = 0 };
    };
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value = std.ArrayList(u8).init(palette.a);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, entry.name);
    try cbor.writeValue(writer, entry.id);
    try cbor.writeValue(writer, if (palette.hints) |hints| hints.get(entry.name) orelse "" else "");
    if (matches) |matches_|
        try cbor.writeValue(writer, matches_);
    try palette.menu.add_item_with_handler(value.items, select);
    palette.items += 1;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var command_name: []const u8 = undefined;
    var command_id: command.ID = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &command_name) catch false)) return;
    if (!(cbor.matchValue(&iter, cbor.extract(&command_id)) catch false)) return;
    update_used_time(menu.*.opts.ctx, command_id);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
    tp.self_pid().send(.{ "cmd", command_name, .{} }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
}

fn sort_by_used_time(palette: *Type) void {
    const less_fn = struct {
        fn less_fn(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.used_time > rhs.used_time;
        }
    }.less_fn;
    std.mem.sort(Entry, palette.entries.items, {}, less_fn);
}

fn update_used_time(palette: *Type, id: command.ID) void {
    set_used_time(palette, id, std.time.milliTimestamp());
    write_state(palette) catch {};
}

fn set_used_time(palette: *Type, id: command.ID, used_time: i64) void {
    for (palette.entries.items) |*cmd_| if (cmd_.id == id) {
        cmd_.used_time = used_time;
        return;
    };
}

fn write_state(palette: *Type) !void {
    var state_file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_file = try std.fmt.bufPrint(&state_file_buffer, "{s}/{s}", .{ try root.get_state_dir(), "commands" });
    var file = try std.fs.createFileAbsolute(state_file, .{ .truncate = true });
    defer file.close();
    var buffer = std.io.bufferedWriter(file.writer());
    defer buffer.flush() catch {};
    const writer = buffer.writer();

    for (palette.entries.items) |cmd_| {
        if (cmd_.used_time == 0) continue;
        try cbor.writeArrayHeader(writer, 2);
        try cbor.writeValue(writer, cmd_.name);
        try cbor.writeValue(writer, cmd_.used_time);
    }
}

pub fn restore_state(palette: *Type) !void {
    var state_file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_file = try std.fmt.bufPrint(&state_file_buffer, "{s}/{s}", .{ try root.get_state_dir(), "commands" });
    const a = std.heap.c_allocator;
    var file = std.fs.openFileAbsolute(state_file, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer file.close();
    const stat = try file.stat();
    var buffer = try a.alloc(u8, @intCast(stat.size));
    defer a.free(buffer);
    const size = try file.readAll(buffer);
    const data = buffer[0..size];

    defer sort_by_used_time(palette);
    var name: []const u8 = undefined;
    var used_time: i64 = undefined;
    var iter: []const u8 = data;
    while (cbor.matchValue(&iter, .{
        tp.extract(&name),
        tp.extract(&used_time),
    }) catch |e| switch (e) {
        error.CborTooShort => return,
        else => return e,
    }) {
        const id = command.getId(name) orelse continue;
        set_used_time(palette, id, used_time);
    }
}
