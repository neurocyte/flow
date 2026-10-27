const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const command = @import("command");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const Scroller = @import("Scroller.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const tp = @import("thespian");
const cbor = @import("cbor");
const reflow = @import("Buffer").reflow;
const tui = @import("tui.zig");
const richdoc = @import("richdoc");
const placement = @import("info_box_placement.zig");

pub const name = @typeName(Self);

pub fn render_theme(theme: *const Widget.Theme) richdoc.render.Theme {
    return .{ .context = theme, .find = find_render_token };
}

fn find_render_token(context: *const anyopaque, scope: []const u8) ?richdoc.render.Token {
    const theme: *const Widget.Theme = @ptrCast(@alignCast(context));
    const token = tui.find_scope_style(theme, scope) orelse return null;
    return .{
        .fg = if (token.style.fg) |fg| fg.color else null,
        .fs = if (token.style.fs) |fs| std.meta.stringToEnum(richdoc.render.FontStyle, @tagName(fs)) else null,
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

const Section = union(Kind) {
    plaintext: []const u8,
    markdown: struct { text: []const u8, sdoc: richdoc.SDoc, rdoc: richdoc.RDoc },

    fn deinit(self: Section, allocator: Allocator) void {
        switch (self) {
            .plaintext => |text| allocator.free(text),
            .markdown => |md| {
                allocator.free(md.text);
                allocator.free(md.sdoc.raw.bytes);
                allocator.free(md.rdoc.raw.bytes);
            },
        }
    }
};

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
view_cols: usize = 0,
sections: std.ArrayList(Section) = .empty,
layout: richdoc.RDocLayout,
layout_width: usize = 0,
box_text_width: ?usize = null,
theme_name: []const u8 = "",
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
scroller: Scroller = .{},
source_anchor: ?SourceAnchor = null,
source_top: ?usize = null,
source_scrolled_away: bool = false,
title: ?[]const u8 = null,
source: ?[]const u8 = null,
source_version: ?usize = null,

const default_widget_type: Widget.Type = .panel;
const panel_margin = 2;
pub const box_min_width = 40;
const box_slack_cols = 3;

pub const panel_tag = "info";
pub const panel_singleton = true;
pub const preview_tag = "preview";

pub fn panel_title(self: *Self) []const u8 {
    return self.title orelse "Info";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "\u{ea74}";
}

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    const self, const container = try create_panel_widget(allocator, parent);
    return Panel.to_hosted(self, container.widget());
}

/// a non-singleton info panel showing a preview of `source`
pub fn create_preview(allocator: Allocator, parent: Plane, source: []const u8) !Panel {
    const name_ = if (source.len > 0 and source[0] == '*') source else std.fs.path.basename(source);
    return create_detached(allocator, parent, "Preview: {s}", .{name_}, source);
}

/// a non-singleton info panel for a copy of an info box
pub fn create_info_copy(allocator: Allocator, parent: Plane, name_: []const u8) !Panel {
    return create_detached(allocator, parent, "Info: {s}", .{name_}, null);
}

// a preview: [source, row, offset], an info copy: [title, [[kind, text], ...]]
pub fn panel_write_state(self: *Self, writer: *std.Io.Writer) error{WriteFailed}!void {
    if (self.source) |source| {
        const position = self.source_position();
        return cbor.writeValue(writer, .{
            source,
            if (position) |p| p.row else null,
            if (position) |p| p.offset else 0,
        });
    }
    const title = self.title orelse return cbor.writeValue(writer, null);
    try cbor.writeArrayHeader(writer, 2);
    try cbor.writeValue(writer, title);
    try cbor.writeArrayHeader(writer, self.sections.items.len);
    for (self.sections.items) |section| switch (section) {
        .plaintext => |text| try cbor.writeValue(writer, .{ @tagName(Kind.plaintext), text }),
        .markdown => |md| try cbor.writeValue(writer, .{ @tagName(Kind.markdown), md.text }),
    };
}

pub fn restore_detached(allocator: Allocator, parent: Plane, state: []const u8) !Panel {
    var source: []const u8 = undefined;
    var row: ?usize = null;
    var offset: isize = 0;
    if (try cbor.match(state, .{ cbor.extract(&source), cbor.extract(&row), cbor.extract(&offset) })) {
        const panel = try create_preview(allocator, parent, source);
        if (row) |r| if (panel.cast(Self)) |self| {
            self.source_anchor = .{ .row = r, .offset = offset };
        };
        try tp.self_pid().send(.{ "cmd", "markdown_preview_sync_disk" });
        return panel;
    }
    var title: []const u8 = undefined;
    var sections: []const u8 = undefined;
    if (!try cbor.match(state, .{ cbor.extract(&title), cbor.extract_cbor(&sections) }))
        return error.InvalidInfoPanelState;
    const panel = try create_detached(allocator, parent, "{s}", .{title}, null);
    errdefer panel.widget.deinit(allocator);
    const self = panel.cast(Self) orelse return error.InvalidInfoPanelState;
    var iter = sections;
    var n = try cbor.decodeArrayHeader(&iter);
    while (n > 0) : (n -= 1) {
        var kind: []const u8 = undefined;
        var text: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, .{ cbor.extract(&kind), cbor.extract(&text) }))
            return error.InvalidInfoPanelState;
        try self.append_content(std.meta.stringToEnum(Kind, kind) orelse return error.InvalidInfoPanelState, text);
    }
    return panel;
}

