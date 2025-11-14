const std = @import("std");
const fmt = std.fmt;
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;
const command = @import("command");
const Buffer = @import("Buffer");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const ed = @import("../../editor.zig");
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Go to Symbol";
pub const name = "Go to";
pub const description = "Symbols in scope";
pub const icon = "󱎸  ";

pub const Entry = struct {
    label: []const u8,
    row: usize,
    cbor: []const u8,
};

pub const ValueType = struct {
    start: ed.CurSel = .{},
    min_col_name: u8 = 26,
    min_col_parent: u8 = 14,
    min_col_kind: u8 = 12,
};
pub const defaultValue: ValueType = .{};

pub fn load_entries(palette: *Type) !usize {
    const mv = tui.mainview() orelse return 0;
    const editor = tui.get_active_editor() orelse return error.NotFound;
    palette.value.start = editor.get_primary().*;
    var iter: []const u8 = mv.symbols.items;
    while (iter.len > 0) {
        var cbor_item: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&cbor_item))) return error.BadCompletion;
        (try palette.entries.addOne(palette.allocator)).* = .{ .cbor = cbor_item, .label = undefined, .row = undefined };
    }

    var max_label_len: usize = 0;
    var max_parent_len: usize = 0;
    var max_kind_len: usize = 0;
    for (palette.entries.items) |*item| {
        const label_, const parent_, const kind, const row, _ = get_values(item.cbor);
        item.label = label_;
        item.row = row;
        max_label_len = @max(max_label_len, item.label.len);
        max_parent_len = @max(max_parent_len, parent_.len);
        max_kind_len = @max(max_kind_len, kind_name(@enumFromInt(kind)).len);
    }

    palette.value.min_col_name = @min(palette.value.min_col_name, max_label_len);
    palette.value.min_col_parent = @min(palette.value.min_col_parent, max_parent_len);
    palette.value.min_col_kind = @min(palette.value.min_col_kind, max_kind_len);
    const less_fn = struct {
        fn less_fn(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.row < rhs.row;
        }
    }.less_fn;
    std.mem.sort(Entry, palette.entries.items, {}, less_fn);

    return if (max_label_len > label.len + 3) 0 else label.len + 3 - max_label_len;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try writer.writeAll(entry.cbor);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

pub fn on_render_menu(palette: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    var item_cbor: []const u8 = undefined;
    var matches_cbor: []const u8 = undefined;

    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&item_cbor)) catch false)) return false;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&matches_cbor)) catch false)) return false;

    const label_, const container, const kind, _, _ = get_values(item_cbor);
    const icon_: []const u8 = kind_icon(@enumFromInt(kind));
    const color: u24 = 0x0;
    var buffer: [200]u8 = undefined;
    const format_buffer = buffer[0..];
    const this_kind_name = kind_name(@enumFromInt(kind));
    const formatted = fmt.bufPrint(format_buffer, "{s:<26}   {s:<14}   {s:<12}", .{ label_[0..@min(palette.value.min_col_name, label_.len)], container[0..@min(palette.value.min_col_parent, container.len)], this_kind_name[0..@min(palette.value.min_col_kind, this_kind_name.len)] }) catch "";
    const indicator: []const u8 = &.{};

    return tui.render_file_item(&button.plane, formatted, icon_, color, indicator, matches_cbor, button.active, selected, button.hover, theme);
}

fn get_values(item_cbor: []const u8) struct { []const u8, []const u8, u8, usize, usize } {
    var label_: []const u8 = "";
    var container: []const u8 = "";
    var kind: u8 = 0;
    var row: usize = 0;
    var col: usize = 0;
    _ = cbor.match(item_cbor, .{
        cbor.any, // file_path
        cbor.extract(&label_), // name
        cbor.extract(&container), // parent_name
        cbor.extract(&kind), // kind
        cbor.extract(&row), // range.begin.row
        cbor.extract(&col), // range.begin.col
        cbor.any, // range.end.row
        cbor.any, // range.end.col
        cbor.any, // tags
        cbor.any, // selectionRange.begin.row
        cbor.any, // selectionRange.begin.col
        cbor.any, // selectionRange.end.row
        cbor.any, // selectionRange.end.col
        cbor.any, // deprecated
        cbor.any, // detail
    }) catch false;
    return .{ label_, container, kind, row, col };
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    _, _, _, const row, const col = get_values(button.opts.label);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "goto_line_and_column", .{ row + 1, col + 1 } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(palette);
    _, _, _, const row, const col = get_values(button.opts.label);
    tp.self_pid().send(.{ "cmd", "goto_line_and_column", .{ row + 1, col + 1 } }) catch {};
}

pub fn cancel(palette: *Type) !void {
    tp.self_pid().send(.{ "cmd", "goto_line_and_column", .{ palette.value.start.cursor.row + 1, palette.value.start.cursor.col + 1 } }) catch return;
    const editor = tui.get_active_editor() orelse return;
    editor.get_primary().selection = palette.value.start.selection;
}

const SymbolKind = enum(u8) {
    None = 0,
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26,
};

fn kind_icon(kind: SymbolKind) []const u8 {
    return switch (kind) {
        .None => " ",
        .File => "",
        .Module => "",
        .Namespace => "",
        .Package => "",
        .Class => "",
        .Method => "",
        .Property => "",
        .Field => "",
        .Constructor => "",
        .Enum => "",
        .Interface => "",
        .Function => "󰊕",
        .Variable => "",
        .Constant => "",
        .String => "",
        .Number => "",
        .Boolean => "",
        .Array => "",
        .Object => "",
        .Key => "",
        .Null => "󰟢",
        .EnumMember => "",
        .Struct => "",
        .Event => "",
        .Operator => "",
        .TypeParameter => "",
    };
}

fn kind_name(kind: SymbolKind) []const u8 {
    return @tagName(kind);
}
