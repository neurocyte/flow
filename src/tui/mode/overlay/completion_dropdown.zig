const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;
const command = @import("command");
const Buffer = @import("Buffer");
const Selection = Buffer.Selection;
const CompletionItemKind = @import("lsp_types").CompletionItemKind;

const tui = @import("../../tui.zig");
pub const Type = @import("dropdown.zig").Create(@This());
const ed = @import("../../editor.zig");
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");
const info_view = @import("../../info_view.zig");
const Panel = @import("../../Panel.zig");
const richdoc = @import("richdoc");

pub const label = "Select completion";
pub const name = "completion";
pub const description = "completions";
pub const icon = "󱎸  ";
pub const modal_dim = false;
pub const placement = .primary_cursor;
pub const widget_type: Widget.Type = .dropdown;
pub var detail_limit: usize = 40;
pub var description_limit: usize = 25;

const info_box_widget_type: Widget.Type = .info_box;

pub const Entry = struct {
    label: []const u8,
    sort_text: []const u8,
    cbor: []const u8,
};

pub const ValueType = struct {
    editor: *ed.Editor = undefined,
    cursor: ed.Cursor = .{},
    view: ed.View = .{},
    query: ?Selection = null,
    last_query: ?[]const u8 = null,
    commands: command.Collection(cmds) = undefined,
    data: []const u8 = &.{},
    info_box_layer: ?*tui.WidgetLayerBox = null,
};
pub const defaultValue: ValueType = .{};

var max_description: usize = 0;

pub fn init(self: *Type) error{ Stop, OutOfMemory }!void {
    try self.value.commands.init(self);
    self.value.editor = tui.get_active_editor() orelse return error.Stop;
    self.value.view = self.value.editor.view;
    self.value.editor.cursor_focus_override = true;
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
            const sort_text_equal = std.mem.eql(u8, lhs.sort_text, rhs.sort_text);
            const lhs_str = if (!sort_text_equal and lhs.sort_text.len > 0) lhs.sort_text else lhs.label;
            const rhs_str = if (!sort_text_equal and rhs.sort_text.len > 0) rhs.sort_text else rhs.label;
            return std.mem.order(u8, lhs_str, rhs_str) == .lt;
        }
    }.less_fn;
    std.mem.sort(Entry, self.entries.items, {}, less_fn);

    max_description = @min(max_description, tui.screen().w -| max_label_len -| 10);
    return @max(max_description, if (max_label_len > label.len + 3) 0 else label.len + 3 - max_label_len);
}

pub fn deinit(self: *Type) void {
    self.value.editor.cursor_focus_override = false;
    self.allocator.free(self.value.data);
    if (self.value.last_query) |p| self.allocator.free(p);
    if (self.value.info_box_layer) |layer| layer.deinit(self.allocator);
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
        const sel: Selection = .{ .begin = query.begin, .end = cursor };
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
        self.value.view.row != self.value.editor.view.row or
        self.value.view.col != self.value.editor.view.col)
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

pub fn add_list_box_entry(self: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(self.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try writer.writeAll(entry.cbor);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try self.list_box.add_item_with_handler(value.written(), select);
    self.items += 1;
}

pub fn on_render_list_box(self: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    var item_cbor: []const u8 = undefined;
    var matches_cbor: []const u8 = undefined;

    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&item_cbor)) catch false)) return false;
    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&matches_cbor)) catch false)) return false;

    const values = get_values(item_cbor);
    const icon_: []const u8 = values.kind.icon();
    const color: u24 = 0x0;

    if (self.value.editor.get_primary_scr()) |cursor|
        self.value.editor.plane.cursor_enable(@intCast(cursor.row), @intCast(cursor.col), tui.get_cursor_shape());

    const lead_cols: usize = if (tui.config().show_fileicons) 5 else 2;
    const hint_cols = @as(usize, button.plane.dim_x()) -| (lead_cols + values.label.len);
    const detail = clip_hint(values.label_detail, detail_limit, hint_cols);
    var description_lines = std.mem.splitScalar(u8, values.label_description, '\n');
    const desc = clip_hint(description_lines.first(), description_limit, hint_cols -| detail.cols() -| 2);

    const more = tui.render_symbol(
        &button.plane,
        0,
        values.label,
        icon_,
        color,
        detail.text,
        desc.text,
        matches_cbor,
        button.active,
        selected,
        button.hover,
        theme,
        detail.suffix,
        desc.suffix,
        &.{},
    );
    if (!selected) return more;
    const layer = self.value.info_box_layer orelse return more;
    layer.widget().update();
    return layer.widget().render(theme) or more;
}

const Hint = struct {
    text: []const u8,
    suffix: []const u8,

    fn cols(self: Hint) usize {
        return self.text.len + @as(usize, if (self.suffix.len > 0) 1 else 0);
    }
};

fn clip_hint(text: []const u8, limit: usize, room: usize) Hint {
    if (text.len <= limit and text.len <= room) return .{ .text = text, .suffix = "" };
    if (room == 0) return .{ .text = "", .suffix = "" };
    return .{ .text = text[0..@min(limit, room - 1)], .suffix = "…" };
}

