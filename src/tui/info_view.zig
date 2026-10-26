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
const reflow = @import("Buffer").reflow;
const tui = @import("tui.zig");
const richdoc = @import("richdoc");

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
    markdown: struct { sdoc: richdoc.SDoc, rdoc: richdoc.RDoc },

    fn deinit(self: Section, allocator: Allocator) void {
        switch (self) {
            .plaintext => |text| allocator.free(text),
            .markdown => |md| {
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
theme_name: []const u8 = "",
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
scroller: Scroller = .{},
title: ?[]const u8 = null,
source: ?[]const u8 = null,

const default_widget_type: Widget.Type = .panel;
const panel_margin = 2;

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
pub fn create_preview(allocator: Allocator, parent: Plane, source: []const u8, name_: []const u8) !Panel {
    return create_detached(allocator, parent, "Preview", name_, source);
}

/// a non-singleton info panel for a copy of an info box
pub fn create_info_copy(allocator: Allocator, parent: Plane, name_: []const u8) !Panel {
    return create_detached(allocator, parent, "Info", name_, null);
}

fn create_detached(allocator: Allocator, parent: Plane, prefix: []const u8, name_: []const u8, source: ?[]const u8) !Panel {
    const self, const container = try create_panel_widget(allocator, parent);
    errdefer container.deinit(allocator);
    self.title = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, name_ });
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
    markdown: richdoc.SDoc,

    fn deinit(self: Content, allocator: Allocator) void {
        switch (self) {
            .plaintext => |text| allocator.free(text),
            .markdown => |sdoc| allocator.free(sdoc.raw.bytes),
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
            .markdown => |md| .{ .markdown = .{ .raw = .{ .bytes = try allocator.dupe(u8, md.sdoc.raw.bytes) } } },
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
        .plaintext => |text| try self.append_content(.plaintext, text),
        .markdown => |sdoc| try self.append_sdoc(sdoc),
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
        .markdown => try self.append_owned_sdoc(try richdoc.markdown.parse(self.allocator, content, tui.query_cache())),
    }
}

pub fn append_sdoc(self: *Self, sdoc: richdoc.SDoc) !void {
    return self.append_owned_sdoc(.{ .raw = .{ .bytes = try self.allocator.dupe(u8, sdoc.raw.bytes) } });
}

fn append_owned_sdoc(self: *Self, sdoc: richdoc.SDoc) !void {
    {
        errdefer self.allocator.free(sdoc.raw.bytes);
        const rdoc = try self.render_sdoc(sdoc);
        errdefer self.allocator.free(rdoc.raw.bytes);
        try self.sections.append(self.allocator, .{ .markdown = .{ .sdoc = sdoc, .rdoc = rdoc } });
    }
    try self.relayout();
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
        tui.config().info_box_width_limit
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
    richdoc.render.to_plane(&self.layout, &self.plane, self.scroller.top(), self.view_rows, self.text_col(), self.plane.style);
    return more;
}

fn has_markdown(self: *const Self) bool {
    for (self.sections.items) |section| if (section == .markdown) return true;
    return false;
}