fn create_detached(allocator: Allocator, parent: Plane, comptime title_fmt: []const u8, title_args: anytype, source: ?[]const u8) !Panel {
    const self, const container = try create_panel_widget(allocator, parent);
    errdefer container.deinit(allocator);
    self.title = try std.fmt.allocPrint(allocator, title_fmt, title_args);
    if (source) |s| self.source = try allocator.dupe(u8, s);
    var panel = Panel.to_tagged(self, preview_tag, false);
    panel.widget = container.widget();
    return panel;
}

/// the info_view inside an info box layer
pub fn from_layer(layer: *tui.WidgetLayerBox) ?*Self {
    const w = layer.widget().get(@typeName(Self)) orelse return null;
    return w.dynamic_cast(Self);
}

pub const Content = union(Kind) {
    plaintext: []const u8,
    markdown: []const u8,

    fn deinit(self: Content, allocator: Allocator) void {
        switch (self) {
            inline else => |text| allocator.free(text),
        }
    }
};

/// a copy of the content that outlives this info_view
pub fn dupe_content(self: *const Self, allocator: Allocator) ![]Content {
    const content = try allocator.alloc(Content, self.sections.items.len);
    var n: usize = 0;
    errdefer free_content(allocator, content[0..n]);
    for (self.sections.items) |section| {
        content[n] = switch (section) {
            .plaintext => |text| .{ .plaintext = try allocator.dupe(u8, text) },
            .markdown => |md| .{ .markdown = try allocator.dupe(u8, md.text) },
        };
        n += 1;
    }
    return content;
}

pub fn free_content(allocator: Allocator, content: []const Content) void {
    for (content) |c| c.deinit(allocator);
    allocator.free(content);
}

pub fn set_contents(self: *Self, content: []const Content) !void {
    self.clear();
    self.scroller.scroll(.top);
    for (content) |c| switch (c) {
        inline else => |text, kind| try self.append_content(kind, text),
    };
}

pub fn is_preview_of(self: *Self, source: []const u8) bool {
    return if (self.source) |s| std.mem.eql(u8, s, source) else false;
}

fn create_panel_widget(allocator: Allocator, parent: Plane) !struct { *Self, *WidgetList } {
    const container = try WidgetList.createH(allocator, parent, "info.container", .dynamic);
    errdefer container.deinit(allocator);
    const self = try init(allocator, container.plane, default_widget_type);
    try container.add(Widget.to(self));
    self.panel_input = try PanelInput.init(allocator, "info");
    try self.scroller.attach_scrollbar(allocator, container, container.plane);
    return .{ self, container };
}

