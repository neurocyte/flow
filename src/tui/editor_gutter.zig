const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");
const diff = @import("diff");
const cbor = @import("cbor");
const root = @import("root");

const Plane = @import("renderer").Plane;
const style = @import("renderer").style;
const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");

const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");
const tui = @import("tui.zig");
const ed = @import("editor.zig");
const DigitStyle = @import("config").DigitStyle;
const LineNumberMode = @import("config").LineNumberMode;

allocator: Allocator,
plane: Plane,
parent: Widget,

lines: u32 = 0,
view_rows: u32 = 1,
view_top: u32 = 1,
line: usize = 0,
mode: ?LineNumberMode = null,
render_style: DigitStyle,
highlight: bool,
symbols: bool,
width: usize = 4,
editor: *ed.Editor,
diff: diff.AsyncDiffer,
diff_symbols: std.ArrayList(Symbol),

const Self = @This();

const Kind = enum { insert, modified, delete };
const Symbol = struct { kind: Kind, line: usize };

pub fn create(allocator: Allocator, parent: Widget, event_source: Widget, editor: *ed.Editor) !Widget {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent.plane.*),
        .parent = parent,
        .mode = tui.config().gutter_line_numbers_mode,
        .render_style = tui.config().gutter_line_numbers_style,
        .highlight = tui.config().highlight_current_line_gutter,
        .symbols = tui.config().gutter_symbols,
        .editor = editor,
        .diff = try diff.create(),
        .diff_symbols = std.ArrayList(Symbol).init(allocator),
    };
    try tui.message_filters().add(MessageFilter.bind(self, filter_receive));
    try event_source.subscribe(EventHandler.bind(self, handle_event));
    return self.widget();
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.diff_symbols_clear();
    self.diff_symbols.deinit();
    tui.message_filters().remove_ptr(self);
    self.plane.deinit();
    allocator.destroy(self);
}

fn diff_symbols_clear(self: *Self) void {
    self.diff_symbols.clearRetainingCapacity();
}

pub fn handle_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ "E", "update", tp.more }))
        return self.diff_update() catch |e| return tp.exit_error(e, @errorReturnTrace());
    if (try m.match(.{ "E", "view", tp.extract(&self.lines), tp.extract(&self.view_rows), tp.extract(&self.view_top) }))
        return self.update_width();
    if (try m.match(.{ "E", "pos", tp.extract(&self.lines), tp.extract(&self.line), tp.more }))
        return self.update_width();
    if (try m.match(.{ "E", "close" })) {
        self.lines = 0;
        self.line = 0;
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var y: i32 = undefined;
    var ypx: i32 = undefined;

    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.primary_click(y);
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON2), tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.middle_click();
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON3), tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.secondary_click();
    if (try m.match(.{ "D", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.primary_drag(y);
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON4), tp.more }))
        return self.mouse_click_button4();
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON5), tp.more }))
        return self.mouse_click_button5();

    return false;
}

fn update_width(self: *Self) void {
    if (self.mode == .none) return;
    const width = int_width(self.lines);
    self.width = if (self.mode == .relative and width > 4) 4 else @max(width, 2);
    self.width += if (self.symbols) 3 else 1;
}

pub fn layout(self: *Self) Widget.Layout {
    return .{ .static = self.get_width() };
}

inline fn get_width(self: *Self) usize {
    return if (self.mode != .none) self.width else if (self.symbols) 3 else 1;
}

fn get_numbering_mode(self: *const Self) LineNumberMode {
    return self.mode orelse switch (if (tui.input_mode()) |mode| mode.line_numbers else .absolute) {
        .relative => .relative,
        .inherit => if (tui.input_mode_outer()) |mode| from_mode_enum(mode.line_numbers) else .absolute,
        .absolute => .absolute,
    };
}

