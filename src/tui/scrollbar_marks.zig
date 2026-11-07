const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const Plane = @import("renderer").Plane;
const MouseEvent = @import("MouseEvent");
const EventHandler = @import("EventHandler");
const Buffer = @import("Buffer");
const Widget = @import("Widget.zig");
const editor_mod = @import("editor.zig");
const Editor = editor_mod.Editor;
const CurSel = editor_mod.CurSel;
const tui = @import("tui.zig");

allocator: Allocator,
plane: Plane,
editor: *const Editor,
event_sink: EventHandler,
cells: std.ArrayList(Cell) = .empty,
events: [kinds.len]std.ArrayList(isize) = @splat(.empty),
last: struct {
    root: ?Buffer.Root = null,
    lines: usize = 0,
    rows: usize = 0,
    match_token: usize = 0,
    match_type: @FieldType(Editor, "match_type") = .none,
    matches: usize = 0,
    cursels: std.ArrayList(?CurSel) = .empty,
} = .{},

const Kind = enum(u2) { none, match, secondary, primary };
const kinds = [_]Kind{ .match, .secondary, .primary };

const Cell = struct {
    dots: u8 = 0,
    kind: Kind = .none,
};

const braille_rows = [_]u8{ 0x09, 0x12, 0x24, 0xc0 }; // ⠉ ⠒ ⠤ ⣀

const Self = @This();

pub fn create(allocator: Allocator, parent: Plane, editor: *const Editor, event_sink: EventHandler) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .editor = editor,
        .event_sink = event_sink,
    };
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.cells.deinit(self.allocator);
    for (&self.events) |*events| events.deinit(self.allocator);
    self.last.cursels.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = if (tui.config().scrollbar_marks) 1 else 0 };
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var btn: MouseEvent.Button = .none;
    var coord: MouseEvent.Coord = undefined;
    var hover: bool = false;
    if (try m.match(.{ "scroll", tp.more })) {
        self.event_sink.send(from, m) catch {};
    } else if (try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.extract(&coord), tp.any })) {
        switch (btn) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => self.event_sink.send(from, m) catch {},
            .left => self.click_at(coord.to_cell(self.plane.mouse_geometry()).row),
            else => {},
        }
    } else if (try m.match(.{ "H", tp.extract(&hover) })) {
        tui.rdr().request_mouse_cursor(.default, hover);
    } else return false;
    return true;
}

fn click_at(self: *Self, y: i32) void {
    const height = self.plane.dim_y();
    if (y < 0 or height == 0) return;
    const lines = (self.editor.buf_root() catch return).lines();
    const row: usize = @intCast(@as(u128, @intCast(y)) * lines / height);
    _ = self.event_sink.msg(.{ "scroll_to", row -| self.editor.view.rows / 2 }) catch {};
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    if (self.plane.dim_x() == 0 or self.plane.dim_y() == 0) return false;
    self.update() catch return false;
    for (self.cells.items, 0..) |cell, row| {
        if (cell.dots == 0) continue;
        const style = switch (cell.kind) {
            .none, .match => theme.editor_match,
            .secondary => theme.editor_cursor_secondary,
            .primary => theme.editor_cursor,
        };
        self.plane.set_style(.{ .fg = style.bg orelse style.fg orelse theme.editor.fg, .bg = theme.editor.bg });
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@as(u21, 0x2800) + cell.dots, &buf) catch unreachable;
        self.plane.cursor_move_yx(@intCast(row), 0);
        _ = self.plane.putstr(buf[0..len]) catch {};
    }
    return false;
}

fn update(self: *Self) !void {
    const editor = self.editor;
    const root = try editor.buf_root();
    const lines = root.lines();
    const rows = self.plane.dim_y();
    if (root == self.last.root and lines == self.last.lines and rows == self.last.rows and
        editor.match_token == self.last.match_token and editor.match_type == self.last.match_type and
        editor.matches.items.len == self.last.matches and cursels_eql(self.last.cursels.items, editor.cursels.items))
        return;
    errdefer self.last.root = null;
    self.last.cursels.clearRetainingCapacity();
    try self.last.cursels.appendSlice(self.allocator, editor.cursels.items);
    self.last.root = root;
    self.last.lines = lines;
    self.last.rows = rows;
    self.last.match_token = editor.match_token;
    self.last.match_type = editor.match_type;
    self.last.matches = editor.matches.items.len;

    const positions = rows * braille_rows.len;
    try self.cells.resize(self.allocator, rows);
    @memset(self.cells.items, .{});
    for (&self.events) |*events| {
        try events.resize(self.allocator, positions + 1);
        @memset(events.items, 0);
    }

    const primary = editor.get_primary();
    switch (editor.match_type) {
        .find, .auto_find => {
            const current = if (primary.selection) |sel| editor.find_selection_match(normalized(sel)) else null;
            const current_match = current orelse editor.match_at_cursor(primary.cursor);
            for (editor.matches.items) |*maybe_match| if (maybe_match.*) |*match| {
                const kind: Kind = if (match == current_match) .primary else .match;
                self.add_range(kind, match.to_selection(), lines);
            };
        },
        else => {},
    }
    for (editor.cursels.items) |*maybe_cursel| if (maybe_cursel.*) |*cursel| {
        const kind: Kind = if (cursel == primary) .primary else .secondary;
        self.add_range(kind, .{ .begin = cursel.cursor, .end = cursel.cursor }, lines);
        if (cursel.selection) |sel| self.add_range(kind, normalized(sel), lines);
    };

    for (self.events, kinds) |events, kind| {
        var depth: isize = 0;
        for (events.items[0..positions], 0..) |event, pos| {
            depth += event;
            if (depth <= 0) continue;
            const cell = &self.cells.items[pos / braille_rows.len];
            cell.dots |= braille_rows[pos % braille_rows.len];
            cell.kind = @fromBackingInt(@intCast(@max(@backingInt(cell.kind), @backingInt(kind))));
        }
    }
}

fn add_range(self: *Self, kind: Kind, sel: Buffer.Selection, lines: usize) void {
    const events = self.events[@backingInt(kind) - 1].items;
    const begin = sel.begin.row;
    const end = @min(@max(begin + 1, sel.end.row + @intFromBool(sel.end.col > 0)), lines);
    if (begin >= end) return;
    const positions = events.len - 1;
    events[project(begin, positions, lines)] += 1;
    events[project(end - 1, positions, lines) + 1] -= 1;
}

fn project(row: usize, positions: usize, lines: usize) usize {
    return @intCast(@as(u128, row) * positions / lines);
}

fn normalized(sel_: Buffer.Selection) Buffer.Selection {
    var sel = sel_;
    sel.normalize();
    return sel;
}

fn cursels_eql(a: []const ?CurSel, b: []const ?CurSel) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_, b_| {
        const x = a_ orelse {
            if (b_ != null) return false;
            continue;
        };
        const y = b_ orelse return false;
        if (!x.cursor.eql(y.cursor)) return false;
        if ((x.selection == null) != (y.selection == null)) return false;
        if (x.selection) |sel| if (!sel.eql(y.selection.?)) return false;
    }
    return true;
}