pub fn create_widget_type(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !Widget {
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    errdefer container.deinit(allocator);
    const self = try init(allocator, parent, widget_type);
    container.ctx = self;
    try container.add(Widget.to(self));
    try self.scroller.attach_scrollbar(allocator, container, parent);
    if (self.scroller.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_v.editor_widget_style;
    return container.widget();
}

fn init(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .layout = .init(allocator),
        .widget_type = widget_type,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.panel_input) |*panel_input| panel_input.deinit(Widget.to(self));
    self.clear();
    self.sections.deinit(self.allocator);
    if (self.title) |title| self.allocator.free(title);
    if (self.source) |source| self.allocator.free(source);
    self.layout.deinit();
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
    if (try self.scroller.receive_mouse(m)) return true;
    const panel_input = if (self.panel_input) |*panel_input| panel_input else return false;
    if (try PanelInput.receive_context_menu(self, m)) return true;
    return panel_input.receive(from, m);
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    self.scroller.scroll(action);
}

pub fn panel_copy(self: *Self) void {
    var text: std.Io.Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    for (self.layout.lines.items) |line| {
        for (line.runs) |run| text.writer.writeAll(run.text) catch return;
        text.writer.writeByte('\n') catch return;
    }
    PanelInput.copy_to_clipboard(text.written());
}

pub fn clear(self: *Self) void {
    for (self.sections.items) |section| section.deinit(self.allocator);
    self.sections.clearRetainingCapacity();
    self.layout.reset();
    self.layout_width = 0;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.view_rows = pos.h;
    self.view_cols = pos.w;
    if (self.text_width() != self.layout_width) self.relayout() catch {};
    self.scroller.set_size(self.layout.lines.items.len, self.view_rows);
    self.resolve_source_anchor();
}

pub const SourceAnchor = struct {
    row: usize,
    place: enum { top, center } = .top,
    offset: isize = 0,
    motion: enum { jump, glide } = .jump,
    state: enum { following, scrolled_away } = .following,
};

pub fn scroll_to_source(self: *Self, anchor: SourceAnchor) void {
    self.source_anchor = anchor;
    self.resolve_source_anchor();
}

pub fn source_position(self: *const Self) ?SourceAnchor {
    if (self.source_anchor) |anchor| return anchor;
    const lines = self.layout.lines.items;
    const top = @min(self.scroller.top(), lines.len);
    const row = for (lines[top..]) |line| {
        if (line.src_row) |row| break row;
    } else for (0..top) |i| {
        if (lines[top - 1 - i].src_row) |row| break row;
    } else return null;
    const line = self.layout.line_of_src_row(row) orelse return null;
    return .{
        .row = row,
        .offset = @as(isize, @intCast(top)) - @as(isize, @intCast(line)),
        .state = if (self.scrolled_away_from_source()) .scrolled_away else .following,
    };
}

fn resolve_source_anchor(self: *Self) void {
    const anchor = self.source_anchor orelse return;
    if (self.view_rows == 0 or self.layout.lines.items.len == 0) return;
    self.source_anchor = null;
    if (self.layout.line_of_src_row(anchor.row)) |line| {
        const top = switch (anchor.place) {
            .top => @as(usize, @intCast(@max(0, @as(isize, @intCast(line)) + anchor.offset))),
            .center => line -| self.view_rows / 2,
        };
        if (@min(top, self.scroller.max_top()) != self.scroller.anim.dest) switch (anchor.motion) {
            .jump => self.scroller.jump_to(top),
            .glide => self.scroller.glide_to(top),
        };
    }
    self.source_top = self.scroller.anim.dest;
    self.source_scrolled_away = anchor.state == .scrolled_away;
}

pub fn scrolled_away_from_source(self: *const Self) bool {
    if (self.source_anchor) |anchor| return anchor.state == .scrolled_away;
    if (self.source_scrolled_away) return true;
    const top = self.source_top orelse return false;
    return @min(top, self.scroller.max_top()) != self.scroller.anim.dest;
}

pub fn append_content(self: *Self, kind: Kind, content: []const u8) !void {
    switch (kind) {
        .plaintext => {
            const text = try self.allocator.dupe(u8, content);
            self.sections.append(self.allocator, .{ .plaintext = text }) catch |e| {
                self.allocator.free(text);
                return e;
            };
        },
        .markdown => {
            const text = try self.allocator.dupe(u8, content);
            errdefer self.allocator.free(text);
            const sdoc = try richdoc.markdown.parse(self.allocator, text, tui.query_cache());
            errdefer self.allocator.free(sdoc.raw.bytes);
            const rdoc = try self.render_sdoc(sdoc);
            errdefer self.allocator.free(rdoc.raw.bytes);
            try self.sections.append(self.allocator, .{ .markdown = .{ .text = text, .sdoc = sdoc, .rdoc = rdoc } });
        },
    }
    try self.relayout();
}

pub fn write_markdown(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (self.sections.items, 0..) |section, i| {
        if (i > 0) try writer.writeByte('\n');
        switch (section) {
            .plaintext => |text| try richdoc.markdown.write_code_block(writer, null, &.{std.mem.trimEnd(u8, text, "\n")}),
            .markdown => |md| try writer.print("{s}\n", .{std.mem.trimEnd(u8, md.text, "\n")}),
        }
    }
}

pub fn set_content(self: *Self, kind: Kind, content: []const u8) !void {
    self.clear();
    self.scroller.scroll(.top);
    return self.append_content(kind, content);
}

pub fn bar_cols_for(self: *const Self, rows: usize) usize {
    return if (self.scroller.scrollbar != null and self.layout.lines.items.len > rows) 1 else 0;
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    return .{ .rows = self.layout.lines.items.len, .cols = self.layout.max_width() };
}

pub const BoxAnchor = struct {
    before: usize,
    after: usize,
    side_rows: BoxRows,
    fallback_x: usize,
    fallback_rows: BoxRows,
};

pub const BoxRows = placement.Span;

pub const BoxSide = enum { right, left, fallback };

pub fn place_box(self: *Self, layer: *tui.WidgetLayerBox, anchor: BoxAnchor) !BoxSide {
    const padding = tui.get_widget_style(self.widget_type).padding;
    const pad_cols = padding.left + padding.right + box_slack_cols;
    const pad_rows = padding.top + padding.bottom;
    const height_limit = tui.config().info_box_height_limit;
    const screen_w = tui.screen().w;

    try self.set_box_text_width(null);
    const want = self.content_size().cols + pad_cols + self.bar_cols_for(height_limit);
    const has_fallback = anchor.fallback_rows.below > 0 or anchor.fallback_rows.above > 0;
    const side = placement.horizontal(screen_w, anchor.before, anchor.after, want, if (has_fallback) box_min_width else 0);
    const room = if (side) |s| s.w else placement.clamped(screen_w, anchor.fallback_x, want).w;
    if (room < want) try self.set_box_text_width(room -| (pad_cols + 1));

    const dim = self.content_size();
    const v = placement.vertical(if (side != null) anchor.side_rows else anchor.fallback_rows, @min(dim.rows, height_limit) + pad_rows);
    const rows = @max(1, v.h -| pad_rows);
    const w = dim.cols + pad_cols + self.bar_cols_for(rows);
    const x = if (side) |s| switch (s.side) {
        .right => s.x,
        .left => anchor.before -| w,
    } else placement.clamped(screen_w, anchor.fallback_x, w).x;
    layer.handle_resize(.{ .y = v.y, .x = x, .h = rows + pad_rows, .w = w });
    return if (side) |s| switch (s.side) {
        .right => .right,
        .left => .left,
    } else .fallback;
}

fn set_box_text_width(self: *Self, width: ?usize) !void {
    if (self.box_text_width == width) return;
    self.box_text_width = width;
    if (self.text_width() != self.layout_width) try self.relayout();
}

fn render_sdoc(self: *Self, sdoc: richdoc.SDoc) !richdoc.RDoc {
    const theme = tui.theme();
    self.theme_name = theme.name;
    const default_lang = if (tui.get_active_editor()) |editor| if (editor.file_type) |ft| ft.parser orelse ft.name else null else null;
    return richdoc.render.from_sdoc(self.allocator, sdoc, render_theme(theme), tui.query_cache(), .{
        .default_lang = default_lang,
        .injection_depth = @intCast(@min(tui.config().syntax_injection_depth, 255)),
    });
}

fn restyle(self: *Self) !void {
    for (self.sections.items) |*section| switch (section.*) {
        .plaintext => {},
        .markdown => |*md| {
            const rdoc = try self.render_sdoc(md.sdoc);
            self.allocator.free(md.rdoc.raw.bytes);
            md.rdoc = rdoc;
        },
    };
    try self.relayout();
}

fn target_width(self: *const Self) usize {
    return if (self.widget_type == .info_box)
        @min(tui.config().info_box_width_limit, self.box_text_width orelse std.math.maxInt(usize))
    else if (self.view_cols > 0)
        self.view_cols + self.scroller.bar_cols()
    else
        tui.screen().w;
}

fn text_width(self: *const Self) usize {
    const width = self.target_width();
    if (self.widget_type == .info_box) return @max(1, width);
    const avail = width -| 2 * panel_margin;
    const conf = tui.config();
    return @max(1, if (conf.panel_centered_view) @min(avail, conf.panel_centered_view_width) else avail);
}

fn text_col(self: *const Self) usize {
    if (self.widget_type == .info_box) return 0;
    return panel_margin + (self.target_width() -| 2 * panel_margin -| self.text_width()) / 2;
}

fn relayout(self: *Self) !void {
    const width = self.text_width();
    self.layout_width = width;
    try self.layout_at(width);
    self.scroller.set_size(self.layout.lines.items.len, self.view_rows);
    self.resolve_source_anchor();
}

fn layout_at(self: *Self, width: usize) !void {
    self.layout.reset();
    const tab_width = tui.config().tab_width;
    for (self.sections.items) |section| switch (section) {
        .plaintext => |text| try self.layout_plaintext(text, width, tab_width),
        .markdown => |md| try richdoc.render.to_layout(&self.layout, md.rdoc, &self.plane, .{
            .width = width,
            .tab_width = tab_width,
            .code_overflow = switch (tui.config().info_code_overflow) {
                .wrap => .wrap,
                .clip => .clip,
            },
        }),
    };
    if (self.widget_type == .info_box) try self.layout.fit_fills();
}

fn layout_plaintext(self: *Self, content: []const u8, width: usize, tab_width: usize) !void {
    const arena = self.layout.allocator();
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| if (line.len > 0) {
        const text = try reflow(arena, line, width, .screen, .spaces, self.plane.metrics(tab_width));
        var iter_ = std.mem.splitScalar(u8, text, '\n');
        while (iter_.next()) |line_| if (line_.len > 0)
            try self.layout.add_line(line_, richdoc.render.text_width(&self.plane, line_, 0, tab_width));
    };
}

pub fn update(self: *Self) void {
    self.scroller.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (!std.mem.eql(u8, self.theme_name, theme.name) and self.has_markdown()) self.restyle() catch {};
    self.plane.set_base_style(if (tui.config().hover_info_mode == .box) theme.editor_widget else theme.panel);
    self.plane.erase();
    self.plane.home();
    const more = self.scroller.render();
    richdoc.render.to_plane(&self.layout, &self.plane, self.scroller.top(), self.view_rows, self.text_col(), self.plane.style, .{
        .terminal_link = richdoc.render.is_absolute_uri,
    });
    return more;
}

fn has_markdown(self: *const Self) bool {
    for (self.sections.items) |section| if (section == .markdown) return true;
    return false;
}
