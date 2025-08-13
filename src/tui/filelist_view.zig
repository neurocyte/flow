const std = @import("std");
const cbor = @import("cbor");
const Allocator = @import("std").mem.Allocator;

const Plane = @import("renderer").Plane;
const tp = @import("thespian");
const log = @import("log");
const root = @import("root");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Menu = @import("Menu.zig");
const Button = @import("Button.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const editor = @import("editor.zig");

pub const name = @typeName(Self);

const Self = @This();
const Commands = command.Collection(cmds);

allocator: std.mem.Allocator,
plane: Plane,
menu: *Menu.State(*Self),
logger: log.Logger,
commands: Commands = undefined,

items: usize = 0,
view_pos: usize = 0,
view_rows: usize = 0,
view_cols: usize = 0,
entries: std.ArrayList(Entry) = undefined,
selected: ?usize = null,
box: Widget.Box = .{},

const path_column_ratio = 4;
const widget_style_type: Widget.Style.Type = .panel;

const Entry = struct {
    path: []const u8,
    begin_line: usize,
    begin_pos: usize,
    end_line: usize,
    end_pos: usize,
    lines: []const u8,
    severity: editor.Diagnostic.Severity = .Information,
};

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .logger = log.logger(@typeName(Self)),
        .entries = std.ArrayList(Entry).init(allocator),
        .menu = try Menu.create(*Self, allocator, tui.plane(), .{
            .ctx = self,
            .style = widget_style_type,
            .on_render = handle_render_menu,
            .on_scroll = EventHandler.bind(self, Self.handle_scroll),
            .on_click4 = mouse_click_button4,
            .on_click5 = mouse_click_button5,
        }),
    };
    if (self.menu.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_style;
    try self.commands.init(self);
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.reset();
    self.plane.deinit();
    self.commands.deinit();
    allocator.destroy(self);
}

fn scrollbar_style(sb: *scrollbar_v, theme: *const Widget.Theme) Widget.Theme.Style {
    return if (sb.active)
        .{ .fg = theme.scrollbar_active.fg, .bg = theme.panel.bg }
    else if (sb.hover)
        .{ .fg = theme.scrollbar_hover.fg, .bg = theme.panel.bg }
    else
        .{ .fg = theme.scrollbar.fg, .bg = theme.panel.bg };
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    const padding = Widget.Style.from_type(widget_style_type).padding;
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.box = pos;
    self.menu.container.resize(self.box);
    const client_box = self.menu.container.to_client_box(pos, padding);
    self.view_rows = client_box.h;
    self.view_cols = client_box.w;
    self.update_scrollbar();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.menu.container_widget.walk(walk_ctx, f) or f(walk_ctx, w);
}

pub fn add_item(self: *Self, entry_: Entry) !void {
    const idx = self.entries.items.len;
    const entry = (try self.entries.addOne());
    entry.* = entry_;
    entry.path = try self.allocator.dupe(u8, entry_.path);
    entry.lines = try self.allocator.dupe(u8, entry_.lines);
    var label = std.ArrayList(u8).init(self.allocator);
    defer label.deinit();
    const writer = label.writer();
    cbor.writeValue(writer, idx) catch return;
    self.menu.add_item_with_handler(label.items, handle_menu_action) catch return;
    self.menu.resize(self.box);
    self.update_scrollbar();
}

pub fn reset(self: *Self) void {
    for (self.entries.items) |entry| {
        self.allocator.free(entry.path);
        self.allocator.free(entry.lines);
    }
    self.entries.clearRetainingCapacity();
    self.menu.reset_items();
    self.selected = null;
    self.menu.selected = null;
    self.view_pos = 0;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    return self.menu.container_widget.render(theme);
}

fn handle_render_menu(self: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = theme.panel;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.panel;
    const style_hint: Widget.Theme.Style = .{ .fg = theme.editor_hint.fg, .fs = theme.editor_hint.fs, .bg = style_label.bg };
    const style_information: Widget.Theme.Style = .{ .fg = theme.editor_information.fg, .fs = theme.editor_information.fs, .bg = style_label.bg };
    const style_warning: Widget.Theme.Style = .{ .fg = theme.editor_warning.fg, .fs = theme.editor_warning.fs, .bg = style_label.bg };
    const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs, .bg = style_label.bg };
    const style_separator: Widget.Theme.Style = .{ .fg = theme.editor_selection.bg, .bg = style_label.bg };
    // const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs, .bg = style_label.bg };
    var idx: usize = undefined;
    var iter = button.opts.label; // label contains cbor, just the index
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch false)) {
        const json = cbor.toJsonAlloc(self.allocator, iter) catch return false;
        defer self.allocator.free(json);
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return false;
    }
    idx += self.view_pos;
    if (idx >= self.entries.items.len) {
        return false;
    }
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        button.plane.fill(" ");
        button.plane.home();
    }
    const entry = &self.entries.items[idx];
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s} ", .{pointer}) catch {};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var removed_prefix: usize = 0;
    const max_len = self.view_cols / path_column_ratio;
    _ = button.plane.print("{s}:{d}", .{ root.shorten_path(&buf, entry.path, &removed_prefix, max_len - 7), entry.begin_line + 1 }) catch {};
    button.plane.cursor_move_yx(0, @intCast(max_len)) catch return false;
    button.plane.set_style(style_separator);
    _ = button.plane.print(" ▏", .{}) catch {};
    switch (entry.severity) {
        .Hint => button.plane.set_style(style_hint),
        .Information => button.plane.set_style(style_information),
        .Warning => button.plane.set_style(style_warning),
        .Error => button.plane.set_style(style_error),
    }
    _ = button.plane.print("{s}", .{std.fmt.fmtSliceEscapeLower(entry.lines)}) catch {};
    return false;
}

