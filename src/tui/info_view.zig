const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const renderer = @import("renderer");
const Plane = renderer.Plane;
const command = @import("command");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const Menu = @import("Menu.zig");
const Scroller = @import("Scroller.zig");
const ScrollLayer = @import("ScrollLayer.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("soft_root").root;
const MouseEvent = @import("MouseEvent");
const reflow = @import("Buffer").reflow;
const tui = @import("tui.zig");
const richdoc = @import("richdoc");
const placement = @import("info_box_placement.zig");
const OverlayLine = @import("OverlayLine.zig");
const link_dispatch = @import("link_dispatch.zig");
const EdgeFade = @import("EdgeFade.zig");
const file_link = @import("file_link");

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

pub const Links = enum { markup, locations };

const Section = union(Kind) {
    plaintext: []const u8,
    markdown: struct { text: []const u8, links: Links, sdoc: richdoc.SDoc, rdoc: richdoc.RDoc },

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
layout_code_overflow: @import("config").CodeOverflow = .wrap,
box_text_width: ?usize = null,
theme_name: []const u8 = "",
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
scroller: Scroller = .{ .pixel_offsets = true },
scroll_layer: ScrollLayer = undefined,
scroll_layer_id: ?renderer.Layer.Id = null,
in_layer_box: bool = false,
fade: EdgeFade = .{},
source_anchor: ?SourceAnchor = null,
source_top: ?usize = null,
source_scrolled_away: bool = false,
title: ?[]const u8 = null,
source: ?[]const u8 = null,
source_version: ?usize = null,
link_hover: ?LinkHover = null,
link_pressed: bool = false,
heading_anchor: ?[]const u8 = null,
links_shown: bool = false,
link_timer: ?tp.Cancellable = null,
link_line_area: ?Widget.Box = null,

const LinkHover = struct {
    href: []const u8,
    since_us: i64,
    shown: bool = false,
};

const default_widget_type: Widget.Type = .panel;
const panel_margin = 2;
pub const box_min_width = 40;
const box_slack_cols = 3;
const fade_cells = 5;

pub const panel_tag = "info";
pub const panel_singleton = true;
pub const preview_tag = "preview";

pub const panel_menu: Menu = .{ .label = "Info", .items = &.{
    .{ .command = .{ .command = "info_open_in_editor" } },
    .{ .command = .{ .command = "toggle_markdown_preview_file_links", .on_activate = .keep_open } },
    .{ .command = .{ .command = "toggle_info_code_overflow", .on_activate = .keep_open } },
} };

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
        .markdown => |md| switch (md.links) {
            .markup => try cbor.writeValue(writer, .{ @tagName(Kind.markdown), md.text }),
            .locations => try cbor.writeValue(writer, .{ @tagName(Kind.markdown), md.text, @tagName(md.links) }),
        },
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
        var links: []const u8 = @tagName(Links.markup);
        var section = iter;
        if (try cbor.matchValue(&section, .{ cbor.extract(&kind), cbor.extract(&text), cbor.extract(&links) }))
            iter = section
        else if (!try cbor.matchValue(&iter, .{ cbor.extract(&kind), cbor.extract(&text) }))
            return error.InvalidInfoPanelState;
        switch (std.meta.stringToEnum(Kind, kind) orelse return error.InvalidInfoPanelState) {
            .plaintext => try self.append_content(.plaintext, text),
            .markdown => try self.append_markdown(text, std.meta.stringToEnum(Links, links) orelse return error.InvalidInfoPanelState),
        }
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
    markdown: struct { text: []const u8, links: Links },

    fn deinit(self: Content, allocator: Allocator) void {
        switch (self) {
            .plaintext => |text| allocator.free(text),
            .markdown => |md| allocator.free(md.text),
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
            .markdown => |md| .{ .markdown = .{ .text = try allocator.dupe(u8, md.text), .links = md.links } },
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
    self.scroller.jump_left_to(0);
    for (content) |c| switch (c) {
        .plaintext => |text| try self.append_content(.plaintext, text),
        .markdown => |md| try self.append_markdown(md.text, md.links),
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
    self.scroll_layer = try ScrollLayer.init(allocator, &self.scroll_layer_id);
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.panel_input) |*panel_input| panel_input.deinit(Widget.to(self));
    self.clear();
    self.set_heading_anchor(null);
    self.sections.deinit(self.allocator);
    if (self.title) |title| self.allocator.free(title);
    if (self.source) |source| self.allocator.free(source);
    self.layout.deinit();
    self.fade.deinit();
    self.scroll_layer.deinit();
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
    var coord: MouseEvent.Coord = undefined;
    var mods: MouseEvent.Modifiers = .{};
    var hover: bool = false;
    if (try m.match(.{ MouseEvent.Type.motion, tp.any, tp.extract(&coord), tp.extract(&mods) })) {
        self.show_links(mods.ctrl);
        self.hover_link(coord);
    } else if (try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.left, tp.extract(&coord), tp.any })) {
        self.link_pressed = self.link_hover != null and self.link_under(coord) != null;
    } else if (try m.match(.{ MouseEvent.Type.release, MouseEvent.Button.left, tp.extract(&coord), tp.extract(&mods) })) {
        const pressed = self.link_pressed;
        self.link_pressed = false;
        if (pressed) if (self.link_hover) |link| if (self.link_under(coord)) |href| if (std.mem.eql(u8, href, link.href)) {
            self.open_link(href, if (tui.mouse_actions(mods).alt_click) .alternate else .normal);
            return true;
        };
    } else if (try m.match(.{ "H", tp.extract(&hover) })) {
        if (!hover) {
            self.show_links(false);
            self.clear_link_hover();
        }
    }
    if (try self.receive_mouse_hscroll(m)) return true;
    if (try self.scroller.receive_mouse(m)) {
        self.clear_link_hover();
        return true;
    }
    const panel_input = if (self.panel_input) |*panel_input| panel_input else return false;
    if (try PanelInput.receive_mouse(self, m)) return true;
    return panel_input.receive(from, m);
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    self.clear_link_hover();
    const step = tui.config().scroll_step_horizontal;
    switch (action) {
        .left => self.scroller.glide_left_to(self.scroller.left_dest() -| step),
        .right => self.scroller.glide_left_to(self.scroller.left_dest() + step),
        .line_start => self.scroller.jump_left_to(0),
        .line_end => self.scroller.jump_left_to(self.max_left_col()),
        else => self.scroller.scroll(action),
    }
}

fn receive_mouse_hscroll(self: *Self, m: tp.message) error{Exit}!bool {
    var btn: MouseEvent.Button = .none;
    var mods: MouseEvent.Modifiers = .{};
    if (!try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.any, tp.extract(&mods) })) return false;
    const actions = tui.mouse_actions(mods);
    const direction: enum { left, right } = switch (btn) {
        .wheel_up => if (actions.alt_scroll) .left else return false,
        .wheel_down => if (actions.alt_scroll) .right else return false,
        .wheel_right => .left,
        .wheel_left => .right,
        else => return false,
    };
    const step = tui.config().scroll_step_horizontal * @as(usize, if (actions.fast_scroll) 5 else 1);
    self.clear_link_hover();
    self.scroller.glide_left_to(switch (direction) {
        .left => self.scroller.left_dest() -| step,
        .right => self.scroller.left_dest() + step,
    });
    return true;
}

