const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;
const command = @import("command");
const Buffer = @import("Buffer");
const builtin = @import("builtin");
const CompletionItemKind = @import("lsp_types").CompletionItemKind;

const tui = @import("../../tui.zig");
pub const Type = @import("dropdown.zig").Create(@This());
const ed = @import("../../editor.zig");
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Select completion";
pub const name = "completion";
pub const description = "completions";
pub const icon = "󱎸  ";
pub const modal_dim = false;
pub const placement = .primary_cursor;
pub const widget_type: Widget.Type = .dropdown;
pub var detail_limit: usize = 40;
pub var description_limit: usize = 25;

pub const Entry = struct {
    label: []const u8,
    sort_text: []const u8,
    cbor: []const u8,
};

pub const ValueType = struct {
    editor: *ed.Editor = undefined,
    cursor: ed.Cursor = .{},
    view: ed.View = .{},
    query: ?Buffer.Selection = null,
    last_query: ?[]const u8 = null,
    commands: command.Collection(cmds) = undefined,
    data: []const u8 = &.{},
};
pub const defaultValue: ValueType = .{};

var max_description: usize = 0;

pub fn init(self: *Type) error{ Stop, OutOfMemory }!void {
    try self.value.commands.init(self);
    self.value.editor = tui.get_active_editor() orelse return error.Stop;
    self.value.view = self.value.editor.view;
}

pub fn load_entries(self: *Type) !usize {
    max_description = 0;
    var max_label_len: usize = 0;

    self.value.cursor = self.value.editor.get_primary().cursor;
    self.value.query = null;
    self.allocator.free(self.value.data);
    self.value.data = try self.allocator.dupe(u8, self.value.editor.completions.data.items);
    var iter: []const u8 = self.value.data;
    while (iter.len > 0) {
        var cbor_item: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract_cbor(&cbor_item))) return error.BadCompletion;
        const values = get_values(cbor_item);

        if (self.value.query == null) if (get_query_selection(self.value.editor, values)) |query| {
            self.value.query = query;
        };
        const item = try self.entries.addOne(self.allocator);
        item.* = .{
            .cbor = cbor_item,
            .label = values.label,
            .sort_text = values.sort_text,
        };

        var lines = std.mem.splitScalar(u8, values.label_description, '\n');
        const label_description_len: usize = if (lines.next()) |desc| desc.len else values.label_description.len;

        max_label_len = @max(max_label_len, item.label.len);
        max_description = @max(max_description, @min(label_description_len, description_limit) + @min(values.label_detail.len, detail_limit) + 2);
    }

    const less_fn = struct {
        fn less_fn(_: void, lhs: Entry, rhs: Entry) bool {
            const lhs_str = if (lhs.sort_text.len > 0) lhs.sort_text else lhs.label;
            const rhs_str = if (rhs.sort_text.len > 0) rhs.sort_text else rhs.label;
            return std.mem.order(u8, lhs_str, rhs_str) == .lt;
        }
    }.less_fn;
    std.mem.sort(Entry, self.entries.items, {}, less_fn);

    max_description = @min(max_description, tui.screen().w -| max_label_len -| 10);
    return @max(max_description, if (max_label_len > label.len + 3) 0 else label.len + 3 - max_label_len);
}

pub fn deinit(self: *Type) void {
    self.allocator.free(self.value.data);
    if (self.value.last_query) |p| self.allocator.free(p);
    self.value.commands.deinit();
}

pub fn handle_event(self: *Type, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ "E", "update" }) or
        try m.match(.{ "E", "sel", tp.more }) or
        try m.match(.{ "E", "view", tp.more }) or
        try m.match(.{ "E", "pos", tp.more }) or
        try m.match(.{ "E", "close" }))
    {
        const cursor = self.value.editor.get_primary().cursor;
        if (!maybe_cancel(self, cursor))
            maybe_update_query(self, cursor) catch |e| self.logger.err(module_name, e);
    }
}

pub fn initial_query(self: *Type, allocator: std.mem.Allocator) error{ Stop, OutOfMemory }![]const u8 {
    return allocator.dupe(u8, try get_query_text(self, self.value.cursor, allocator));
}

fn get_query_text_nostore(self: *Type, cursor: ed.Cursor, allocator: std.mem.Allocator) error{ Stop, OutOfMemory }![]const u8 {
    return if (self.value.query) |query| blk: {
        const sel: Buffer.Selection = .{ .begin = query.begin, .end = cursor };
        break :blk try self.value.editor.get_selection(sel, allocator);
    } else allocator.dupe(u8, "");
}

