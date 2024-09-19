const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");
const diff = @import("diff");
const cbor = @import("cbor");
const root = @import("root");

const Plane = @import("renderer").Plane;
const style = @import("renderer").style;
const key = @import("renderer").input.key;
const event_type = @import("renderer").input.event_type;

const Widget = @import("Widget.zig");
const EventHandler = @import("EventHandler.zig");
const MessageFilter = @import("MessageFilter.zig");
const tui = @import("tui.zig");
const command = @import("command.zig");
const ed = @import("editor.zig");

allocator: Allocator,
plane: Plane,
parent: Widget,

lines: u32 = 0,
rows: u32 = 1,
row: u32 = 1,
line: usize = 0,
linenum: bool,
relative: bool,
highlight: bool,
width: usize = 4,
editor: *ed.Editor,
diff: diff,
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
        .linenum = tui.current().config.gutter_line_numbers,
        .relative = tui.current().config.gutter_line_numbers_relative,
        .highlight = tui.current().config.highlight_current_line_gutter,
        .editor = editor,
        .diff = try diff.create(),
        .diff_symbols = std.ArrayList(Symbol).init(allocator),
    };
    try tui.current().message_filters.add(MessageFilter.bind(self, filter_receive));
    try event_source.subscribe(EventHandler.bind(self, handle_event));
    return self.widget();
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.diff_symbols_clear();
    self.diff_symbols.deinit();
    tui.current().message_filters.remove_ptr(self);
    self.plane.deinit();
    allocator.destroy(self);
}

fn diff_symbols_clear(self: *Self) void {
    self.diff_symbols.clearRetainingCapacity();
}

pub fn handle_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ "E", "update", tp.more }))
        return self.diff_update() catch |e| return tp.exit_error(e, @errorReturnTrace());
    if (try m.match(.{ "E", "view", tp.extract(&self.lines), tp.extract(&self.rows), tp.extract(&self.row) }))
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

    if (try m.match(.{ "B", event_type.PRESS, key.BUTTON1, tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.primary_click(y);
    if (try m.match(.{ "B", event_type.PRESS, key.BUTTON3, tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.secondary_click();
    if (try m.match(.{ "D", event_type.PRESS, key.BUTTON1, tp.any, tp.any, tp.extract(&y), tp.any, tp.extract(&ypx) }))
        return self.primary_drag(y);
    if (try m.match(.{ "B", event_type.PRESS, key.BUTTON4, tp.more }))
        return self.mouse_click_button4();
    if (try m.match(.{ "B", event_type.PRESS, key.BUTTON5, tp.more }))
        return self.mouse_click_button5();

    return false;
}

fn update_width(self: *Self) void {
    if (!self.linenum) return;
    var buf: [31]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "  {d} ", .{self.lines}) catch return;
    self.width = if (self.relative and tmp.len > 7) 7 else @max(tmp.len, 5);
}

pub fn layout(self: *Self) Widget.Layout {
    return .{ .static = self.get_width() };
}

inline fn get_width(self: *Self) usize {
    return if (self.linenum) self.width else 3;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = "gutter render" });
    defer frame.deinit();
    self.plane.set_base_style(" ", theme.editor_gutter);
    self.plane.erase();
    if (self.linenum) {
        const relative = self.relative or if (tui.current().input_mode) |mode| mode.line_numbers == .relative else false;
        if (relative)
            self.render_relative(theme)
        else
            self.render_linear(theme);
    } else {
        self.render_none(theme);
    }
    self.render_diagnostics(theme);
    return false;
}

pub fn render_none(self: *Self, theme: *const Widget.Theme) void {
    var pos: usize = 0;
    var linenum = self.row + 1;
    var rows = self.rows;
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
    var linenum = self.row + 1;
    var rows = self.rows;
    var diff_symbols = self.diff_symbols.items;
    var buf: [31:0]u8 = undefined;
    while (rows > 0) : (rows -= 1) {
        if (linenum > self.lines) return;
        if (linenum == self.line + 1) {
            self.plane.set_base_style(" ", theme.editor_gutter_active);
            self.plane.on_styles(style.bold);
        } else {
            self.plane.set_base_style(" ", theme.editor_gutter);
            self.plane.off_styles(style.bold);
        }
        _ = self.plane.print_aligned_right(@intCast(pos), "{s}", .{std.fmt.bufPrintZ(&buf, "{d} ", .{linenum}) catch return}) catch {};
        if (self.highlight and linenum == self.line + 1)
            self.render_line_highlight(pos, theme);
        self.render_diff_symbols(&diff_symbols, pos, linenum, theme);
        pos += 1;
        linenum += 1;
    }
}

pub fn render_relative(self: *Self, theme: *const Widget.Theme) void {
    const row: isize = @intCast(self.row + 1);
    const line: isize = @intCast(self.line + 1);
    var pos: usize = 0;
    var linenum: isize = row - line;
    var abs_linenum = self.row + 1;
    var rows = self.rows;
    var diff_symbols = self.diff_symbols.items;
    var buf: [31:0]u8 = undefined;
    while (rows > 0) : (rows -= 1) {
        if (pos > self.lines - @as(u32, @intCast(row))) return;
        self.plane.set_base_style(" ", if (linenum == 0) theme.editor_gutter_active else theme.editor_gutter);
        const val = @abs(if (linenum == 0) line else linenum);
        const fmt = std.fmt.bufPrintZ(&buf, "{d} ", .{val}) catch return;
        _ = self.plane.print_aligned_right(@intCast(pos), "{s}", .{if (fmt.len > 6) "==> " else fmt}) catch {};
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
    if (!(self.row < row and row < self.row + self.rows)) return;
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
    const y = row - self.row;
    self.plane.cursor_move_yx(@intCast(y), 0) catch return;
    var cell = self.plane.cell_init();
    _ = self.plane.at_cursor_cell(&cell) catch return;
    cell.set_style_fg(style_);
    _ = self.plane.cell_load(&cell, icon) catch {};
    _ = self.plane.putc(&cell) catch {};
}

fn primary_click(self: *const Self, y: i32) error{Exit}!bool {
    var line = self.row + 1;
    line += @intCast(y);
    if (line > self.lines) line = self.lines;
    try command.executeName("goto_line", command.fmt(.{line}));
    try command.executeName("goto_column", command.fmt(.{1}));
    try command.executeName("select_end", .{});
    try command.executeName("select_right", .{});
    return true;
}

fn primary_drag(_: *const Self, y: i32) error{Exit}!bool {
    try command.executeName("drag_to", command.fmt(.{ y + 1, 0 }));
    return true;
}

fn secondary_click(_: *Self) error{Exit}!bool {
    try command.executeName("gutter_mode_next", .{});
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
    return self.diff.diff(diff_result, new, old);
}

fn diff_result(from: tp.pid_ref, edits: []diff.Edit) void {
    diff_result_send(from, edits) catch |e| @import("log").err(@typeName(Self), "diff", e);
}

fn diff_result_send(from: tp.pid_ref, edits: []diff.Edit) !void {
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
