const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;
const command = @import("command");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());

pub const label = "Clipboard history";
pub const name = " clipboard";
pub const description = "clipboard";
pub const icon = "  ";

pub const Entry = struct {
    label: []const u8,
    idx: usize,
    group: usize,
};

pub fn load_entries(palette: *Type) !usize {
    const history = tui.clipboard_get_history() orelse &.{};

    if (history.len > 0) {
        var idx = history.len - 1;
        while (true) : (idx -= 1) {
            const entry = &history[idx];
            var label_ = entry.text;
            while (label_.len > 0) switch (label_[0]) {
                ' ', '\t', '\n' => label_ = label_[1..],
                else => break,
            };
            (try palette.entries.addOne(palette.allocator)).* = .{
                .label = label_,
                .idx = idx,
                .group = entry.group,
            };
            if (idx == 0) break;
        }
    }
    return if (palette.entries.items.len == 0) label.len + 3 else 10;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);

    var hint: std.Io.Writer.Allocating = .init(palette.allocator);
    defer hint.deinit();
    const clipboard_ = tui.clipboard_get_history();
    const clipboard = clipboard_ orelse &.{};
    const clipboard_entry: tui.ClipboardEntry = if (clipboard_) |_| clipboard[entry.idx] else .{};
    const group_idx = tui.clipboard_current_group() - clipboard_entry.group;
    const item = clipboard_entry.text;
    var line_count: usize = 1;
    for (0..item.len) |i| if (item[i] == '\n') {
        line_count += 1;
    };
    if (line_count > 1)
        try hint.writer.print(" {d} lines", .{line_count})
    else
        try hint.writer.print(" {d} {s}", .{ item.len, if (item.len == 1) "byte " else "bytes" });
    try hint.writer.print(" :{d}", .{group_idx});
    try cbor.writeValue(writer, hint.written());

    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try cbor.writeValue(writer, entry.idx);
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    var unused: []const u8 = undefined;
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &unused) catch false)) return;
    if (!(cbor.matchString(&iter, &unused) catch false)) return;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    while (len > 0) : (len -= 1)
        cbor.skipValue(&iter) catch return;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("clipboard_palette", e);

    const history = tui.clipboard_get_history() orelse return;
    if (history.len <= idx) return;
    tp.self_pid().send(.{ "cmd", "paste", .{history[idx].text} }) catch {};
}

pub fn delete_item(menu: *Type.MenuType, button: *Type.ButtonType) bool {
    var unused: []const u8 = undefined;
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &unused) catch false)) return false;
    if (!(cbor.matchString(&iter, &unused) catch false)) return false;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1)
        cbor.skipValue(&iter) catch return false;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch false)) return false;
    command.executeName("clipboard_delete", command.fmt(.{idx})) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    return true; //refresh list
}