fn get_query_text(self: *Type, cursor: ed.Cursor, allocator: std.mem.Allocator) error{ Stop, OutOfMemory }![]const u8 {
    if (self.value.last_query) |p| self.allocator.free(p);
    self.value.last_query = null;
    const query = try get_query_text_nostore(self, cursor, allocator);
    self.value.last_query = query;
    return query;
}

fn maybe_cancel(self: *Type, cursor: Buffer.Cursor) bool {
    if (self.value.cursor.row != cursor.row or
        self.value.cursor.col > cursor.col or
        !self.value.view.eql(self.value.editor.view))
    {
        tp.self_pid().send(.{ "cmd", "palette_menu_cancel" }) catch |e| self.logger.err(module_name, e);
        return true;
    }
    return false;
}

fn maybe_update_query(self: *Type, cursor: Buffer.Cursor) error{OutOfMemory}!void {
    const query = get_query_text_nostore(self, cursor, self.allocator) catch |e| switch (e) {
        error.Stop => return,
        else => |e_| return e_,
    };
    defer self.allocator.free(query);
    if (self.value.last_query) |last| {
        if (!std.mem.eql(u8, query, last))
            try update_query_text(self, cursor);
    } else try update_query_text(self, cursor);

    if (self.match_count == 0)
        tp.self_pid().send(.{ "cmd", "completion" }) catch |e| self.logger.err(module_name, e);
}

fn update_query_text(self: *Type, cursor: ed.Cursor) error{OutOfMemory}!void {
    const query = get_query_text(self, cursor, self.allocator) catch |e| switch (e) {
        error.Stop => return,
        else => |e_| return e_,
    };
    Type.update_query(self, query) catch return;
    return;
}

pub fn clear_entries(self: *Type) void {
    self.entries.clearRetainingCapacity();
}

pub fn add_menu_entry(self: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(self.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try writer.writeAll(entry.cbor);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try self.menu.add_item_with_handler(value.written(), select);
    self.items += 1;
}

pub fn on_render_menu(self: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    var item_cbor: []const u8 = undefined;
    var matches_cbor: []const u8 = undefined;

    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&item_cbor)) catch false)) return false;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&matches_cbor)) catch false)) return false;

    const values = get_values(item_cbor);
    const icon_: []const u8 = values.kind.icon();
    const color: u24 = 0x0;

    if (tui.config().enable_terminal_cursor) blk: {
        const cursor = self.value.editor.get_primary_abs() orelse break :blk;
        tui.rdr().cursor_enable(@intCast(cursor.row), @intCast(cursor.col), tui.get_cursor_shape()) catch {};
    }

    return tui.render_symbol(
        &button.plane,
        values.label,
        icon_,
        color,
        values.label_detail[0..@min(values.label_detail.len, detail_limit)],
        values.label_description[0..@min(values.label_description.len, description_limit)],
        matches_cbor,
        button.active,
        selected,
        button.hover,
        theme,
        if (values.label_detail.len > detail_limit) "…" else "",
        if (values.label_description.len > description_limit) "…" else "",
        &.{},
    );
}

pub const Values = struct {
    label: []const u8,
    sort_text: []const u8,
    kind: CompletionItemKind,
    insert: ?Buffer.Selection,
    replace: ?Buffer.Selection,
    additionalTextEdits: []const u8,
    label_detail: []const u8,
    label_description: []const u8,
    detail: []const u8,
    documentation: []const u8,
    insertText: []const u8,
    insertTextFormat: usize,
    textEdit_newText: []const u8,
};

pub fn get_values(item_cbor: []const u8) Values {
    var label_: []const u8 = "";
    var label_detail: []const u8 = "";
    var label_description: []const u8 = "";
    var detail: []const u8 = "";
    var documentation: []const u8 = "";
    var sort_text: []const u8 = "";
    var kind: u8 = 0;
    var insertText: []const u8 = "";
    var insertTextFormat: usize = 0;
    var textEdit_newText: []const u8 = "";
    var insert_cbor: []const u8 = &.{};
    var replace_cbor: []const u8 = &.{};
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
        cbor.extract(&insertText), // insertText
        cbor.extract(&insertTextFormat), // insertTextFormat
        cbor.extract(&textEdit_newText), // textEdit_newText
        cbor.extract_cbor(&insert_cbor),
        cbor.extract_cbor(&replace_cbor),
        cbor.extract_cbor(&additionalTextEdits),
    }) catch false;
    return .{
        .label = label_,
        .sort_text = sort_text,
        .kind = @enumFromInt(kind),
        .insert = get_range(insert_cbor),
        .replace = get_range(replace_cbor),
        .additionalTextEdits = additionalTextEdits,
        .label_detail = label_detail,
        .label_description = label_description,
        .detail = detail,
        .documentation = documentation,
        .insertTextFormat = insertTextFormat,
        .insertText = insertText,
        .textEdit_newText = textEdit_newText,
    };
}