fn from_mode_enum(mode: anytype) LineNumberMode {
    return switch (mode) {
        .relative => .relative,
        .inherit => .absolute,
        .absolute => .absolute,
    };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = "gutter render" });
    defer frame.deinit();
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(theme.editor_gutter);
    _ = self.plane.fill(" ");
    switch (self.get_numbering_mode()) {
        .none => self.render_none(theme),
        .relative => self.render_relative(theme),
        .absolute => self.render_linear(theme),
    }
    if (self.symbols)
        self.render_diagnostics(theme);
    return false;
}

pub fn render_none(self: *Self, theme: *const Widget.Theme) void {
    var pos: usize = 0;
    var linenum = self.view_top + 1;
    var rows = self.view_rows;
    var diff_symbols = self.diff_symbols.items;
    while (rows > 0) : (rows -= 1) {
        if (linenum > self.lines) return;
        if (self.highlight and linenum == self.line + 1)
            self.render_line_highlight(pos, theme);
        self.render_diff_symbols(&diff_symbols, pos, linenum, theme);
        pos += 1;
        linenum += 1;
    }
}

pub fn render_linear(self: *Self, theme: *const Widget.Theme) void {
    var pos: usize = 0;
    var linenum = self.view_top + 1;
    var rows = self.view_rows;
    var diff_symbols = self.diff_symbols.items;
    while (rows > 0) : (rows -= 1) {
        if (linenum > self.lines) return;
        if (linenum == self.line + 1) {
            self.plane.set_style(.{ .fg = theme.editor_gutter_active.fg });
            self.plane.on_styles(style.bold);
        } else {
            self.plane.set_style(.{ .fg = theme.editor_gutter.fg });
            self.plane.off_styles(style.bold);
        }
        try self.plane.cursor_move_yx(@intCast(pos), 0);
        try self.print_digits(linenum, self.render_style);
        if (self.highlight and linenum == self.line + 1)
            self.render_line_highlight(pos, theme);
        self.render_diff_symbols(&diff_symbols, pos, linenum, theme);
        pos += 1;
        linenum += 1;
    }
}

pub fn render_relative(self: *Self, theme: *const Widget.Theme) void {
    const row: isize = @intCast(self.view_top + 1);
    const line: isize = @intCast(self.line + 1);
    var pos: usize = 0;
    var linenum: isize = row - line;
    var abs_linenum = self.view_top + 1;
    var rows = self.view_rows;
    var diff_symbols = self.diff_symbols.items;
    while (rows > 0) : (rows -= 1) {
        if (self.lines > @as(u32, @intCast(row)) and pos > self.lines - @as(u32, @intCast(row))) return;
        self.plane.set_style(if (linenum == 0) theme.editor_gutter_active else theme.editor_gutter);
        const val = @abs(if (linenum == 0) line else linenum);

        try self.plane.cursor_move_yx(@intCast(pos), 0);
        if (val > 999999)
            _ = self.plane.print_aligned_right(@intCast(pos), "==> ", .{}) catch {}
        else
            self.print_digits(val, self.render_style) catch {};

        if (self.highlight and linenum == 0)
            self.render_line_highlight(pos, theme);
        self.render_diff_symbols(&diff_symbols, pos, abs_linenum, theme);
        pos += 1;
        linenum += 1;
        abs_linenum += 1;
    }
}

inline fn render_line_highlight(self: *Self, pos: usize, theme: *const Widget.Theme) void {
    for (0..self.get_width()) |i| {
        self.plane.cursor_move_yx(@intCast(pos), @intCast(i)) catch return;
        var cell = self.plane.cell_init();
        _ = self.plane.at_cursor_cell(&cell) catch return;
        cell.set_style_bg(theme.editor_line_highlight);
        _ = self.plane.putc(&cell) catch {};
    }
}

