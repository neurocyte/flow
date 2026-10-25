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

const Section = struct {
    kind: Kind,
    text: []const u8,
    sdoc: richdoc.SDoc = .{},
    rdoc: richdoc.RDoc = .{},

    fn deinit(self: *Section, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.sdoc.raw.bytes);
        allocator.free(self.rdoc.raw.bytes);
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
        .layout = .init(allocator),
        .widget_type = widget_type,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.panel_input) |*panel_input| panel_input.deinit(Widget.to(self));
    self.clear();
    self.sections.deinit(self.allocator);
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
    const panel_input = if (self.panel_input) |*panel_input| panel_input else return false;
    if (try PanelInput.receive_context_menu(self, m)) return true;
    return panel_input.receive(from, m);
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    const rows = @max(1, self.view_rows);
    const max_top = self.layout.lines.items.len -| rows;
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
    for (self.layout.lines.items) |line| {
        for (line.runs) |run| text.writer.writeAll(run.text) catch return;
        text.writer.writeByte('\n') catch return;
    }
    PanelInput.copy_to_clipboard(text.written());
}

pub fn clear(self: *Self) void {
    for (self.sections.items) |*section| section.deinit(self.allocator);
    self.sections.clearRetainingCapacity();
    self.layout.reset();
    self.layout_width = 0;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.view_rows = pos.h;
    self.view_cols = pos.w;
    if (self.target_width() != self.layout_width) self.relayout() catch {};
}

pub fn append_content(self: *Self, kind: Kind, content: []const u8) !void {
    const text = try self.allocator.dupe(u8, content);
    errdefer self.allocator.free(text);
    var section: Section = .{ .kind = kind, .text = text };
    if (kind == .markdown) {
        section.sdoc = try richdoc.markdown.parse(self.allocator, text, tui.query_cache());
        errdefer self.allocator.free(section.sdoc.raw.bytes);
        section.rdoc = try self.render_sdoc(section.sdoc);
    }
    errdefer section.deinit(self.allocator);
    try self.sections.append(self.allocator, section);
    try self.relayout();
}

pub fn set_content(self: *Self, kind: Kind, content: []const u8) !void {
    self.clear();
    self.top = 0;
    return self.append_content(kind, content);
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
    for (self.sections.items) |*section| if (section.kind == .markdown) {
        const rdoc = try self.render_sdoc(section.sdoc);
        self.allocator.free(section.rdoc.raw.bytes);
        section.rdoc = rdoc;
    };
    try self.relayout();
}

fn target_width(self: *const Self) usize {
    return if (self.widget_type == .info_box)
        tui.config().info_box_width_limit
    else if (self.view_cols > 0)
        self.view_cols
    else
        tui.screen().w;
}

fn relayout(self: *Self) !void {
    self.layout.reset();
    const width = @max(1, self.target_width());
    self.layout_width = width;
    const tab_width = tui.config().tab_width;
    for (self.sections.items) |section| switch (section.kind) {
        .plaintext => try self.layout_plaintext(section.text, width, tab_width),
        .markdown => try richdoc.render.to_layout(&self.layout, section.rdoc, &self.plane, .{
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

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (!std.mem.eql(u8, self.theme_name, theme.name) and self.has_markdown()) self.restyle() catch {};
    self.plane.set_base_style(if (tui.config().hover_info_mode == .box) theme.editor_widget else theme.panel);
    self.plane.erase();
    self.plane.home();
    richdoc.render.to_plane(&self.layout, &self.plane, self.top, self.view_rows, self.plane.style);
    return false;
}

fn has_markdown(self: *const Self) bool {
    for (self.sections.items) |section| if (section.kind == .markdown) return true;
    return false;
}