fn update_cols(self: *Self) void {
    const cols = self.visible_cols();
    self.scroller.set_cols(self.max_left_col() + cols, cols);
}

fn visible_cols(self: *const Self) usize {
    return self.view_cols -| self.text_col();
}

fn max_left_col(self: *const Self) usize {
    const width = self.layout.max_width();
    const cols = self.visible_cols();
    if (width <= cols) return 0;
    return width + self.text_col() - cols;
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
    self.clear_link_hover();
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
    if (self.layout_stale()) self.relayout() catch {};
    self.scroller.set_view(pos, &self.plane);
    self.scroller.set_content(self.layout.lines.items.len);
    self.update_cols();
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
        if (@min(top, self.scroller.max_top()) != self.scroller.dest()) switch (anchor.motion) {
            .jump => self.scroller.jump_to(top),
            .glide => self.scroller.glide_to(top),
        };
    }
    self.source_top = self.scroller.dest();
    self.source_scrolled_away = anchor.state == .scrolled_away;
}

pub fn scrolled_away_from_source(self: *const Self) bool {
    if (self.source_anchor) |anchor| return anchor.state == .scrolled_away;
    if (self.source_scrolled_away) return true;
    const top = self.source_top orelse return false;
    return @min(top, self.scroller.max_top()) != self.scroller.dest();
}

