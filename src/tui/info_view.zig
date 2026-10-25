const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const command = @import("command");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const tp = @import("thespian");
const reflow = @import("Buffer").reflow;
const tui = @import("tui.zig");
const markdown = @import("markdown");

const Attrs = markdown.rich_line.Attrs;
const BlockReader = markdown.rich_text.BlockReader;

pub const name = @typeName(Self);

pub fn markdown_theme(theme: *const Widget.Theme) markdown.rich_text.Theme {
    return .{ .context = theme, .find = find_markdown_token };
}

fn find_markdown_token(context: *const anyopaque, scope: []const u8) ?markdown.rich_text.Token {
    const theme: *const Widget.Theme = @ptrCast(@alignCast(context));
    const token = tui.find_scope_style(theme, scope) orelse return null;
    return .{
        .fg = if (token.style.fg) |fg| fg.color else null,
        .fs = if (token.style.fs) |fs| std.meta.stringToEnum(markdown.rich_text.FontStyle, @tagName(fs)) else null,
    };
}

const Self = @This();

pub const Kind = enum {
    plaintext,
    markdown,

    /// an LSP `MarkupKind`
    pub fn from_lsp(kind: []const u8) Kind {
        return if (std.mem.eql(u8, kind, "markdown")) .markdown else .plaintext;
    }
};

const Section = struct {
    kind: Kind,
    text: []const u8,
    doc: markdown.document.Document = .{},
    rich_text: markdown.rich_text.RichText = .{},

    fn deinit(self: *Section, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.doc.raw.bytes);
        allocator.free(self.rich_text.raw.bytes);
    }
};

const Run = struct {
    text: []const u8,
    attrs: Attrs = .{},
};

const Line = struct {
    runs: []const Run,
    width: usize,
};

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
view_cols: usize = 0,
sections: std.ArrayList(Section) = .empty,
lines: std.ArrayList(Line) = .empty,
layout_arena: std.heap.ArenaAllocator,
layout_width: usize = 0,
theme_name: []const u8 = "",
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
top: usize = 0,

const default_widget_type: Widget.Type = .panel;

pub const panel_tag = "info";
pub const panel_singleton = true;

pub fn panel_title(_: *Self) []const u8 {
    return "Info";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "\u{ea74}";
}

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    const self = try init(allocator, parent, default_widget_type);
    errdefer self.deinit(allocator);
    self.panel_input = try PanelInput.init(allocator, "info");
    return Panel.to(self);
}

