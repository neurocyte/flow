const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const command = @import("command");
const text_manip = @import("text_manip");
const Buffer = @import("Buffer");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const ed = @import("../../editor.zig");
const module_name = @typeName(@This());

pub const label = "Search lines";
pub const name = "󰍉 lines";
pub const description = "buffer lines";
pub const icon = "󰍉  ";
pub const modal_dim = false;

pub const Entry = struct {
    /// Byte range into `ValueType.shared.text` (u32 caps buffers at 4 GiB).
    offset: u32,
    len: u32,
    row: u32,
    /// The line has a non-ASCII char that lowercases differently.
    unicode_upper: bool,
};

/// Longest query remembered for narrowing. Longer queries take a full scan.
const max_remembered_query = 256;

pub const ValueType = struct {
    start: ed.CurSel = .{},
    view: ed.View = .{},
    shared: ?*Buffer.SharedText = null,
    query: text_manip.CompiledQuery = .{},
    prev_query: [max_remembered_query]u8 = undefined,
    prev_query_len: usize = 0,
    prev_query_valid: bool = false,
    narrow: bool = false,
    /// Popup width: cached longest line plus the line number prefix.
    max_width: usize = 0,
    tab_width: usize = 0,
};
pub const defaultValue: ValueType = .{};

pub fn load_entries(palette: *Type) !usize {
    const editor = tui.get_active_editor() orelse return error.NotFound;
    const buffer = editor.buffer orelse return error.NotFound;
    palette.value.start = editor.get_primary().*;
    palette.value.view = editor.view;
    palette.value.tab_width = editor.metrics.tab_width;

    // Snapshot the text so entries stay valid across edits.
    const shared = buffer.share_text(.lf);
    errdefer shared.release();
    const text = shared.text;
    if (text.len >= std.math.maxInt(u32)) return error.FileTooLarge;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var row: u32 = 0;
    var max_raw_width: usize = 0;
    // ASCII buffers need no per-line Unicode check.
    const check_unicode = text_manip.has_non_ascii(text);
    try palette.entries.ensureTotalCapacity(palette.allocator, buffer.root.lines());
    while (lines.next()) |line| : (row += 1) {
        (try palette.entries.addOne(palette.allocator)).* = .{
            .offset = @intCast(@intFromPtr(line.ptr) - @intFromPtr(text.ptr)),
            .len = @intCast(line.len),
            .row = row,
            .unicode_upper = check_unicode and text_manip.has_unicode_upper(line),
        };
        max_raw_width = @max(max_raw_width, line.len);
    }
    // Measure tabs and wide chars, falling back to the byte length.
    buffer.update_longest_line_length(editor.metrics) catch {};
    const line_number_width = number_prefix_width(@intCast(buffer.root.lines()));
    palette.value.max_width = @max(buffer.longest_line_len, max_raw_width) + line_number_width;
    palette.value.shared = shared;
    palette.initial_selected = palette.value.start.cursor.row + 1;
    palette.quick_activate_enabled = false;
    return 0;
}

pub fn deinit(palette: *Type) void {
    if (palette.value.shared) |shared| shared.release();
    palette.value.shared = null;
}

fn number_prefix_width(row: u32) usize {
    var digits: usize = 1;
    var n = row;
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(digits, 4) + 3; // "{d:>4} | "
}

fn line_at(palette: *const Type, entry: *const Entry) []const u8 {
    return palette.value.shared.?.text[entry.offset..][0..entry.len];
}

pub fn longest_width(palette: *Type) usize {
    return palette.value.max_width;
}

pub fn prepare_filter(palette: *Type, query: []const u8) void {
    const prev = palette.value.prev_query[0..palette.value.prev_query_len];
    palette.value.narrow = palette.value.prev_query_valid and text_manip.query_extends(prev, query);
    if (query.len <= max_remembered_query) {
        @memcpy(palette.value.prev_query[0..query.len], query);
        palette.value.prev_query_len = query.len;
        palette.value.prev_query_valid = true;
    } else {
        palette.value.prev_query_len = 0;
        palette.value.prev_query_valid = false;
    }
    palette.value.query = text_manip.compile_query(query);
}

/// The query only grew, so its matches are a subset of the current ones.
pub fn reuse_matches(palette: *Type) bool {
    // Refiltering matches is slower per line, so only when half or fewer match.
    return palette.value.narrow and palette.matches.items.len * 2 <= palette.entries.items.len;
}

pub fn filter_entry(palette: *Type, entry: *Entry) bool {
    const line = line_at(palette, entry);
    // ad also matches the shown line number and pipe, so retry with those.
    if (palette.value.query.matches(line, entry.unicode_upper)) return true;
    if (!palette.value.query.needs_prefix) return false;
    // u32 row numbers fit in 10 digits.
    var number_buf: [10]u8 = undefined;
    const number = if (palette.value.query.needs_number)
        std.fmt.bufPrint(&number_buf, "{d}", .{entry.row + 1}) catch unreachable
    else
        "";
    return palette.value.query.matches_with_number(number, line, entry.unicode_upper);
}

pub fn add_list_box_entry(palette: *Type, entry: *Entry, _: ?[]const usize) !void {
    var label_buf: std.Io.Writer.Allocating = .init(palette.allocator);
    defer label_buf.deinit();
    try label_buf.writer.print("{d:>4} | ", .{entry.row + 1});
    try text_manip.write_tabs_expanded(&label_buf.writer, line_at(palette, entry), palette.value.tab_width);

    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, label_buf.written());
    try cbor.writeValue(writer, "");
    try cbor.writeValue(writer, &[_]usize{});
    try cbor.writeValue(writer, @as(usize, entry.row));
    try palette.list_box.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

fn get_row(button: *Type.ButtonType) ?usize {
    var row: usize = 0;
    var iter = button.opts.label;
    // label, hint and match positions precede the row
    for (0..3) |_| if (!(cbor.matchValue(&iter, cbor.any) catch false)) return null;
    if (!(cbor.matchValue(&iter, cbor.extract(&row)) catch false)) return null;
    return row;
}

fn row_end_col(editor: *ed.Editor, row: usize) usize {
    const buffer = editor.buffer orelse return 0;
    return buffer.root.line_width(row, editor.metrics) catch 0;
}

fn select(list_box: **Type.ListBoxType, button: *Type.ButtonType, _: Type.Pos) void {
    const row = get_row(button) orelse return;
    const editor = tui.get_active_editor() orelse return;
    const end_col = row_end_col(editor, row);
    editor.clear_matches();
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| list_box.*.opts.ctx.logger.err(module_name, e);
    // goto first so the jump is recorded in the location history
    tp.self_pid().send(.{ "cmd", "goto_line_and_column", .{ row + 1, 1 } }) catch |e| list_box.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "select_range", .{ row, 0, row, end_col } }) catch |e| list_box.*.opts.ctx.logger.err(module_name, e);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    const button = button_ orelse return cancel(palette, .empty());
    const row = get_row(button) orelse return;
    const editor = tui.get_active_editor() orelse return;
    tp.self_pid().send(.{ "cmd", "focus_on_range", .{ row, 0, row, row_end_col(editor, row) } }) catch {};
}

pub fn cancel(palette: *Type, ctx: command.Context) !void {
    const editor = tui.get_active_editor() orelse return;
    editor.clear_matches();
    editor.get_primary().* = palette.value.start;
    editor.update_scroll_dest_abs(palette.value.view.row, ctx.now);
}