pub fn append_content(self: *Self, kind: Kind, content: []const u8) !void {
    switch (kind) {
        .plaintext => {
            const text = try self.allocator.dupe(u8, content);
            self.sections.append(self.allocator, .{ .plaintext = text }) catch |e| {
                self.allocator.free(text);
                return e;
            };
            try self.relayout();
        },
        .markdown => try self.append_markdown(content, .markup),
    }
}

pub fn append_markdown(self: *Self, content: []const u8, links: Links) !void {
    const text = try self.allocator.dupe(u8, content);
    errdefer self.allocator.free(text);
    const sdoc = try richdoc.markdown.parse(self.allocator, text, tui.query_cache());
    errdefer self.allocator.free(sdoc.raw.bytes);
    const rdoc = try self.render_sdoc(sdoc, links);
    errdefer self.allocator.free(rdoc.raw.bytes);
    try self.sections.append(self.allocator, .{ .markdown = .{ .text = text, .links = links, .sdoc = sdoc, .rdoc = rdoc } });
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
    self.scroller.jump_left_to(0);
    return self.append_content(kind, content);
}

pub fn set_markdown(self: *Self, content: []const u8, links: Links) !void {
    self.clear();
    self.scroller.scroll(.top);
    return self.append_markdown(content, links);
}

pub fn markdown_links(self: *const Self) ?Links {
    for (self.sections.items) |section| switch (section) {
        .markdown => |md| return md.links,
        .plaintext => {},
    };
    return null;
}

pub fn bar_cols_for(self: *const Self, rows: usize) usize {
    return if (self.scroller.scrollbar != null and self.layout.lines.items.len > rows) 1 else 0;
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    return .{ .rows = self.layout.lines.items.len, .cols = @min(self.layout.max_width(), self.text_width()) };
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
    self.box_text_width = width;
    if (self.layout_stale()) try self.relayout();
}

fn layout_stale(self: *const Self) bool {
    return self.text_width() != self.layout_width or self.layout_code_overflow != tui.config().info_code_overflow;
}

fn render_sdoc(self: *Self, sdoc: richdoc.SDoc, links: Links) !richdoc.RDoc {
    const theme = tui.theme();
    self.theme_name = theme.name;
    const default_lang = if (tui.get_active_editor()) |editor| if (editor.file_type) |ft| ft.parser orelse ft.name else null else null;
    return richdoc.render.from_sdoc(self.allocator, sdoc, render_theme(theme), tui.query_cache(), .{
        .default_lang = default_lang,
        .injection_depth = @intCast(@min(tui.config().syntax_injection_depth, 255)),
        .linkify = switch (links) {
            .markup => null,
            .locations => .{ .context = self, .find = find_location },
        },
    });
}

fn find_location(context: *const anyopaque, allocator: Allocator, line: []const u8) error{OutOfMemory}!?richdoc.render.Link {
    const self: *const Self = @ptrCast(@alignCast(context));
    const range = file_link.find_in_line(line) orelse return null;
    var link: richdoc.render.Link = .{ .start = range.start, .end = range.end, .href = "" };
    var href: std.Io.Writer.Allocating = .init(allocator);
    switch (file_link.parse(line[range.start..range.end]) catch return link) {
        .url => |url| link.href = url.url,
        .file => |file| {
            const path = try std.fs.path.resolveAlloc(allocator, &.{ tp.env.get().str("project"), self.base_dir(), file.path });
            link_dispatch.write_file_href(&href.writer, path, file.line, file.column) catch return error.OutOfMemory;
            link.href = href.written();
        },
        .dir => {},
    }
    return link;
}