pub fn reserve_right(_: *Type, x: usize) usize {
    if (tui.config().completion_info_mode != .box) return 0;
    return if (x >= info_view.box_min_width) 0 else info_view.box_min_width;
}

pub fn walk(self: *Type, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    const layer = self.value.info_box_layer orelse return false;
    return layer.widget().walk(walk_ctx, f);
}

pub fn after_resize(self: *Type) void {
    if (self.value.info_box_layer) |layer| {
        layer.deinit(self.allocator);
        self.value.info_box_layer = null;
    }
}

pub const Values = struct {
    label: []const u8,
    sort_text: []const u8,
    kind: CompletionItemKind,
    insert: ?Selection,
    replace: ?Selection,
    additionalTextEdits: cbor.Raw,
    item: cbor.Raw,
    label_detail: []const u8,
    label_description: []const u8,
    detail: []const u8,
    documentation: []const u8,
    documentation_kind: info_view.Kind,
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
    var documentation_kind: []const u8 = "";
    var sort_text: []const u8 = "";
    var kind: u8 = 0;
    var insertText: []const u8 = "";
    var insertTextFormat: usize = 0;
    var textEdit_newText: []const u8 = "";
    var insert_cbor: []const u8 = &.{};
    var replace_cbor: []const u8 = &.{};
    var additionalTextEdits: []const u8 = &.{};
    var item: []const u8 = &.{};
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
        cbor.extract(&documentation_kind), // documentation_kind
        cbor.extract(&sort_text), // sortText
        cbor.extract(&insertText), // insertText
        cbor.extract(&insertTextFormat), // insertTextFormat
        cbor.extract(&textEdit_newText), // textEdit_newText
        cbor.extract_cbor(&insert_cbor),
        cbor.extract_cbor(&replace_cbor),
        cbor.extract_cbor(&additionalTextEdits),
        cbor.extract_cbor(&item),
    }) catch false;
    return .{
        .label = label_,
        .sort_text = sort_text,
        .kind = @fromBackingInt(@intCast(kind)),
        .insert = get_range(insert_cbor),
        .replace = get_range(replace_cbor),
        .additionalTextEdits = .{ .bytes = additionalTextEdits },
        .item = .{ .bytes = item },
        .label_detail = label_detail,
        .label_description = label_description,
        .detail = detail,
        .documentation = documentation,
        .documentation_kind = .from_lsp(documentation_kind),
        .insertTextFormat = insertTextFormat,
        .insertText = insertText,
        .textEdit_newText = textEdit_newText,
    };
}

