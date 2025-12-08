const std = @import("std");
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

pub const label = "Select completion";
pub const name = "completion";
pub const description = "completions";
pub const icon = "󱎸  ";
pub const modal_dim = false;
pub const placement = .top_right;

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

var max_description: usize = 0;

pub fn load_entries(palette: *Type) !usize {
    const editor = tui.get_active_editor() orelse return error.NotFound;
    palette.value.start = editor.get_primary().*;
    var iter: []const u8 = editor.completions.items;
    while (iter.len > 0) {
        var cbor_item: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&cbor_item))) return error.BadCompletion;
        (try palette.entries.addOne(palette.allocator)).* = .{ .cbor = cbor_item, .label = undefined, .sort_text = undefined };
    }

    max_description = 0;
    var max_label_len: usize = 0;
    for (palette.entries.items) |*item| {
        const label_, const sort_text, _, const maybe_replace, _, const label_detail, const label_description, _, _ = get_values(item.cbor);
        if (get_replace_selection(maybe_replace)) |replace| {
            if (palette.value.replace == null) palette.value.replace = replace;
        }
        item.label = label_;
        item.sort_text = sort_text;

        var lines = std.mem.splitScalar(u8, label_description, '\n');
        const label_description_len = if (lines.next()) |desc| desc.len else label_description.len;

        max_label_len = @max(max_label_len, item.label.len);
        max_description = @max(max_description, label_description_len + label_detail.len);
    }

    const less_fn = struct {
        fn less_fn(_: void, lhs: Entry, rhs: Entry) bool {
            const lhs_str = if (lhs.sort_text.len > 0) lhs.sort_text else lhs.label;
            const rhs_str = if (rhs.sort_text.len > 0) rhs.sort_text else rhs.label;
            return std.mem.order(u8, lhs_str, rhs_str) == .lt;
        }
    }.less_fn;
    std.mem.sort(Entry, palette.entries.items, {}, less_fn);

    max_description = @min(max_description, tui.screen().w -| max_label_len -| 10);
    return @max(max_description, if (max_label_len > label.len + 3) 0 else label.len + 3 - max_label_len);
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

//pub fn render_symbol( self: *renderer.Plane, symbol: []const u8, icon: []const u8, color: u24, detail: []const u8, description: []const u8, matches_cbor: []const u8, active: bool, selected: bool, hover: bool, theme_: *const Widget.Theme, ) bool

pub fn on_render_menu(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    var item_cbor: []const u8 = undefined;
    var matches_cbor: []const u8 = undefined;

    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&item_cbor)) catch false)) return false;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&matches_cbor)) catch false)) return false;

    const label_, _, const kind, _, _, const label_detail, const label_description, _, _ = get_values(item_cbor);
    const icon_: []const u8 = kind_icon(@enumFromInt(kind));
    const color: u24 = 0x0;

    return tui.render_symbol(
        &button.plane,
        label_,
        icon_,
        color,
        label_detail,
        label_description,
        matches_cbor,
        button.active,
        selected,
        button.hover,
        theme,
    );
}

fn get_values(item_cbor: []const u8) struct { []const u8, []const u8, u8, Buffer.Selection, []const u8, []const u8, []const u8, []const u8, []const u8 } {
    var label_: []const u8 = "";
    var label_detail: []const u8 = "";
    var label_description: []const u8 = "";
    var detail: []const u8 = "";
    var documentation: []const u8 = "";
    var sort_text: []const u8 = "";
    var kind: u8 = 0;
    var insertTextFormat: usize = 0;
    var textEdit_newText: []const u8 = "";
    var replace: Buffer.Selection = .{};
    var additionalTextEdits: []const u8 = &.{};
    _ = cbor.match(item_cbor, .{
        cbor.any, // file_path
        cbor.any, // row
        cbor.any, // col
        cbor.any, // is_incomplete
        cbor.extract(&label_), // label
        cbor.extract(&label_detail), // label_detail
        cbor.extract(&label_description), // label_description
        cbor.extract(&kind), // kind
        cbor.extract(&detail), // detail
        cbor.extract(&documentation), // documentation
        cbor.any, // documentation_kind
        cbor.extract(&sort_text), // sortText
        cbor.extract(&insertTextFormat), // insertTextFormat
        cbor.extract(&textEdit_newText), // textEdit_newText
        cbor.any, // insert.begin.row
        cbor.any, // insert.begin.col
        cbor.any, // insert.end.row
        cbor.any, // insert.end.col
        cbor.extract(&replace.begin.row), // replace.begin.row
        cbor.extract(&replace.begin.col), // replace.begin.col
        cbor.extract(&replace.end.row), // replace.end.row
        cbor.extract(&replace.end.col), // replace.end.col
        cbor.extract_cbor(&additionalTextEdits),
    }) catch false;
    return .{ label_, sort_text, kind, replace, additionalTextEdits, label_detail, label_description, detail, documentation };
}

const TextEdit = struct { newText: []const u8 = &.{}, insert: ?Range = null, replace: ?Range = null };
const Range = struct { start: Position, end: Position };
const Position = struct { line: usize, character: usize };

fn get_replace_selection(replace: Buffer.Selection) ?Buffer.Selection {
    return if (tui.get_active_editor()) |edt|
        replace.from_pos(edt.buf_root() catch return null, edt.metrics)
    else if (replace.empty())
        null
    else
        replace;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const label_, _, _, _, _, _, _, _, _ = get_values(button.opts.label);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "insert_chars", .{label_} }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    const mv = tui.mainview() orelse return;
    mv.cancel_info_content() catch {};
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(palette);
    _, _, _, const replace, _, _, _, const detail, const documentation = get_values(button.opts.label);
    const editor = tui.get_active_editor() orelse return error.NotFound;
    editor.get_primary().selection = get_replace_selection(replace);

    const mv = tui.mainview() orelse return;
    try mv.set_info_content(detail, .replace);
    try mv.set_info_content(" ", .append); // blank line
    try mv.set_info_content(documentation, .append);
}

pub fn cancel(palette: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    editor.get_primary().selection = palette.value.start.selection;
    const mv = tui.mainview() orelse return;
    mv.cancel_info_content() catch {};
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
