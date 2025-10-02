const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("root");
const command = @import("command");
const Buffer = @import("Buffer");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const ed = @import("../../editor.zig");
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Select completion";
pub const name = "completion";
pub const description = "completions";
pub const icon = "󱎸  ";

pub const Entry = struct {
    label: []const u8,
    sort_text: []const u8,
    cbor: []const u8,
};

pub const ValueType = struct {
    start: ed.CurSel = .{},
    replace: ?Buffer.Selection = null,
};
pub const defaultValue: ValueType = .{};

pub fn load_entries(palette: *Type) !usize {
    const editor = tui.get_active_editor() orelse return error.NotFound;
    palette.value.start = editor.get_primary().*;
    var iter: []const u8 = editor.completions.items;
    while (iter.len > 0) {
        var cbor_item: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&cbor_item))) return error.BadCompletion;
        (try palette.entries.addOne(palette.allocator)).* = .{ .cbor = cbor_item, .label = undefined, .sort_text = undefined };
    }

    var max_label_len: usize = 0;
    for (palette.entries.items) |*item| {
        const label_, const sort_text, _, const replace = get_values(item.cbor);
        if (palette.value.replace == null and !(replace.begin.row == 0 and replace.begin.col == 0 and replace.end.row == 0 and replace.end.col == 0))
            palette.value.replace = replace;
        item.label = label_;
        item.sort_text = sort_text;
        max_label_len = @max(max_label_len, item.label.len);
    }

    const less_fn = struct {
        fn less_fn(_: void, lhs: Entry, rhs: Entry) bool {
            const lhs_str = if (lhs.sort_text.len > 0) lhs.sort_text else lhs.label;
            const rhs_str = if (rhs.sort_text.len > 0) rhs.sort_text else rhs.label;
            return std.mem.order(u8, lhs_str, rhs_str) == .lt;
        }
    }.less_fn;
    std.mem.sort(Entry, palette.entries.items, {}, less_fn);

    return if (max_label_len > label.len + 3) 0 else label.len + 3 - max_label_len;
}

pub fn initial_query(palette: *Type, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    return if (palette.value.replace) |replace| blk: {
        const editor = tui.get_active_editor() orelse break :blk allocator.dupe(u8, "");
        const sel: Buffer.Selection = .{ .begin = replace.begin, .end = palette.value.start.cursor };
        break :blk editor.get_selection(sel, allocator) catch break :blk allocator.dupe(u8, "");
    } else allocator.dupe(u8, "");
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

pub fn on_render_menu(_: *Type, button: *Type.ButtonState, theme: *const Widget.Theme, selected: bool) bool {
    var item_cbor: []const u8 = undefined;
    var matches_cbor: []const u8 = undefined;

    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&item_cbor)) catch false)) return false;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&matches_cbor)) catch false)) return false;

    const label_, _, const kind, _ = get_values(item_cbor);
    const icon_: []const u8 = kind_icon(@enumFromInt(kind));
    const color: u24 = 0x0;
    const indicator: []const u8 = &.{};

    return tui.render_file_item(&button.plane, label_, icon_, color, indicator, matches_cbor, button.active, selected, button.hover, theme);
}

fn get_values(item_cbor: []const u8) struct { []const u8, []const u8, u8, Buffer.Selection } {
    var label_: []const u8 = "";
    var sort_text: []const u8 = "";
    var kind: u8 = 0;
    var replace: Buffer.Selection = .{};
    _ = cbor.match(item_cbor, .{
        cbor.any, // file_path
        cbor.any, // row
        cbor.any, // col
        cbor.any, // is_incomplete
        cbor.extract(&label_), // label
        cbor.any, // label_detail
        cbor.any, // label_description
        cbor.extract(&kind), // kind
        cbor.any, // detail
        cbor.any, // documentation
        cbor.any, // documentation_kind
        cbor.extract(&sort_text), // sortText
        cbor.any, // insertTextFormat
        cbor.any, // textEdit_newText
        cbor.any, // insert.begin.row
        cbor.any, // insert.begin.col
        cbor.any, // insert.end.row
        cbor.any, // insert.end.col
        cbor.extract(&replace.begin.row), // replace.begin.row
        cbor.extract(&replace.begin.col), // replace.begin.col
        cbor.extract(&replace.end.row), // replace.end.row
        cbor.extract(&replace.end.col), // replace.end.col
    }) catch false;
    return .{ label_, sort_text, kind, replace };
}

fn select(menu: **Type.MenuState, button: *Type.ButtonState) void {
    const label_, _, _, _ = get_values(button.opts.label);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "insert_chars", .{label_} }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonState) !void {
    const button = button_ orelse return cancel(palette);
    _, _, _, const replace = get_values(button.opts.label);
    const editor = tui.get_active_editor() orelse return error.NotFound;
    editor.get_primary().selection = if (replace.empty()) null else replace;
}

pub fn cancel(palette: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    editor.get_primary().selection = palette.value.start.selection;
}

const CompletionItemKind = enum(u8) {
    None = 0,
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25,
};

fn kind_icon(kind: CompletionItemKind) []const u8 {
    return switch (kind) {
        .None => " ",
        .Text => "󰊄",
        .Method => "",
        .Function => "󰊕",
        .Constructor => "",
        .Field => "",
        .Variable => "",
        .Class => "",
        .Interface => "",
        .Module => "",
        .Property => "",
        .Unit => "󱔁",
        .Value => "󱔁",
        .Enum => "",
        .Keyword => "",
        .Snippet => "",
        .Color => "",
        .File => "",
        .Reference => "※",
        .Folder => "🗀",
        .EnumMember => "",
        .Constant => "",
        .Struct => "",
        .Event => "",
        .Operator => "",
        .TypeParameter => "",
    };
}