fn get_range(range_cbor: []const u8) ?Buffer.Selection {
    var range: Buffer.Selection = .{};
    return if (cbor.match(range_cbor, tp.null_) catch false)
        null
    else if (cbor.match(range_cbor, .{
        cbor.extract(&range.begin.row),
        cbor.extract(&range.begin.col),
        cbor.extract(&range.end.row),
        cbor.extract(&range.end.col),
    }) catch false)
        range
    else
        null;
}

const TextEdit = struct { newText: []const u8 = &.{}, insert: ?Range = null, replace: ?Range = null };
const Range = struct { start: Position, end: Position };
const Position = struct { line: usize, character: usize };

pub fn get_query_selection(editor: *ed.Editor, values: Values) ?Buffer.Selection {
    return get_replacement_selection(editor, values.insert, values.replace);
}

fn get_replacement_selection(editor: *ed.Editor, insert_: ?Buffer.Selection, replace_: ?Buffer.Selection) Buffer.Selection {
    const pos = switch (tui.config().completion_insert_mode) {
        .replace => replace_ orelse insert_ orelse return ed.Selection.from_cursor(&editor.get_primary().cursor),
        .insert => insert_ orelse replace_ orelse return ed.Selection.from_cursor(&editor.get_primary().cursor),
    };
    var sel = pos.from_pos(editor.buf_root() catch return ed.Selection.from_cursor(&editor.get_primary().cursor), editor.metrics);
    sel.normalize();
    const cursor = editor.get_primary().cursor;
    return switch (tui.config().completion_insert_mode) {
        .insert => .{ .begin = sel.begin, .end = cursor },
        .replace => if (!cursor.within(sel)) .{ .begin = sel.begin, .end = cursor } else sel,
    };
}

fn get_insert_selection(editor: *ed.Editor, values: Values) Buffer.Selection {
    return get_replacement_selection(editor, values.insert, values.replace);
}

pub fn complete(self: *Type, _: ?*Type.ButtonType) !void {
    self.menu.activate_selected();
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const self = menu.*.opts.ctx;
    const values = get_values(button.opts.label);
    const sel = get_insert_selection(self.value.editor, values);
    const text = if (values.insertText.len > 0)
        values.insertText
    else if (values.textEdit_newText.len > 0)
        values.textEdit_newText
    else
        values.label;
    self.value.editor.insert_completion(sel, text, values.insertTextFormat) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    const mv = tui.mainview() orelse return;
    mv.cancel_info_content() catch {};
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| self.logger.err(module_name, e);
}

pub fn updated(self: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(self);
    const values = get_values(button.opts.label);
    const mv = tui.mainview() orelse return;
    try mv.set_info_content(values.label, .replace);
    try mv.set_info_content(" ", .append); // blank line
    try mv.set_info_content(values.detail, .append);
    if (builtin.mode == .Debug) {
        try mv.set_info_content("newText:", .append); // blank line
        try mv.set_info_content(values.textEdit_newText, .append);
        try mv.set_info_content("insertText:", .append); // blank line
        try mv.set_info_content(values.insertText, .append);
    }
    try mv.set_info_content(" ", .append); // blank line
    try mv.set_info_content(values.documentation, .append);
    if (mv.get_active_editor()) |editor|
        self.value.view = editor.view;
}

pub fn cancel(_: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    editor.cancel_all_matches();
    const mv = tui.mainview() orelse return;
    mv.cancel_info_content() catch {};
}

const cmds = struct {
    pub const Target = Type;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn update_completion(self: *Type, _: Ctx) Result {
        clear_entries(self);
        self.longest_hint = try load_entries(self);
        try update_query_text(self, self.value.editor.get_primary().cursor);
    }
    pub const update_completion_meta: Meta = .{};
};