fn base_dir(self: *const Self) []const u8 {
    if (self.source) |source| return std.fs.path.dirname(source) orelse "";
    return tp.env.get().str("project");
}

fn restyle(self: *Self) !void {
    for (self.sections.items) |*section| switch (section.*) {
        .plaintext => {},
        .markdown => |*md| {
            const rdoc = try self.render_sdoc(md.sdoc, md.links);
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
    self.update_cols();
    self.scroller.set_content(self.layout.lines.items.len);
    self.resolve_source_anchor();
}

fn layout_at(self: *Self, width: usize) !void {
    self.layout.reset();
    const tab_width = tui.config().tab_width;
    self.layout_code_overflow = tui.config().info_code_overflow;
    for (self.sections.items) |section| switch (section) {
        .plaintext => |text| try self.layout_plaintext(text, width, tab_width),
        .markdown => |md| try richdoc.render.to_layout(&self.layout, md.rdoc, &self.plane, .{
            .width = width,
            .tab_width = tab_width,
            .code_overflow = switch (self.layout_code_overflow) {
                .wrap => .wrap,
                .scroll => .scroll,
            },
        }),
    };
    if (self.widget_type == .info_box) try self.layout.fit_fills(width);
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
    if (self.theme_name.ptr != theme.name.ptr and self.has_markdown()) self.restyle() catch {};
    const base = if (tui.config().hover_info_mode == .box) theme.editor_widget else theme.panel;
    self.plane.set_base_style(base);
    self.plane.erase();
    self.plane.home();
    self.update_cols();
    const more = self.scroller.render();
    const pos = self.scroller.pos();
    self.scroll_layer.prepare(&self.plane, self.scroller.draw_rows(), self.view_cols + @intFromBool(pos.xoffset > 0));
    const content = &self.scroll_layer.plane;
    content.set_base_style(base);
    content.erase();
    content.home();
    richdoc.render.to_plane(&self.layout, content, self.scroller.top(), self.scroller.draw_rows(), self.text_col(), self.scroller.left(), content.style, .{
        .terminal_link = terminal_link,
        .underline = if (self.links_shown) .all else if (self.link_hover) |h| .{ .link = h.href } else .none,
    });
    if (!self.in_layer_box) self.submit_content(null);
    self.render_fade(base.bg);
    self.show_link_line();
    return more;
}

fn render_fade(self: *Self, bg: ?Widget.Theme.Color) void {
    const color = bg orelse return;
    const cols = self.visible_cols();
    const cw = self.plane.cell_x();
    const ox, const oy = self.plane.global_origin_px();
    const view_w, const view_h = self.scroller.view_px();
    const margin = @as(i32, @intCast(self.text_col())) * cw;
    const view: renderer.Layer.Frame = .{
        .x = ox + margin,
        .y = oy,
        .w = @as(i32, @intCast(view_w)) - margin,
        .h = @intCast(view_h),
    };
    self.fade.submit(self.allocator, view, .horizontal, .{
        .head = self.scroller.scrolled_left(),
        .tail = self.scroller.scrolled_right(),
    }, @intCast(@min(fade_cells, cols / 4)), color, self.scroll_layer.over_level(&self.plane));
}

fn submit_content(self: *Self, parent: ?renderer.Layer.Handle) void {
    self.scroll_layer.submit(&self.plane, self.scroller.pos(), self.scroller.view_px(), .{ .margin_cols = self.text_col(), .parent = parent });
}

fn after_layer_submit(ctx: ?*anyopaque, handle: renderer.Layer.Handle) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    self.submit_content(handle);
}

pub fn bind_layer(layer: *tui.WidgetLayerBox) void {
    const self = from_layer(layer) orelse return;
    self.in_layer_box = true;
    layer.ctx = self;
    layer.after_submit = after_layer_submit;
}

fn terminal_link(href: []const u8) bool {
    return link_dispatch.terminal_link(href, link_dispatch.renderer);
}

fn open_link(self: *Self, href: []const u8, click: link_dispatch.Click) void {
    self.clear_link_hover();
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const action = link_dispatch.classify(arena.allocator(), href, .{ .base_dir = self.base_dir() }) catch return;
    switch (action) {
        .anchor => |anchor| _ = self.scroll_to_heading(anchor),
        else => link_dispatch.dispatch(action, click),
    }
}

pub fn set_heading_anchor(self: *Self, anchor: ?[]const u8) void {
    if (self.heading_anchor) |old| self.allocator.free(old);
    self.heading_anchor = if (anchor) |a| self.allocator.dupe(u8, a) catch null else null;
}

pub fn resolve_heading_anchor(self: *Self) void {
    const anchor = self.heading_anchor orelse return;
    defer self.set_heading_anchor(null);
    if (!self.scroll_to_heading(anchor)) std.log.scoped(.info_view).info("no heading #{s}", .{anchor});
}

pub fn scroll_to_heading(self: *Self, anchor: []const u8) bool {
    if (self.sections.items.len == 0) return false;
    const md = switch (self.sections.items[0]) {
        .markdown => |md| md,
        .plaintext => return false,
    };
    const row = richdoc.anchors.heading_row(self.allocator, md.sdoc, anchor) catch return false;
    self.scroll_to_source(.{ .row = row orelse return false });
    return true;
}

fn link_under(self: *Self, coord: MouseEvent.Coord) ?[]const u8 {
    if (!self.plane.pixel_frame().contains(coord.x, coord.y)) return null;
    const cell = coord.to_cell(self.scroll_layer.geometry(&self.plane));
    if (cell.row < 0 or cell.col < 0) return null;
    const col: usize = @intCast(cell.col);
    if (col < self.text_col()) return null;
    const line = self.scroller.top() + @as(usize, @intCast(cell.row));
    return richdoc.render.link_at(&self.layout, line, col - self.text_col() + self.scroller.left(), &self.plane);
}

fn hover_link(self: *Self, coord: MouseEvent.Coord) void {
    const href = self.link_under(coord) orelse return self.clear_link_hover();
    if (self.link_hover) |h| if (std.mem.eql(u8, h.href, href)) return;
    self.clear_link_hover();
    const owned = self.allocator.dupe(u8, href) catch return;
    self.link_hover = .{ .href = owned, .since_us = root.get_now().toMicroseconds() };
    tui.rdr().request_mouse_cursor(.pointer, true);
    // a little late, so the render that shows the line comes after the delay
    const delay_us = std.time.us_per_ms * (tui.config().hover_time_ms + 1);
    self.link_timer = tp.self_pid().delay_send_cancellable(self.allocator, "info_view.link_timer", delay_us, .{"render"}) catch null;
    tui.need_render(@src());
}

fn show_links(self: *Self, shown: bool) void {
    if (self.links_shown == shown) return;
    self.links_shown = shown;
    tui.need_render(@src());
}

fn clear_link_hover(self: *Self) void {
    const hover = self.link_hover orelse return;
    if (self.link_timer) |*timer| {
        timer.cancel() catch {};
        timer.deinit();
        self.link_timer = null;
    }
    if (hover.shown) if (tui.mainview()) |mv| mv.hide_link_line();
    self.allocator.free(hover.href);
    self.link_hover = null;
    tui.rdr().request_mouse_cursor(.pointer, false);
    tui.need_render(@src());
}

fn show_link_line(self: *Self) void {
    const hover = if (self.link_hover) |*h| h else return;
    if (hover.shown) return;
    const delay_us: i64 = @intCast(std.time.us_per_ms * tui.config().hover_time_ms);
    if (root.get_now().toMicroseconds() - hover.since_us < delay_us) return;
    const mv = tui.mainview() orelse return;
    const text = self.allocator.dupe(u8, hover.href) catch return;
    defer self.allocator.free(text);
    mv.show_link_line(std.Uri.percentDecodeInPlace(text), self.link_line_area orelse OverlayLine.area_of(self.plane));
    hover.shown = true;
}

fn has_markdown(self: *const Self) bool {
    for (self.sections.items) |section| if (section == .markdown) return true;
    return false;
}