fn get_range(range_cbor: []const u8) ?Selection {
    var range: Selection = .{};
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

pub fn get_query_selection(editor: *ed.Editor, values: Values) ?Selection {
    return get_replacement_selection(editor, values.insert, values.replace, null);
}

fn get_replacement_selection(editor: *ed.Editor, insert_: ?Selection, replace_: ?Selection, query: ?Selection) Selection {
    const pos = switch (tui.config().completion_insert_mode) {
        .replace => replace_ orelse insert_,
        .insert => insert_ orelse replace_,
    };

    var sel = if (pos) |p|
        p.from_pos(editor.buf_root() catch return ed.Selection.from_cursor(&editor.get_primary().cursor), editor.metrics)
    else
        query orelse editor.guest_completion_range();
    sel.normalize();
    const cursor = editor.get_primary().cursor;
    return switch (tui.config().completion_insert_mode) {
        .insert => .{ .begin = sel.begin, .end = cursor },
        .replace => if (!cursor.within(sel)) .{ .begin = sel.begin, .end = cursor } else sel,
    };
}

fn get_insert_selection(editor: *ed.Editor, values: Values, query: ?Selection) Selection {
    return get_replacement_selection(editor, values.insert, values.replace, query);
}

pub fn complete(self: *Type, _: ?*Type.ButtonType) !void {
    self.list_box.activate_selected();
}

fn select(list_box: **Type.ListBoxType, button: *Type.ButtonType, _: Type.Pos) void {
    const self = list_box.*.opts.ctx;
    const values = get_values(button.opts.label);
    const sel = get_insert_selection(self.value.editor, values, self.value.query);
    const text = if (values.insertText.len > 0)
        values.insertText
    else if (values.textEdit_newText.len > 0)
        values.textEdit_newText
    else
        values.label;
    const ctx: command.Context = .empty();
    self.value.editor.insert_completion(sel, text, values.insertTextFormat, values.additionalTextEdits, values.item, ctx.now) catch |e| list_box.*.opts.ctx.logger.err(module_name, e);
    const mv = tui.mainview() orelse return;
    mv.cancel_info_content() catch {};
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| self.logger.err(module_name, e);
}

pub fn updated(self: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(self, .empty());
    const mv = tui.mainview() orelse return;
    const values = get_values(button.opts.label);
    self.value.editor.resolve_completion(values.item, values.additionalTextEdits);
    switch (tui.config().completion_info_mode) {
        .none => {},
        .box => try show_info_box(self, button, values),
        .panel => try show_info_panel(self.allocator, mv, values),
    }
    if (mv.get_active_editor()) |editor|
        self.value.view = editor.view;
}

pub fn show_info_panel(allocator: std.mem.Allocator, mv: anytype, values: Values) !void {
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try write_info_markdown(&content.writer, values);
    try mv.set_info_content(.markdown, content.written(), .replace);
    if (has_plaintext_documentation(values)) {
        try mv.set_info_content(.plaintext, " ", .append); // blank line
        try mv.set_info_content(.plaintext, values.documentation, .append);
    }
}

fn has_plaintext_documentation(values: Values) bool {
    return values.documentation_kind == .plaintext and values.documentation.len > 0;
}

fn write_info_markdown(writer: *std.Io.Writer, values: Values) std.Io.Writer.Error!void {
    try richdoc.markdown.write_code_block(writer, null, &.{ values.label, values.detail });
    if (values.documentation_kind == .markdown and values.documentation.len > 0) {
        try writer.writeByte('\n');
        try writer.writeAll(values.documentation);
    }
}

fn show_info_box(self: *Type, button: *Type.ButtonType, values: Values) !void {
    const layer = self.value.info_box_layer orelse blk: {
        const new_layer = try tui.WidgetLayerBox.create(self.allocator, tui.plane(), .{ .name = "completion_info.layer" });
        new_layer.blend = .src_over_blur;
        new_layer.alpha = tui.palette_opacity();
        new_layer.radius = 8;
        errdefer new_layer.deinit(self.allocator);
        const inner = try info_view.create_widget_type(self.allocator, new_layer.inner_plane(), info_box_widget_type);
        new_layer.set(inner);
        self.value.info_box_layer = new_layer;
        break :blk new_layer;
    };
    const w = layer.widget();
    const info_ = if (w.get(@typeName(info_view))) |w_| w_.dynamic_cast(info_view) orelse null else null;
    const info = info_ orelse @panic("show_info_box");

    var content: std.Io.Writer.Allocating = .init(self.allocator);
    defer content.deinit();
    try write_info_markdown(&content.writer, values);
    try info.set_content(.markdown, content.written());
    if (has_plaintext_documentation(values)) {
        try info.append_content(.plaintext, " "); // blank line
        try info.append_content(.plaintext, values.documentation);
    }

    const screen_h = tui.screen().h;
    const list = self.list_box_layer.box;
    const gy, _ = button.plane.global_yx();
    const y: usize = @intCast(@max(0, gy));
    const list_bottom = list.y + list.h;
    const side = try info.place_box(layer, .{
        .before = list.x,
        .after = list.x + list.w,
        .side_rows = .{ .start = y, .below = screen_h -| y },
        .fallback_x = list.x,
        .fallback_rows = .{ .start = list_bottom, .below = screen_h -| list_bottom },
    });
    layer.corners, layer.shadow = switch (side) {
        .right => .{ .right, .{ .edges = .{ .left = false } } },
        .left => .{ .left, .{ .edges = .{ .right = false } } },
        .fallback => .{ .all, .{} },
    };
}

fn scroll_info(self: *Type, action: Panel.ScrollAction) void {
    const info = switch (tui.config().completion_info_mode) {
        .none => null,
        .box => info_view.from_layer(self.value.info_box_layer orelse return),
        .panel => (tui.mainview() orelse return).bottom_area.find_first(info_view),
    } orelse return;
    info.panel_scroll(action);
}

pub fn cancel(_: *Type, _: command.Context) !void {
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
        if (tui.config().completion_trigger == .automatic and self.value.editor.get_last_trigger_char() == null)
            return tp.self_pid().send(.{ "cmd", "palette_menu_cancel" }) catch |e| self.logger.err(module_name, e);

        clear_entries(self);
        self.longest_hint = try load_entries(self);
        try update_query_text(self, self.value.editor.get_primary().cursor);
    }
    pub const update_completion_meta: Meta = .{};

    pub fn completion_info_to_panel(self: *Type, _: Ctx) Result {
        const layer = self.value.info_box_layer orelse return;
        const info = info_view.from_layer(layer) orelse return;
        const button = self.list_box.get_selected() orelse return;
        const mv = tui.mainview() orelse return;
        try mv.open_info_copy(info, get_values(button.opts.label).label);
    }
    pub const completion_info_to_panel_meta: Meta = .{ .description = "Open the completion info box in a panel" };

    pub fn completion_info_scroll_down(self: *Type, _: Ctx) Result {
        scroll_info(self, .half_page_down);
    }
    pub const completion_info_scroll_down_meta: Meta = .{ .description = "Scroll the completion info down half a page" };

    pub fn completion_info_scroll_up(self: *Type, _: Ctx) Result {
        scroll_info(self, .half_page_up);
    }
    pub const completion_info_scroll_up_meta: Meta = .{ .description = "Scroll the completion info up half a page" };
};