inline fn render_diff_symbols(self: *Self, diff_symbols: *[]Symbol, pos: usize, linenum_: usize, theme: *const Widget.Theme) void {
    const linenum = linenum_ - 1;
    if (diff_symbols.len == 0) return;
    while ((diff_symbols.*)[0].line < linenum) {
        diff_symbols.* = (diff_symbols.*)[1..];
        if (diff_symbols.len == 0) return;
    }

    if ((diff_symbols.*)[0].line > linenum) return;

    const sym = (diff_symbols.*)[0];
    const char = switch (sym.kind) {
        .insert => "┃",
        .modified => "┋",
        .delete => "▔",
    };

    self.plane.cursor_move_yx(@intCast(pos), @intCast(self.get_width() - 1)) catch return;
    var cell = self.plane.cell_init();
    _ = self.plane.at_cursor_cell(&cell) catch return;
    cell.set_style_fg(switch (sym.kind) {
        .insert => theme.editor_gutter_added,
        .modified => theme.editor_gutter_modified,
        .delete => theme.editor_gutter_deleted,
    });
    _ = self.plane.cell_load(&cell, char) catch {};
    _ = self.plane.putc(&cell) catch {};
}

fn render_diagnostics(self: *Self, theme: *const Widget.Theme) void {
    for (self.editor.diagnostics.items) |*diag| self.render_diagnostic(diag, theme);
}

fn render_diagnostic(self: *Self, diag: *const ed.Diagnostic, theme: *const Widget.Theme) void {
    const row = diag.sel.begin.row;
    if (!(self.view_top < row and row < self.view_top + self.view_rows)) return;
    const style_ = switch (diag.get_severity()) {
        .Error => theme.editor_error,
        .Warning => theme.editor_warning,
        .Information => theme.editor_information,
        .Hint => theme.editor_hint,
    };
    const icon = switch (diag.get_severity()) {
        .Error => "",
        .Warning => "",
        .Information => "",
        .Hint => "",
    };
    const y = row - self.view_top;
    self.plane.cursor_move_yx(@intCast(y), 0) catch return;
    var cell = self.plane.cell_init();
    _ = self.plane.at_cursor_cell(&cell) catch return;
    cell.set_style_fg(style_);
    _ = self.plane.cell_load(&cell, icon) catch {};
    _ = self.plane.putc(&cell) catch {};
}

fn primary_click(self: *const Self, y_: i32) error{Exit}!bool {
    const y = self.editor.plane.abs_y_to_rel(y_);
    var line = self.view_top + 1;
    line += @intCast(y);
    if (line > self.lines) line = self.lines;
    try command.executeName("goto_line", command.fmt(.{line}));
    try command.executeName("goto_column", command.fmt(.{1}));
    try command.executeName("select_end", .{});
    try command.executeName("select_right", .{});
    return true;
}

fn primary_drag(self: *const Self, y_: i32) error{Exit}!bool {
    const y = self.editor.plane.abs_y_to_rel(y_);
    try command.executeName("drag_to", command.fmt(.{ y + 1, 0 }));
    return true;
}

fn secondary_click(_: *Self) error{Exit}!bool {
    try command.executeName("gutter_mode_next", .{});
    return true;
}

fn middle_click(_: *Self) error{Exit}!bool {
    try command.executeName("gutter_style_next", .{});
    return true;
}

fn mouse_click_button4(_: *Self) error{Exit}!bool {
    try command.executeName("scroll_up_pageup", .{});
    return true;
}

fn mouse_click_button5(_: *Self) error{Exit}!bool {
    try command.executeName("scroll_down_pagedown", .{});
    return true;
}

fn diff_update(self: *Self) !void {
    if (self.lines == 0 or self.lines > root.max_diff_lines) {
        self.diff_symbols_clear();
        return;
    }
    const editor = self.editor;
    const new = editor.get_current_root() orelse return;
    const old = if (editor.buffer) |buffer| buffer.last_save orelse return else return;
    const eol_mode = if (editor.buffer) |buffer| buffer.file_eol_mode else return;
    return self.diff.diff(diff_result, new, old, eol_mode);
}

fn diff_result(from: tp.pid_ref, edits: []diff.Diff) void {
    diff_result_send(from, edits) catch |e| @import("log").err(@typeName(Self), "diff", e);
}