pub fn create_widget_type(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !Widget {
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    errdefer container.deinit(allocator);
    const self = try init(allocator, parent, widget_type);
    container.ctx = self;
    try container.add(Widget.to(self));
    return container.widget();
}

fn init(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .layout_arena = .init(allocator),
        .widget_type = widget_type,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.panel_input) |*panel_input| panel_input.deinit(Widget.to(self));
    self.clear();
    self.sections.deinit(self.allocator);
    self.lines.deinit(self.allocator);
    self.layout_arena.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn focus(self: *Self) void {
    if (self.panel_input) |*panel_input| panel_input.focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    if (self.panel_input) |*panel_input| panel_input.unfocus(Widget.to(self));
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    const panel_input = if (self.panel_input) |*panel_input| panel_input else return false;
    if (try PanelInput.receive_context_menu(self, m)) return true;
    return panel_input.receive(from, m);
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    const rows = @max(1, self.view_rows);
    const max_top = self.lines.items.len -| rows;
    self.top = @min(max_top, switch (action) {
        .line_up => self.top -| 1,
        .line_down => self.top + 1,
        .page_up => self.top -| rows,
        .page_down => self.top + rows,
        .top => 0,
        .bottom => max_top,
    });
    tui.need_render(@src());
}

pub fn panel_copy(self: *Self) void {
    var text: std.Io.Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    for (self.lines.items) |line| {
        for (line.runs) |run| text.writer.writeAll(run.text) catch return;
        text.writer.writeByte('\n') catch return;
    }
    PanelInput.copy_to_clipboard(text.written());
}

pub fn clear(self: *Self) void {
    for (self.sections.items) |*section| section.deinit(self.allocator);
    self.sections.clearRetainingCapacity();
    self.lines.clearRetainingCapacity();
    _ = self.layout_arena.reset(.retain_capacity);
    self.layout_width = 0;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.view_rows = pos.h;
    self.view_cols = pos.w;
    if (self.target_width() != self.layout_width) self.layout() catch {};
}

pub fn append_content(self: *Self, kind: Kind, content: []const u8) !void {
    const text = try self.allocator.dupe(u8, content);
    errdefer self.allocator.free(text);
    var section: Section = .{ .kind = kind, .text = text };
    if (kind == .markdown) {
        section.doc = try markdown.document.parse(self.allocator, text, tui.query_cache());
        errdefer self.allocator.free(section.doc.raw.bytes);
        section.rich_text = try self.build_rich_text(section.doc);
    }
    errdefer section.deinit(self.allocator);
    try self.sections.append(self.allocator, section);
    try self.layout();
}

pub fn set_content(self: *Self, kind: Kind, content: []const u8) !void {
    self.clear();
    self.top = 0;
    return self.append_content(kind, content);
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    var cols: usize = 0;
    for (self.lines.items) |line| cols = @max(cols, line.width);
    return .{ .rows = self.lines.items.len, .cols = cols };
}

fn build_rich_text(self: *Self, doc: markdown.document.Document) !markdown.rich_text.RichText {
    const theme = tui.theme();
    self.theme_name = theme.name;
    const default_lang = if (tui.get_active_editor()) |editor| if (editor.file_type) |ft| ft.parser orelse ft.name else null else null;
    return markdown.rich_text.build(self.allocator, doc, markdown_theme(theme), tui.query_cache(), .{
        .default_lang = default_lang,
        .injection_depth = @intCast(@min(tui.config().syntax_injection_depth, 255)),
    });
}

fn restyle(self: *Self) !void {
    for (self.sections.items) |*section| if (section.kind == .markdown) {
        const rich_text = try self.build_rich_text(section.doc);
        self.allocator.free(section.rich_text.raw.bytes);
        section.rich_text = rich_text;
    };
    try self.layout();
}

fn target_width(self: *const Self) usize {
    return if (self.widget_type == .info_box)
        tui.config().info_box_width_limit
    else if (self.view_cols > 0)
        self.view_cols
    else
        tui.screen().w;
}

fn layout(self: *Self) !void {
    self.lines.clearRetainingCapacity();
    _ = self.layout_arena.reset(.retain_capacity);
    const width = @max(1, self.target_width());
    self.layout_width = width;
    var builder: LayoutBuilder = .{
        .view = self,
        .arena = self.layout_arena.allocator(),
        .width = width,
        .tab_width = tui.config().tab_width,
    };
    for (self.sections.items) |section| switch (section.kind) {
        .plaintext => try builder.plaintext(section.text),
        .markdown => {
            var blocks = try markdown.rich_text.read_blocks(section.rich_text);
            while (try blocks.next()) |block| try builder.block(block);
        },
    };
    if (self.widget_type == .info_box) try builder.fit_fills();
}

const Prefix = struct {
    first: []const u8,
    rest: []const u8,
    attrs: Attrs,
    used: bool = false,
};

const LayoutBuilder = struct {
    view: *Self,
    arena: Allocator,
    width: usize,
    tab_width: usize,
    prefixes: std.ArrayList(Prefix) = .empty,
    fills: std.ArrayList(Fill) = .empty,

    const Fill = struct { line: usize, fill: []const u8, prefix_width: usize };

    /// fit fills to the widest line
    fn fit_fills(self: *LayoutBuilder) !void {
        if (self.fills.items.len == 0) return;
        var width: usize = 0;
        var fill_idx: usize = 0;
        for (self.view.lines.items, 0..) |line, i| {
            if (fill_idx < self.fills.items.len and self.fills.items[fill_idx].line == i) {
                fill_idx += 1;
                continue;
            }
            width = @max(width, line.width);
        }
        for (self.fills.items) |f| {
            const line = &self.view.lines.items[f.line];
            const fill_width = @max(1, self.text_width(f.fill, 0));
            const count = @max(1, (width -| f.prefix_width) / fill_width);
            var text: std.ArrayList(u8) = .empty;
            for (0..count) |_| try text.appendSlice(self.arena, f.fill);
            const last = line.runs.len - 1;
            const runs = try self.arena.dupe(Run, line.runs);
            runs[last].text = text.items;
            line.runs = runs;
            line.width = f.prefix_width + count * fill_width;
        }
    }

    fn plaintext(self: *LayoutBuilder, content: []const u8) !void {
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| if (line.len > 0) {
            const text = try reflow(self.arena, line, self.width, .screen, .spaces, self.view.plane.metrics(self.tab_width));
            var iter_ = std.mem.splitScalar(u8, text, '\n');
            while (iter_.next()) |line_| if (line_.len > 0) {
                const runs = try self.arena.alloc(Run, 1);
                runs[0] = .{ .text = line_ };
                try self.view.lines.append(self.view.allocator, .{ .runs = runs, .width = self.text_width(line_, 0) });
            };
        };
    }

    fn text_width(self: *const LayoutBuilder, text: []const u8, start_col: usize) usize {
        var col = start_col;
        var i: usize = 0;
        while (i < text.len) {
            var cols: usize = 0;
            i += self.view.plane.egc_length(text[i..], &cols, col, self.tab_width);
            col += cols;
        }
        return col - start_col;
    }

    fn prefix_runs(self: *LayoutBuilder, runs: *std.ArrayList(Run), consume: bool) !usize {
        var width: usize = 0;
        for (self.prefixes.items) |*p| {
            const text = if (p.used) p.rest else p.first;
            if (consume) p.used = true;
            if (text.len == 0) continue;
            try runs.append(self.arena, .{ .text = text, .attrs = p.attrs });
            width += self.text_width(text, width);
        }
        return width;
    }

    fn next_prefix_width(self: *const LayoutBuilder) usize {
        var width: usize = 0;
        for (self.prefixes.items) |p| width += self.text_width(if (p.used) p.rest else p.first, width);
        return width;
    }

    fn blank_line(self: *LayoutBuilder) !void {
        var runs: std.ArrayList(Run) = .empty;
        var width: usize = 0;
        for (self.prefixes.items) |p| if (p.used) {
            if (p.rest.len == 0) continue;
            try runs.append(self.arena, .{ .text = p.rest, .attrs = p.attrs });
            width += self.text_width(p.rest, width);
        };
        // no trailing spaces on a line without content
        while (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            const trimmed = std.mem.trimEnd(u8, last.text, " ");
            width -= self.text_width(last.text, 0) - self.text_width(trimmed, 0);
            if (trimmed.len > 0) {
                last.text = trimmed;
                break;
            }
            _ = runs.pop();
        }
        try self.view.lines.append(self.view.allocator, .{ .runs = runs.items, .width = width });
    }

    fn emit(self: *LayoutBuilder, text: []const u8, segs: []const Run, start: usize, end: usize) !void {
        var runs: std.ArrayList(Run) = .empty;
        var col = try self.prefix_runs(&runs, true);
        var pos: usize = 0;
        for (segs) |seg| {
            const seg_start = pos;
            pos += seg.text.len;
            const s = @max(start, seg_start);
            const e = @min(end, pos);
            if (s >= e) continue;
            const part = try self.expand_tabs(text[s..e], col);
            col += self.text_width(part, col);
            try runs.append(self.arena, .{ .text = part, .attrs = seg.attrs });
        }
        try self.view.lines.append(self.view.allocator, .{ .runs = runs.items, .width = col });
    }

    fn expand_tabs(self: *const LayoutBuilder, text: []const u8, start_col: usize) ![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
        var out: std.ArrayList(u8) = .empty;
        var col = start_col;
        for (text) |c| if (c == '\t') {
            const n = self.tab_width - (col % self.tab_width);
            try out.appendNTimes(self.arena, ' ', n);
            col += n;
        } else {
            try out.append(self.arena, c);
            col += 1;
        };
        return out.items;
    }

    fn segments(self: *const LayoutBuilder, b: BlockReader) ![]Run {
        var list: std.ArrayList(Run) = .empty;
        var pos: usize = 0;
        var spans = try b.span_iterator();
        while (try spans.next()) |span| {
            if (span.start > pos) try list.append(self.arena, .{ .text = b.text[pos..span.start] });
            const start = @max(pos, span.start);
            const end = @min(span.end, b.text.len);
            if (end > start) try list.append(self.arena, .{ .text = b.text[start..end], .attrs = span.attrs });
            pos = @max(pos, end);
        }
        if (pos < b.text.len) try list.append(self.arena, .{ .text = b.text[pos..] });
        return list.items;
    }

    fn block(self: *LayoutBuilder, b: BlockReader) error{ OutOfMemory, InvalidRichText, InvalidRichLine }!void {
        for (0..b.space_before()) |_| try self.blank_line();
        const first_prefix = b.first_prefix();
        const prefix = b.prefix();
        const has_prefix = first_prefix.len > 0 or prefix.len > 0;
        if (has_prefix) try self.prefixes.append(self.arena, .{
            .first = first_prefix,
            .rest = prefix,
            .attrs = .{ .style = b.prefix_style() },
        });
        const lines_before = self.view.lines.items.len;

        const fill = b.fill();
        if (b.is_table()) {
            try self.table(b);
        } else if (fill.len > 0) {
            const fill_width = @max(1, self.text_width(fill, 0));
            var line: std.ArrayList(u8) = .empty;
            for (0..self.avail() / fill_width) |_| try line.appendSlice(self.arena, fill);
            const seg: [1]Run = .{.{ .text = line.items, .attrs = .{ .style = b.prefix_style() } }};
            const prefix_width = self.next_prefix_width();
            try self.emit(line.items, &seg, 0, line.items.len);
            try self.fills.append(self.arena, .{ .line = self.view.lines.items.len - 1, .fill = fill, .prefix_width = prefix_width });
        } else if (b.text.len > 0) {
            try self.wrap(b);
        }

        if (!b.is_table()) {
            var children = b.iterate();
            while (try children.next()) |child| try self.block(child);
        }

        if (has_prefix) {
            if (self.view.lines.items.len == lines_before) try self.emit("", &.{}, 0, 0);
            _ = self.prefixes.pop();
        }
    }

    /// a line of text and the runs that style it
    const LineText = struct {
        text: std.ArrayList(u8) = .empty,
        segs: std.ArrayList(Run) = .empty,

        fn add(self: *LineText, arena: Allocator, text: []const u8, attrs: Attrs) !void {
            if (text.len == 0) return;
            try self.text.appendSlice(arena, text);
            try self.segs.append(arena, .{ .text = text, .attrs = attrs });
        }
    };

    const CellLine = struct { segs: []const Run, width: usize };
    const TableCell = struct { lines: []const CellLine, width: usize };
    const TableRow = struct { head: bool, height: usize, cells: []const TableCell };

    /// the lines of a cell, split at hard breaks
    fn cell_lines(self: *const LayoutBuilder, cell: BlockReader) !TableCell {
        var lines: std.ArrayList(CellLine) = .empty;
        var segs: std.ArrayList(Run) = .empty;
        var width: usize = 0;
        for (try self.segments(cell)) |seg| {
            var parts = std.mem.splitScalar(u8, seg.text, '\n');
            var first = true;
            while (parts.next()) |part| {
                if (!first) {
                    try lines.append(self.arena, .{ .segs = segs.items, .width = width });
                    segs = .empty;
                    width = 0;
                }
                first = false;
                if (part.len == 0) continue;
                try segs.append(self.arena, .{ .text = part, .attrs = seg.attrs });
                width += self.text_width(part, width);
            }
        }
        try lines.append(self.arena, .{ .segs = segs.items, .width = width });
        var max: usize = 0;
        for (lines.items) |line| max = @max(max, line.width);
        return .{ .lines = lines.items, .width = max };
    }

    /// columns sized to their widest cell, or one wrapped line per row line if that does not fit
    fn table(self: *LayoutBuilder, b: BlockReader) !void {
        var rows: std.ArrayList(TableRow) = .empty;
        var widths: std.ArrayList(usize) = .empty;
        var row_iter = b.iterate();
        while (try row_iter.next()) |row| {
            var cells: std.ArrayList(TableCell) = .empty;
            var height: usize = 1;
            var cell_iter = row.iterate();
            while (try cell_iter.next()) |cell| {
                const table_cell = try self.cell_lines(cell);
                if (cells.items.len >= widths.items.len) try widths.append(self.arena, 0);
                widths.items[cells.items.len] = @max(widths.items[cells.items.len], table_cell.width);
                height = @max(height, table_cell.lines.len);
                try cells.append(self.arena, table_cell);
            }
            try rows.append(self.arena, .{ .head = row.row() == .head, .height = height, .cells = cells.items });
        }
        const separator = " │ ";
        const border: Attrs = .{ .style = b.prefix_style() };
        var total: usize = 0;
        for (widths.items) |w| total += w;
        total += (widths.items.len -| 1) * self.text_width(separator, 0);
        const fits = total <= self.avail();

        for (rows.items) |row| {
            for (0..row.height) |k| {
                var line: LineText = .{};
                for (widths.items, 0..) |width, i| {
                    if (i > 0) try line.add(self.arena, separator, border);
                    const cell_line: CellLine = if (i < row.cells.len and k < row.cells[i].lines.len)
                        row.cells[i].lines[k]
                    else
                        .{ .segs = &.{}, .width = 0 };
                    const pad = if (fits) width -| cell_line.width else 0;
                    const left = switch (b.column_align(i)) {
                        .right => pad,
                        .center => pad / 2,
                        .none, .left => 0,
                    };
                    try line.add(self.arena, try self.spaces(left), .{});
                    for (cell_line.segs) |seg| try line.add(self.arena, seg.text, seg.attrs);
                    if (i + 1 < widths.items.len) try line.add(self.arena, try self.spaces(pad - left), .{});
                }
                if (fits)
                    try self.emit(line.text.items, line.segs.items, 0, line.text.items.len)
                else
                    try self.wrap_words(line.text.items, line.segs.items, 0, line.text.items.len);
            }
            if (row.head and fits) {
                var rule: LineText = .{};
                for (widths.items, 0..) |width, i| {
                    if (i > 0) try rule.add(self.arena, "─┼─", border);
                    var dashes: std.ArrayList(u8) = .empty;
                    for (0..width) |_| try dashes.appendSlice(self.arena, "─");
                    try rule.add(self.arena, dashes.items, border);
                }
                try self.emit(rule.text.items, rule.segs.items, 0, rule.text.items.len);
            }
        }
    }

    fn spaces(self: *const LayoutBuilder, n: usize) ![]const u8 {
        const s = try self.arena.alloc(u8, n);
        @memset(s, ' ');
        return s;
    }

    const Grapheme = struct { len: usize, width: usize };

    fn grapheme(self: *const LayoutBuilder, text: []const u8, col: usize) Grapheme {
        var cols: usize = 0;
        const len = self.view.plane.egc_length(text, &cols, col, self.tab_width);
        return .{ .len = @max(1, len), .width = cols };
    }

    fn wrap(self: *LayoutBuilder, b: BlockReader) !void {
        const segs = try self.segments(b);
        const mode: enum { words, cells, clip } = switch (b.wrap()) {
            .words => .words,
            .cells => if (tui.config().info_code_overflow == .clip) .clip else .cells,
        };
        var lines = std.mem.splitScalar(u8, b.text, '\n');
        var line_start: usize = 0;
        while (lines.next()) |line| {
            const a = line_start;
            const end = a + line.len;
            line_start = end + 1;
            switch (mode) {
                .words => try self.wrap_words(b.text, segs, a, end),
                .cells => try self.wrap_cells(b.text, segs, a, end),
                .clip => try self.clip(b.text, segs, a, end),
            }
        }
    }

    fn avail(self: *const LayoutBuilder) usize {
        return @max(1, self.width -| self.next_prefix_width());
    }

    fn clip(self: *LayoutBuilder, text: []const u8, segs: []const Run, a: usize, end: usize) !void {
        const width = self.avail();
        if (self.text_width(text[a..end], 0) <= width) return self.emit(text, segs, a, end);
        var col: usize = 0;
        var i = a;
        while (i < end) {
            const g = self.grapheme(text[i..end], col);
            if (col + g.width > width -| 1) break;
            col += g.width;
            i += g.len;
        }
        try self.emit(text, segs, a, i);
        const line = &self.view.lines.items[self.view.lines.items.len - 1];
        const runs = try self.arena.alloc(Run, line.runs.len + 1);
        @memcpy(runs[0..line.runs.len], line.runs);
        runs[line.runs.len] = .{ .text = "…", .attrs = if (line.runs.len > 0) line.runs[line.runs.len - 1].attrs else .{} };
        line.runs = runs;
        line.width += 1;
    }

    fn wrap_cells(self: *LayoutBuilder, text: []const u8, segs: []const Run, a: usize, end: usize) !void {
        var ls = a;
        var col: usize = 0;
        var i = a;
        var width = self.avail();
        while (i < end) {
            const g = self.grapheme(text[i..end], col);
            if (col + g.width > width and i > ls) {
                try self.emit(text, segs, ls, i);
                ls = i;
                col = 0;
                width = self.avail();
            }
            col += g.width;
            i += g.len;
        }
        if (ls < end or a == end) try self.emit(text, segs, ls, end);
    }

    fn wrap_words(self: *LayoutBuilder, text: []const u8, segs: []const Run, a: usize, end: usize) !void {
        var ls = a;
        var col: usize = 0;
        var word_end = a;
        var i = a;
        var width = self.avail();
        while (i < end) {
            if (text[i] == ' ') {
                if (ls == i and ls != a) {
                    // no spaces at the start of a wrapped line
                    i += 1;
                    ls = i;
                    word_end = i;
                    continue;
                }
                col += 1;
                i += 1;
                continue;
            }
            var j = i;
            var word_width: usize = 0;
            while (j < end and text[j] != ' ') {
                const g = self.grapheme(text[j..end], col + word_width);
                word_width += g.width;
                j += g.len;
            }
            if (col + word_width > width and word_end > ls) {
                try self.emit(text, segs, ls, word_end);
                ls = i;
                col = 0;
                width = self.avail();
            }
            if (word_width > width) {
                // a word longer than the line breaks at cells
                var k = i;
                var c = col;
                while (k < j) {
                    const g = self.grapheme(text[k..j], c);
                    if (c + g.width > width and k > ls) {
                        try self.emit(text, segs, ls, k);
                        ls = k;
                        c = 0;
                        width = self.avail();
                    }
                    c += g.width;
                    k += g.len;
                }
                col = c;
            } else {
                col += word_width;
            }
            word_end = j;
            i = j;
        }
        if (word_end > ls or a == end) try self.emit(text, segs, ls, word_end);
    }
};

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (!std.mem.eql(u8, self.theme_name, theme.name) and self.has_markdown()) self.restyle() catch {};
    self.plane.set_base_style(if (tui.config().hover_info_mode == .box) theme.editor_widget else theme.panel);
    self.plane.erase();
    self.plane.home();
    const base = self.plane.style;
    defer self.plane.style = base;
    for (self.lines.items[@min(self.top, self.lines.items.len)..], 0..) |line, row| {
        if (row >= self.view_rows) break;
        self.plane.cursor_move_yx(@intCast(row), 0);
        for (line.runs) |run| self.write_run(base, run);
    }
    return false;
}