fn handle_scroll(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!void {
    _ = try m.match(.{ "scroll_to", tp.extract(&self.view_pos) });
    self.update_selected();
}

fn update_scrollbar(self: *Self) void {
    if (self.menu.scrollbar) |scrollbar|
        scrollbar.set(@intCast(self.entries.items.len), @intCast(self.view_rows), @intCast(self.view_pos));
}

fn mouse_click_button4(menu: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
    const self = &menu.*.opts.ctx.*;
    self.selected = if (self.menu.selected) |sel_| sel_ + self.view_pos else self.selected;
    if (self.view_pos < Menu.scroll_lines) {
        self.view_pos = 0;
    } else {
        self.view_pos -= Menu.scroll_lines;
    }
    self.update_selected();
    self.update_scrollbar();
}

fn mouse_click_button5(menu: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
    const self = &menu.*.opts.ctx.*;
    self.selected = if (self.menu.selected) |sel_| sel_ + self.view_pos else self.selected;
    if (self.view_pos < @max(self.entries.items.len, self.view_rows) - self.view_rows)
        self.view_pos += Menu.scroll_lines;
    self.update_selected();
    self.update_scrollbar();
}

fn update_selected(self: *Self) void {
    if (self.selected) |sel| {
        if (sel >= self.view_pos and sel < self.view_pos + self.view_rows) {
            self.menu.selected = sel - self.view_pos;
        } else {
            self.menu.selected = null;
        }
    }
}

fn handle_menu_action(menu: **Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
    const self = menu.*.opts.ctx;
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch return)) {
        const json = cbor.toJsonAlloc(self.allocator, button.opts.label) catch return;
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return;
    }
    idx += self.view_pos;
    if (idx >= self.entries.items.len) return;
    self.selected = idx;
    self.update_selected();
    const entry = &self.entries.items[idx];

    tp.self_pid().send(.{ "cmd", "navigate", .{
        .file = entry.path,
        .goto = .{
            entry.end_line + 1,
            entry.end_pos + 2,
            entry.begin_line,
            if (entry.begin_pos == 0) 0 else entry.begin_pos + 1,
            entry.end_line,
            entry.end_pos + 1,
        },
    } }) catch |e| self.logger.err("navigate", e);
}

fn select_next(self: *Self, dir: enum { up, down }) void {
    self.selected = if (self.menu.selected) |sel_| sel_ + self.view_pos else self.selected;
    const sel = switch (dir) {
        .up => if (self.selected) |sel_| if (sel_ > 0) sel_ - 1 else self.entries.items.len - 1 else self.entries.items.len - 1,
        .down => if (self.selected) |sel_| if (sel_ < self.entries.items.len - 1) sel_ + 1 else 0 else 0,
    };
    self.selected = sel;
    if (sel < self.view_pos) self.view_pos = sel;
    if (sel > self.view_pos + self.view_rows - 1) self.view_pos = sel - @min(sel, self.view_rows - 1);
    self.update_selected();
    self.update_scrollbar();
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn goto_prev_file(self: *Self, _: Ctx) Result {
        self.select_next(.up);
        self.menu.activate_selected();
    }
    pub const goto_prev_file_meta: Meta = .{ .description = "Navigate to previous file in the file list" };

    pub fn goto_next_file(self: *Self, _: Ctx) Result {
        self.select_next(.down);
        self.menu.activate_selected();
    }
    pub const goto_next_file_meta: Meta = .{ .description = "Navigate to next file in the file list" };

    pub fn select_prev_file(self: *Self, _: Ctx) Result {
        self.select_next(.up);
    }
    pub const select_prev_file_meta: Meta = .{ .description = "Select previous file in the file list" };

    pub fn select_next_file(self: *Self, _: Ctx) Result {
        self.select_next(.down);
    }
    pub const select_next_file_meta: Meta = .{ .description = "Select next file in the file list" };

    pub fn goto_selected_file(self: *Self, _: Ctx) Result {
        if (self.menu.selected == null) return tp.exit_error(error.NoSelectedFile, @errorReturnTrace());
        self.menu.activate_selected();
    }
    pub const goto_selected_file_meta: Meta = .{};
};
