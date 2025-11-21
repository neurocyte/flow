const std = @import("std");
const fmt = std.fmt;
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;
const text_manip = @import("text_manip");
const write_string = text_manip.write_string;
const write_padding = text_manip.write_padding;
const command = @import("command");
const Buffer = @import("Buffer");
const SymbolKind = @import("lsp_types").SymbolKind;

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const ed = @import("../../editor.zig");
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Go to Symbol";
pub const name = "Go to";
pub const description = "Symbols in scope";
pub const icon = "󱎸  ";
pub const modal_dim = false;
pub const placement = .top_right;

const Column = struct {
    label: []const u8,
    max_width: u8,
    min_width: u8,
};
const ColumnName = enum(u8) {
    Name = 0,
    Container = 1,
    Kind = 2,
};
const columns: [3]Column = .{
    .{ .label = "Name", .max_width = 26, .min_width = 4 },
    .{ .label = "Container", .max_width = 14, .min_width = 4 },
    .{ .label = "Kind", .max_width = 12, .min_width = 4 },
};

pub const Entry = struct {
    label: []const u8,
    range: ed.Selection,
    cbor: []const u8,
};

pub const ValueType = struct {
    start: ed.CurSel = .{},
    view: ed.View = .{},
    column_size: [3]u8 = undefined,
};
pub const defaultValue: ValueType = .{};

fn init_col_sizes(palette: *Type) void {
    for (0..columns.len) |i| {
        palette.value.column_size[i] = columns[i].min_width;
    }
}

fn update_min_col_sizes(palette: *Type) void {
    for (0..columns.len) |i| {
        palette.value.column_size[i] = @min(columns[i].max_width, palette.value.column_size[i]);
    }
}

fn update_max_col_sizes(palette: *Type, comp_sizes: []const usize) u8 {
    var total_length: u8 = 0;
    for (0..columns.len) |i| {
        const truncated: u8 = @truncate(comp_sizes[i]);
        palette.value.column_size[i] = @max(if (truncated > columns[i].max_width) columns[i].max_width else truncated, palette.value.column_size[i]);
        total_length += palette.value.column_size[i];
    }
    return total_length;
}

fn write_columns(palette: *Type, writer: anytype, column_info: [][]const u8) void {
    if (palette.value.column_size.len == 0)
        return;
    write_string(writer, column_info[0][0..@min(palette.value.column_size[0], column_info[0].len)], columns[0].max_width) catch {};

    for (1..column_info.len) |i| {
        write_padding(writer, 1, 2) catch {};
        write_string(writer, column_info[i][0..@min(palette.value.column_size[i], column_info[i].len)], columns[i].max_width) catch {};
    }
}

fn total_row_width() u8 {
    var total_width: u8 = 0;

    for (columns) |col| {
        total_width += col.max_width;
    }
    return total_width;
}

pub fn load_entries(palette: *Type) !usize {
    const mv = tui.mainview() orelse return 0;
    const editor = tui.get_active_editor() orelse return error.NotFound;
    var max_cols_len: u8 = 0;
    var max_label_len: usize = 0;

    palette.value.start = editor.get_primary().*;
    palette.value.view = editor.view;
    var iter: []const u8 = mv.symbols.items;
    init_col_sizes(palette);
    while (iter.len > 0) {
        var cbor_item: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&cbor_item))) return error.BadCompletion;
        const label_, const parent_, const kind, const sel = get_values(cbor_item);
        const label_len_ = tui.egc_chunk_width(label_, 0, 1);
        const parent_len = tui.egc_chunk_width(parent_, 0, 1);
        (try palette.entries.addOne(palette.allocator)).* = .{ .cbor = cbor_item, .label = label_[0..@min(columns[0].max_width, label_len_)], .range = sel };


        const current_lengths: [3]usize = .{ label_len_, parent_len, @tagName(kind).len };
        const label_len: u8 = @truncate(if (label_len_ > columns[0].max_width) columns[0].max_width else label_len_);
        max_cols_len = @max(max_cols_len, label_len, update_max_col_sizes(palette, &current_lengths));
        max_label_len = @max(max_label_len, label_len);
    }
    update_min_col_sizes(palette);

    const less_fn = struct {
        fn less_fn(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.range.begin.row < rhs.range.begin.row;
        }
    }.less_fn;
    std.mem.sort(Entry, palette.entries.items, {}, less_fn);

    palette.initial_selected = find_closest(palette);
    palette.quick_activate_enabled = false;

    const total_width = total_row_width();
    const outer_label_len = tui.egc_chunk_width(label, 0, 1);
    return 2 + if (max_cols_len > outer_label_len + 3) total_width - max_label_len else outer_label_len + 1 - max_cols_len;
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

    const label_, const container, const kind, _ = get_values(item_cbor);
    const icon_: []const u8 = kind.icon();
    const color: u24 = 0x0;
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    var column_info = [_][]const u8{ label_, container, @tagName(kind) };
    write_columns(palette, writer, &column_info);
    const indicator: []const u8 = &.{};

    return tui.render_file_item(&button.plane, value.written(), icon_, color, indicator, &.{}, matches_cbor, button.active, selected, button.hover, theme);
}

fn get_values(item_cbor: []const u8) struct { []const u8, []const u8, SymbolKind, ed.Selection } {
    var label_: []const u8 = "";
    var container: []const u8 = "";
    var kind: u8 = 0;
    var range: ed.Selection = .{};
    _ = cbor.match(item_cbor, .{
        cbor.any, // file_path
        cbor.extract(&label_), // name
        cbor.extract(&container), // parent_name
        cbor.extract(&kind), // kind
        cbor.extract(&range.begin.row), // range.begin.row
        cbor.extract(&range.begin.col), // range.begin.col
        cbor.extract(&range.end.row), // range.end.row
        cbor.extract(&range.end.col), // range.end.col
        cbor.any, // tags
        cbor.any, // selectionRange.begin.row
        cbor.any, // selectionRange.begin.col
        cbor.any, // selectionRange.end.row
        cbor.any, // selectionRange.end.col
        cbor.any, // deprecated
        cbor.any, // detail
    }) catch false;
    return .{ label_, container, @enumFromInt(kind), range };
}

fn find_closest(palette: *Type) ?usize {
    const editor = tui.get_active_editor() orelse return null;
    const cursor = editor.get_primary().cursor;
    var previous: usize = 0;
    for (palette.entries.items, 0..) |entry, idx| {
        _, _, _, const sel = get_values(entry.cbor);
        if (cursor.row < sel.begin.row) return previous + 1;
        previous = idx;
    }
    return null;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const editor = tui.get_active_editor() orelse return;
    editor.clear_matches();
    _, _, _, const sel = get_values(button.opts.label);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "goto_line_and_column", .{ sel.begin.row + 1, sel.begin.col + 1 } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(palette);
    _, _, _, const sel = get_values(button.opts.label);
    tp.self_pid().send(.{ "cmd", "focus_on_range", .{ sel.begin.row, sel.begin.col, sel.end.row, sel.end.col } }) catch {};
}

pub fn cancel(palette: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    editor.clear_matches();
    editor.update_scroll_dest_abs(palette.value.view.row);
}