fn diff_result_send(from: tp.pid_ref, edits: []diff.Diff) !void {
    var buf: [tp.max_message_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    try cbor.writeArrayHeader(writer, 2);
    try cbor.writeValue(writer, "DIFF");
    try cbor.writeArrayHeader(writer, edits.len);
    for (edits) |edit| {
        try cbor.writeArrayHeader(writer, 4);
        try cbor.writeValue(writer, switch (edit.kind) {
            .insert => "I",
            .delete => "D",
        });
        try cbor.writeValue(writer, edit.line);
        try cbor.writeValue(writer, edit.offset);
        try cbor.writeValue(writer, edit.bytes);
    }
    from.send_raw(tp.message{ .buf = stream.getWritten() }) catch return;
}

pub fn process_diff(self: *Self, cb: []const u8) MessageFilter.Error!void {
    var iter = cb;
    self.diff_symbols_clear();
    var count = try cbor.decodeArrayHeader(&iter);
    while (count > 0) : (count -= 1) {
        var line: usize = undefined;
        var offset: usize = undefined;
        var bytes: []const u8 = undefined;
        if (try cbor.matchValue(&iter, .{ "I", cbor.extract(&line), cbor.extract(&offset), cbor.extract(&bytes) })) {
            var pos: usize = 0;
            var ln: usize = line;
            while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |next| {
                const end = if (next < bytes.len) next + 1 else next;
                try self.process_edit(.insert, ln, offset, bytes[pos..end]);
                pos = next + 1;
                ln += 1;
                offset = 0;
            }
            try self.process_edit(.insert, ln, offset, bytes[pos..]);
            continue;
        }
        if (try cbor.matchValue(&iter, .{ "D", cbor.extract(&line), cbor.extract(&offset), cbor.extract(&bytes) })) {
            try self.process_edit(.delete, line, offset, bytes);
            continue;
        }
    }
}

fn process_edit(self: *Self, kind: Kind, line: usize, offset: usize, bytes: []const u8) !void {
    const change = if (self.diff_symbols.items.len > 0) self.diff_symbols.items[self.diff_symbols.items.len - 1].line == line else false;
    if (change) {
        self.diff_symbols.items[self.diff_symbols.items.len - 1].kind = .modified;
        return;
    }
    (try self.diff_symbols.addOne()).* = switch (kind) {
        .insert => ret: {
            if (offset > 0)
                break :ret .{ .kind = .modified, .line = line };
            if (bytes.len == 0)
                return;
            if (bytes[bytes.len - 1] == '\n')
                break :ret .{ .kind = .insert, .line = line };
            break :ret .{ .kind = .modified, .line = line };
        },
        .delete => .{ .kind = .delete, .line = line },
        else => unreachable,
    };
}

pub fn filter_receive(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var cb: []const u8 = undefined;
    if (cbor.match(m.buf, .{ "DIFF", tp.extract_cbor(&cb) }) catch false) {
        try self.process_diff(cb);
        return true;
    }
    return false;
}

fn int_width(n_: usize) usize {
    var n = n_;
    var size: usize = 1;
    while (true) {
        n /= 10;
        if (n == 0) return size;
        size += 1;
    }
}

fn print_digits(self: *Self, n_: anytype, style_: DigitStyle) !void {
    var n = n_;
    var buf: [12][]const u8 = undefined;
    var digits = std.ArrayListUnmanaged([]const u8).initBuffer(&buf);
    while (true) {
        digits.addOneAssumeCapacity().* = get_digit(n % 10, style_);
        n /= 10;
        if (n == 0) break;
    }
    std.mem.reverse([]const u8, digits.items);
    try self.plane.cursor_move_yx(@intCast(self.plane.cursor_y()), @intCast(self.width - digits.items.len - 1));
    for (digits.items) |digit| _ = try self.plane.putstr(digit);
}

pub fn print_digit(plane: *Plane, n: anytype, style_: DigitStyle) !void {
    _ = try plane.putstr(get_digit(n, style_));
}

const get_digit = @import("fonts.zig").get_digit;
