const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());

pub const label = "Search commands";
pub const name = "󱊒 command";
pub const description = "command";

pub const Entry = struct {
    label: []const u8,
    hint: []const u8,
    id: command.ID,
};

pub fn deinit(palette: *Type) void {
    for (palette.entries.items) |entry|
        palette.allocator.free(entry.label);
}

pub fn load_entries(palette: *Type) !usize {
    const hints = if (tui.input_mode()) |m| m.keybind_hints else @panic("no keybind hints");
    var longest_hint: usize = 0;
    for (command.commands.items) |cmd_| if (cmd_) |p| {
        var label_: std.Io.Writer.Allocating = .init(palette.allocator);
        defer label_.deinit();
        const writer = &label_.writer;
        try writer.writeAll(p.name);
        if (p.meta.description.len > 0) try writer.print(" ({s})", .{p.meta.description});
        if (p.meta.arguments.len > 0) {
            try writer.writeAll(" {");
            var first = true;
            for (p.meta.arguments) |arg| {
                if (first) {
                    first = false;
                    try writer.print("{s}", .{@tagName(arg)});
                } else {
                    try writer.print(", {s}", .{@tagName(arg)});
                }
            }
            try writer.writeAll("}");
        }

        const hint = hints.get(p.name) orelse "";
        longest_hint = @max(longest_hint, hint.len);

        (try palette.entries.addOne(palette.allocator)).* = .{
            .label = try label_.toOwnedSlice(),
            .hint = hint,
            .id = p.id,
        };
    };
    return longest_hint;
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.hint);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try cbor.writeValue(writer, entry.id);
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    var unused: []const u8 = undefined;
    var command_id: command.ID = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &unused) catch false)) return;
    if (!(cbor.matchString(&iter, &unused) catch false)) return;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    while (len > 0) : (len -= 1)
        cbor.skipValue(&iter) catch break;
    if (!(cbor.matchValue(&iter, cbor.extract(&command_id)) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
    tp.self_pid().send(.{ "cmd", "paste", .{command.get_name(command_id) orelse return} }) catch {};
}