fn has_markdown(self: *const Self) bool {
    for (self.sections.items) |section| if (section.kind == .markdown) return true;
    return false;
}

fn write_run(self: *Self, base: markdown.rich_line.Style, run: Run) void {
    const a = run.attrs.style;
    var style = base;
    if (a.fg != .default) style.fg = a.fg;
    if (a.bg != .default) style.bg = a.bg;
    if (a.ul != .default) style.ul = a.ul;
    if (a.ul_style != .off) style.ul_style = a.ul_style;
    style.bold = style.bold or a.bold;
    style.dim = style.dim or a.dim;
    style.italic = style.italic or a.italic;
    style.blink = style.blink or a.blink;
    style.reverse = style.reverse or a.reverse;
    style.invisible = style.invisible or a.invisible;
    style.strikethrough = style.strikethrough or a.strikethrough;
    self.plane.style = style;
    if (run.attrs.link.len == 0) {
        _ = self.plane.putstr(run.text) catch {};
        return;
    }
    var i: usize = 0;
    while (i < run.text.len) {
        var cell = self.plane.cell_init();
        const len = self.plane.cell_load(&cell, run.text[i..]) catch return;
        self.plane.cell_set_link(&cell, run.attrs.link, run.attrs.link_id);
        const width = self.plane.putc(&cell) catch return;
        if (width == 0) return;
        i += @max(1, len);
    }
}
