const std = @import("std");
const cbor = @import("cbor");
const Allocator = @import("std").mem.Allocator;

const Plane = @import("renderer").Plane;
const tp = @import("thespian");
const log = @import("log");
const root = @import("soft_root").root;
const command = @import("command");
const EventHandler = @import("EventHandler");
const keybind = @import("keybind");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const Tabs = @import("status/tabs.zig");
const WidgetList = @import("WidgetList.zig");
const Menu = @import("Menu.zig");
const Button = @import("Button.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const editor = @import("editor.zig");
const FileList = @import("FileList.zig");

pub const name = @typeName(Self);

const Self = @This();
const Commands = command.Collection(cmds);

pub const Entry = FileList.Entry;
pub const ActivateMode = FileList.ActivateMode;

allocator: std.mem.Allocator,
plane: Plane,
menu: *MenuType,
logger: log.Logger,
commands: Commands = undefined,
input_mode: keybind.Mode,

manager: ?*FileList.Manager = null,
focused: bool = false,
activate: ActivateMode = .normal,
view_rows: usize = 0,
view_cols: usize = 0,
box: Widget.Box = .{},
tabs: *WidgetList,
tabs_hash: u64 = 0,
tab_style: Tabs.Style,
tab_style_bufs: [][]const u8,

const MenuType = Menu.Options(*Self).MenuType;
const ButtonType = MenuType.ButtonType;
const FilelistTabType = Button.Options(FilelistTab).ButtonType;
const path_column_ratio = 4;
const widget_type: Widget.Type = .panel;

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var plane = try Plane.init(&(Widget.Box{}).opts(name), parent);
    errdefer plane.deinit();

    var input_mode = try keybind.mode("filelist", allocator, .{ .insert_command = "do_nothing" });
    errdefer input_mode.deinit();

    const tabs = try WidgetList.createH(allocator, plane, "filelist.tabs", .dynamic);
    errdefer tabs.deinit(allocator);

    const tab_style, const tab_style_bufs = root.read_config(Tabs.Style, allocator);

    const menu = try Menu.create(*Self, allocator, plane, .{
        .ctx = self,
        .style = widget_type,
        .on_render = handle_render_menu,
        .on_scroll = EventHandler.bind(self, Self.handle_scroll),
        .on_click4 = mouse_click_button4,
        .on_click5 = mouse_click_button5,
    });
    errdefer menu.widget().deinit(allocator);

    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .logger = log.logger(@typeName(Self)),
        .input_mode = input_mode,
        .tabs = tabs,
        .menu = menu,
        .tab_style = tab_style,
        .tab_style_bufs = tab_style_bufs,
    };
    if (self.menu.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_style;
    self.tabs.ctx = self;
    self.tabs.on_render = render_tab_bar;
    self.tabs.render_decoration = null;
    try self.commands.init(self);
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.focused) tui.release_keyboard_focus(Widget.to(self));
    root.free_config(self.allocator, self.tab_style_bufs);
    self.input_mode.deinit();
    self.menu.widget().deinit(allocator);
    self.tabs.deinit(allocator);
    self.plane.deinit();
    self.commands.deinit();
    allocator.destroy(self);
}

pub fn attach(self: *Self, manager: *FileList.Manager) void {
    self.manager = manager;
    self.rebuild_menu();
}

fn active_list(self: *Self) ?*FileList {
    return if (self.manager) |m| m.active() else null;
}

fn scrollbar_style(sb: *scrollbar_v, theme: *const Widget.Theme) Widget.Theme.Style {
    return if (sb.active)
        .{ .fg = theme.scrollbar_active.fg, .bg = theme.panel.bg }
    else if (sb.hover)
        .{ .fg = theme.scrollbar_hover.fg, .bg = theme.panel.bg }
    else
        .{ .fg = theme.scrollbar.fg, .bg = theme.panel.bg };
}

fn menu_area(self: *Self) Widget.Box {
    var b = self.box;
    if (b.h > 0) {
        b.y += 1;
        b.h -= 1;
    }
    return b;
}

fn tab_area(self: *Self) Widget.Box {
    var b = self.box;
    b.h = @min(b.h, 1);
    return b;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    const padding = tui.get_widget_style(widget_type).padding;
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.box = pos;
    self.reparent_children();
    self.tabs.resize(self.tab_area());
    const menu_box = self.menu_area();
    self.menu.container.resize(menu_box);
    const client_box = menu_box.to_client_box(padding);
    self.view_rows = client_box.h;
    self.view_cols = client_box.w;
    self.update_scrollbar();
}

fn reparent_children(self: *Self) void {
    for ([_]*Plane{ &self.tabs.plane, &self.menu.container.plane }) |p| {
        p.layer = self.plane.layer;
        p.window.screen = self.plane.window.screen;
    }
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (f(walk_ctx, Widget.to(self), .begin)) return true;
    return self.tabs.walk(walk_ctx, f) or
        self.menu.container_widget.walk(walk_ctx, f) or
        f(walk_ctx, Widget.to(self), .end);
}

fn rebuild_menu(self: *Self) void {
    self.menu.reset_items();
    self.menu.selected = null;
    if (self.active_list()) |fl| {
        for (0..fl.entries.items.len) |i| {
            var label: std.Io.Writer.Allocating = .init(self.allocator);
            defer label.deinit();
            cbor.writeValue(&label.writer, i) catch continue;
            self.menu.add_item_with_handler(label.written(), handle_menu_action) catch continue;
        }
        self.menu.resize(self.menu_area());
        self.update_selected();
    }
    self.update_scrollbar();
}

fn append_button(self: *Self) void {
    const fl = self.active_list() orelse return;
    if (fl.entries.items.len == 0) return;
    const idx = fl.entries.items.len - 1;
    var label: std.Io.Writer.Allocating = .init(self.allocator);
    defer label.deinit();
    cbor.writeValue(&label.writer, idx) catch return;
    self.menu.add_item_with_handler(label.written(), handle_menu_action) catch return;
    self.menu.resize(self.menu_area());
    self.update_scrollbar();
}

pub fn handle_filelist_event(self: *Self, event: FileList.Event) void {
    switch (event) {
        .none => tui.need_render(@src()),
        .rebuild => self.rebuild_menu(),
        .append_one => self.append_button(),
    }
}

pub fn refresh_if_active(self: *Self, list_name: []const u8) void {
    if (self.manager) |m| if (m.active()) |active|
        if (std.mem.eql(u8, active.name, list_name)) self.rebuild_menu();
}

pub fn refresh(self: *Self) void {
    self.rebuild_menu();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    self.sync_tabs();
    _ = self.tabs.render(theme);
    return self.menu.container_widget.render(theme);
}

const FilelistTab = struct {
    ctx: *Self,
    name: []const u8,
    close_pos: ?i32 = null,

    const Mode = enum { inactive, active, selected };

    fn is_active(t: *FilelistTab) bool {
        const m = t.ctx.manager orelse return false;
        const active = m.active() orelse return false;
        return std.mem.eql(u8, active.name, t.name);
    }

    fn label(t: *FilelistTab) []const u8 {
        const m = t.ctx.manager orelse return t.name;
        const fl = m.get(t.name) orelse return t.name;
        return fl.label;
    }

    fn render(t: *FilelistTab, plane: *Plane, theme: *const Widget.Theme, hover: bool) void {
        const active = t.is_active();
        const mode: Mode = if (hover) .selected else if (active) .active else .inactive;
        switch (mode) {
            .selected => t.render_selected(plane, hover, theme, active),
            .active => if (t.ctx.focused)
                t.render_active(plane, hover, theme)
            else
                t.render_unfocused_active(plane, hover, theme),
            .inactive => if (t.ctx.focused)
                t.render_inactive(plane, hover, theme)
            else
                t.render_unfocused_inactive(plane, hover, theme),
        }
    }

    fn render_selected(t: *FilelistTab, plane: *Plane, hover: bool, theme: *const Widget.Theme, active: bool) void {
        const s = &t.ctx.tab_style;
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = s.inactive_fg.from_theme(theme),
            .bg = s.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();
        if (active) {
            plane.set_style(.{
                .fg = s.selected_fg.from_theme(theme),
                .bg = s.selected_bg.from_theme(theme),
            });
            plane.fill(" ");
            plane.home();
        }

        plane.set_style(.{
            .fg = s.selected_left_fg.from_theme(theme),
            .bg = s.selected_left_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.selected_left, s.selected_left_fg_transparent, .normal);

        plane.set_style(.{
            .fg = s.selected_fg.from_theme(theme),
            .bg = s.selected_bg.from_theme(theme),
        });
        t.render_content(plane, hover, s.selected_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = s.selected_right_fg.from_theme(theme),
            .bg = s.selected_right_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.selected_right, s.selected_right_fg_transparent, .normal);
    }

    fn render_active(t: *FilelistTab, plane: *Plane, hover: bool, theme: *const Widget.Theme) void {
        const s = &t.ctx.tab_style;
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = s.inactive_fg.from_theme(theme),
            .bg = s.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();
        plane.set_style(.{
            .fg = s.active_fg.from_theme(theme),
            .bg = s.active_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();

        plane.set_style(.{
            .fg = s.active_left_fg.from_theme(theme),
            .bg = s.active_left_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.active_left, s.active_left_fg_transparent, .normal);

        plane.set_style(.{
            .fg = s.active_fg.from_theme(theme),
            .bg = s.active_bg.from_theme(theme),
        });
        t.render_content(plane, hover, s.active_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = s.active_right_fg.from_theme(theme),
            .bg = s.active_right_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.active_right, s.active_right_fg_transparent, .normal);
    }

    fn render_inactive(t: *FilelistTab, plane: *Plane, hover: bool, theme: *const Widget.Theme) void {
        const s = &t.ctx.tab_style;
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = s.inactive_fg.from_theme(theme),
            .bg = s.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();

        plane.set_style(.{
            .fg = s.inactive_left_fg.from_theme(theme),
            .bg = s.inactive_left_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.inactive_left, s.inactive_left_fg_transparent, .normal);

        plane.set_style(.{
            .fg = s.inactive_fg.from_theme(theme),
            .bg = s.inactive_bg.from_theme(theme),
        });
        t.render_content(plane, hover, s.inactive_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = s.inactive_right_fg.from_theme(theme),
            .bg = s.inactive_right_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.inactive_right, s.inactive_right_fg_transparent, .normal);
    }

    fn render_unfocused_active(t: *FilelistTab, plane: *Plane, hover: bool, theme: *const Widget.Theme) void {
        const s = &t.ctx.tab_style;
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = s.inactive_fg.from_theme(theme),
            .bg = s.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();
        plane.set_style(.{
            .fg = s.active_fg.from_theme(theme),
            .bg = s.active_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();

        plane.set_style(.{
            .fg = s.unfocused_active_left_fg.from_theme(theme),
            .bg = s.unfocused_active_left_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.unfocused_active_left, s.unfocused_active_left_fg_transparent, .normal);

        plane.set_style(.{
            .fg = s.unfocused_active_fg.from_theme(theme),
            .bg = s.unfocused_active_bg.from_theme(theme),
        });
        t.render_content(plane, hover, s.unfocused_active_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = s.unfocused_active_right_fg.from_theme(theme),
            .bg = s.unfocused_active_right_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.unfocused_active_right, s.unfocused_active_right_fg_transparent, .normal);
    }

    fn render_unfocused_inactive(t: *FilelistTab, plane: *Plane, hover: bool, theme: *const Widget.Theme) void {
        const s = &t.ctx.tab_style;
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = s.inactive_fg.from_theme(theme),
            .bg = s.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();

        plane.set_style(.{
            .fg = s.unfocused_inactive_left_fg.from_theme(theme),
            .bg = s.unfocused_inactive_left_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.unfocused_inactive_left, s.unfocused_inactive_left_fg_transparent, .normal);

        plane.set_style(.{
            .fg = s.unfocused_inactive_fg.from_theme(theme),
            .bg = s.unfocused_inactive_bg.from_theme(theme),
        });
        t.render_content(plane, hover, s.unfocused_inactive_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = s.unfocused_inactive_right_fg.from_theme(theme),
            .bg = s.unfocused_inactive_right_bg.from_theme(theme),
        });
        Tabs.put_glyph(plane, s.unfocused_inactive_right, s.unfocused_inactive_right_fg_transparent, .normal);
    }

    fn render_content(t: *FilelistTab, plane: *Plane, hover: bool, fg: ?Widget.Theme.Color, theme: *const Widget.Theme) void {
        const s = &t.ctx.tab_style;
        t.render_padding(plane, .left);
        _ = plane.putstr(t.label()) catch {};
        _ = plane.putstr(" ") catch {};
        t.close_pos = null;
        if (hover) {
            plane.set_style(.{ .fg = s.close_icon_fg.from_theme(theme) });
            t.close_pos = plane.cursor_x();
            Tabs.put_glyph(plane, s.close_icon, s.close_icon_fg_transparent, .normal);
        } else {
            if (s.clean_indicator_fg) |color|
                plane.set_style(.{ .fg = color.from_theme(theme) });
            Tabs.put_glyph(plane, s.clean_indicator, s.clean_indicator_fg_transparent, .normal);
        }
        plane.set_style(.{ .fg = fg });
        t.render_padding(plane, .right);
    }

    fn render_padding(t: *FilelistTab, plane: *Plane, side: enum { left, right }) void {
        const s = &t.ctx.tab_style;
        var padding: usize = switch (side) {
            .left => s.padding_left,
            .right => s.padding_right,
        };
        const old_fgt = plane.style.glyph_alpha_from_bg;
        defer plane.style.glyph_alpha_from_bg = old_fgt;
        plane.style.glyph_alpha_from_bg = s.padding_fg_transparent;
        while (padding > 0) : (padding -= 1) _ = plane.putstr(s.padding) catch {};
    }

    fn layout(t: *FilelistTab, btn: *FilelistTabType) Widget.Layout {
        const s = &t.ctx.tab_style;
        const plane = btn.plane;
        const len = plane.egc_chunk_width(t.label(), 0, 1);
        const len_padding = plane.egc_chunk_width(s.padding, 0, 1) * (s.padding_left + s.padding_right) +
            @max(
                plane.egc_chunk_width(s.close_icon, 0, 1),
                plane.egc_chunk_width(s.clean_indicator, 0, 1),
            ) + 1 + // +1 for the leading space
            if (t.is_active())
                plane.egc_chunk_width(s.active_left, 0, 1) +
                    plane.egc_chunk_width(s.active_right, 0, 1)
            else
                plane.egc_chunk_width(s.inactive_left, 0, 1) +
                    plane.egc_chunk_width(s.inactive_right, 0, 1);
        return .{ .static = len + len_padding };
    }
};

fn render_tab_bar(ctx: ?*anyopaque, theme: *const Widget.Theme) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    const plane = &self.tabs.plane;
    plane.set_base_style(theme.editor);
    plane.erase();
    plane.home();
    plane.set_style(.{
        .fg = self.tab_style.bar_fg.from_theme(theme),
        .bg = self.tab_style.bar_bg.from_theme(theme),
    });
    plane.fill(" ");
    plane.home();
}

fn hash_tabs(self: *Self) u64 {
    var h = std.hash.Wyhash.init(0);
    if (self.manager) |m| for (m.lists.values()) |fl| if (!fl.is_empty()) {
        h.update(fl.name);
        h.update(&[_]u8{0});
    };
    return h.final();
}

fn sync_tabs(self: *Self) void {
    const hash = self.hash_tabs();
    if (hash == self.tabs_hash) return;
    self.tabs_hash = hash;
    self.rebuild_tabs();
}

fn rebuild_tabs(self: *Self) void {
    self.tabs.remove_all();
    if (self.manager) |m| for (m.lists.values()) |fl| {
        if (fl.is_empty()) continue;
        const w = Button.create_widget(FilelistTab, self.allocator, self.plane, .{
            .ctx = .{ .ctx = self, .name = fl.name },
            .label = fl.name,
            .on_click = handle_tab_click,
            .on_render = handle_tab_render,
            .on_layout = handle_tab_layout,
        }) catch continue;
        self.tabs.add(w) catch {
            w.deinit(self.allocator);
            continue;
        };
    };
    self.tabs.resize(self.tab_area());
}

fn handle_tab_layout(ctx: *FilelistTab, btn: *FilelistTabType) Widget.Layout {
    return ctx.layout(btn);
}

fn handle_tab_render(ctx: *FilelistTab, button: *FilelistTabType, theme: *const Widget.Theme) bool {
    ctx.render(&button.plane, theme, button.hover);
    return false;
}

fn handle_tab_click(ctx: *FilelistTab, _: *FilelistTabType, pos: Widget.Pos) void {
    const t = ctx;
    const self = t.ctx;
    if (t.close_pos) |close_pos| if (pos.x == close_pos) {
        tp.self_pid().send(.{ "cmd", "filelist_close", .{t.name} }) catch |e| self.logger.err(name, e);
        return;
    };
    if (self.manager) |m| {
        m.set_active(t.name);
        self.rebuild_menu();
    }
    self.focus();
    tui.need_render(@src());
}

fn handle_render_menu(self: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    const fl = self.active_list() orelse return false;
    const view_pos = fl.view_pos;
    const style_base = theme.panel;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.panel;
    const style_hint: Widget.Theme.Style = .{ .fg = theme.editor_hint.fg, .fs = theme.editor_hint.fs, .bg = style_label.bg };
    const style_information: Widget.Theme.Style = .{ .fg = theme.editor_information.fg, .fs = theme.editor_information.fs, .bg = style_label.bg };
    const style_warning: Widget.Theme.Style = .{ .fg = theme.editor_warning.fg, .fs = theme.editor_warning.fs, .bg = style_label.bg };
    const style_error: Widget.Theme.Style = .{ .fg = theme.editor_error.fg, .fs = theme.editor_error.fs, .bg = style_label.bg };
    const style_separator: Widget.Theme.Style = .{ .fg = theme.editor_selection.bg, .bg = style_label.bg };
    var idx: usize = undefined;
    var iter = button.opts.label; // label contains cbor, just the index
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch false)) {
        const json = cbor.toJsonAlloc(self.allocator, iter) catch return false;
        defer self.allocator.free(json);
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return false;
    }
    idx += view_pos;
    if (idx >= fl.entries.items.len) {
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
    const entry = &fl.entries.items[idx];
    button.plane.set_style(style_label);
    tui.render_pointer(&button.plane, selected);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var removed_prefix: usize = 0;
    const max_len = self.view_cols / path_column_ratio;
    _ = button.plane.print("{s}:{d}", .{ root.shorten_path(&buf, entry.path, &removed_prefix, max_len - 7), entry.begin_line + 1 }) catch {};
    button.plane.cursor_move_yx(0, @intCast(max_len));
    button.plane.set_style(style_separator);
    _ = button.plane.print(" ▏", .{}) catch {};
    switch (entry.severity) {
        .Hint => button.plane.set_style(style_hint),
        .Information => button.plane.set_style(style_information),
        .Warning => button.plane.set_style(style_warning),
        .Error => button.plane.set_style(style_error),
    }
    const tab_width = tui.config().tab_width;
    const show_tabs_visual = switch (tui.config().whitespace_mode) {
        .tabs, .external, .visible, .full => true,
        else => false,
    };
    var codepoints = (std.unicode.Utf8View.init(entry.lines) catch std.unicode.Utf8View.initUnchecked(entry.lines)).iterator();
    while (codepoints.nextCodepointSlice()) |codepoint| {
        const cp = std.unicode.utf8Decode(codepoint) catch {
            for (codepoint) |b| _ = button.plane.print("\\x{x:0>2}", .{b}) catch {};
            continue;
        };
        switch (cp) {
            '\t' => {
                const col: usize = @intCast(button.plane.cursor_x());
                const spaces = tab_width - (col % tab_width);
                if (show_tabs_visual) {
                    button.plane.set_style(.{ .fg = theme.editor_whitespace.fg, .bg = style_label.bg });
                    for (0..spaces) |i|
                        _ = button.plane.putstr(if (i < spaces - 1) editor.whitespace.char.tab_begin else editor.whitespace.char.tab_end) catch {};
                    button.plane.set_style(style_label);
                } else {
                    for (0..spaces) |_| _ = button.plane.putstr(" ") catch {};
                }
            },
            0x00...0x08, 0x0a...0x1f, 0x7f => _ = button.plane.print("\\x{x:0>2}", .{cp}) catch {},
            else => _ = button.plane.putstr(codepoint) catch {},
        }
    }
    return false;
}

fn handle_scroll(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!void {
    const fl = self.active_list() orelse return;
    _ = try m.match(.{ "scroll_to", tp.extract(&fl.view_pos) });
    self.update_selected();
}

fn update_scrollbar(self: *Self) void {
    const scrollbar = self.menu.scrollbar orelse return;
    if (self.active_list()) |fl|
        scrollbar.set(@intCast(fl.entries.items.len), @intCast(self.view_rows), @intCast(fl.view_pos))
    else
        scrollbar.set(0, @intCast(self.view_rows), 0);
}

fn mouse_click_button4(menu: **MenuType, _: *ButtonType, _: Widget.Pos) void {
    const self = &menu.*.opts.ctx.*;
    const fl = self.active_list() orelse return;
    fl.selected = if (self.menu.selected) |sel_| sel_ + fl.view_pos else fl.selected;
    if (fl.view_pos < Menu.scroll_lines) {
        fl.view_pos = 0;
    } else {
        fl.view_pos -= Menu.scroll_lines;
    }
    self.update_selected();
    self.update_scrollbar();
}

fn mouse_click_button5(menu: **MenuType, _: *ButtonType, _: Widget.Pos) void {
    const self = &menu.*.opts.ctx.*;
    const fl = self.active_list() orelse return;
    fl.selected = if (self.menu.selected) |sel_| sel_ + fl.view_pos else fl.selected;
    if (fl.view_pos < @max(fl.entries.items.len, self.view_rows) - self.view_rows)
        fl.view_pos += Menu.scroll_lines;
    self.update_selected();
    self.update_scrollbar();
}

fn update_selected(self: *Self) void {
    const fl = self.active_list() orelse return;
    if (fl.selected) |sel| {
        if (sel >= fl.view_pos and sel < fl.view_pos + self.view_rows) {
            self.menu.selected = sel - fl.view_pos;
        } else {
            self.menu.selected = null;
        }
    }
}

fn handle_menu_action(menu: **MenuType, button: *ButtonType, _: Widget.Pos) void {
    const self = menu.*.opts.ctx;
    const fl = self.active_list() orelse return;
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch return)) {
        const json = cbor.toJsonAlloc(self.allocator, button.opts.label) catch return;
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return;
    }
    idx += fl.view_pos;
    if (idx >= fl.entries.items.len) return;
    fl.selected = idx;
    self.update_selected();
    const entry = &fl.entries.items[idx];

    const cmd_ = switch (self.activate) {
        .normal => "navigate",
        .alternate => "navigate_split_vertical",
    };
    self.activate = .normal; // reset transient mode after use

    tp.self_pid().send(.{ "cmd", cmd_, .{
        .file = entry.path,
        .goto = .{
            entry.end_line + 1,
            entry.end_pos + 2,
            entry.begin_line,
            if (entry.begin_pos == 0) 0 else entry.begin_pos + 1,
            entry.end_line,
            entry.end_pos + 1,
            entry.pos_type,
        },
    } }) catch |e| self.logger.err("navigate", e);
}

fn select_next(self: *Self, dir: enum { up, down, page_up, page_down, home, end }) void {
    const fl = self.active_list() orelse return;
    if (fl.entries.items.len == 0) return;
    fl.selected = if (self.menu.selected) |sel_| sel_ + fl.view_pos else fl.selected;
    const sel_ = fl.selected orelse 0;
    const sel = switch (dir) {
        .up => if (sel_ > 0) sel_ - 1 else fl.entries.items.len - 1,
        .down => if (sel_ < fl.entries.items.len - 1) sel_ + 1 else 0,
        .page_up => sel_ -| self.view_rows,
        .page_down => @min(sel_ + self.view_rows, fl.entries.items.len - 1),
        .home => 0,
        .end => fl.entries.items.len - 1,
    };
    fl.selected = sel;
    if (sel < fl.view_pos) fl.view_pos = sel;
    if (sel > fl.view_pos + self.view_rows - 1) fl.view_pos = sel - @min(sel, self.view_rows - 1);
    self.update_selected();
    self.update_scrollbar();
}

fn switch_filelist(self: *Self, dir: FileList.Direction) void {
    const manager = self.manager orelse return;
    const next = manager.next(manager.active(), dir) orelse return;
    manager.set_active(next.name);
    self.rebuild_menu();
    tui.need_render(@src());
}

fn close_list(self: *Self, list_name: []const u8) void {
    const manager = self.manager orelse return;
    manager.clear(list_name);
    if (manager.refresh_active()) {
        self.rebuild_menu();
        tui.need_render(@src());
    } else {
        command.executeName("hide_filelist", .empty()) catch |e| self.logger.err(name, e);
    }
}

pub fn focus(self: *Self) void {
    if (self.focused) return;
    self.focused = true;
    if (tui.mini_mode() != null)
        command.executeName("exit_mini_mode", .empty()) catch {};
    if (tui.input_mode_outer() != null)
        command.executeName("exit_overlay_mode", .empty()) catch {};
    tui.set_keyboard_focus(Widget.to(self));
    tui.need_render(@src());
}

pub fn unfocus(self: *Self) void {
    if (!self.focused) return;
    self.focused = false;
    tui.release_keyboard_focus(Widget.to(self));
    tui.need_render(@src());
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (!self.focused) return false;
    if (!try m.match(.{ "I", tp.more })) return false;
    if (try self.input_mode.bindings.receive(from, m)) return true;
    return true; // swallow unhandled input while focused
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

    pub fn select_prev_page(self: *Self, _: Ctx) Result {
        self.select_next(.page_up);
    }
    pub const select_prev_page_meta: Meta = .{ .description = "Select previous page in the file list" };

    pub fn select_next_page(self: *Self, _: Ctx) Result {
        self.select_next(.page_down);
    }
    pub const select_next_page_meta: Meta = .{ .description = "Select next page in the file list" };

    pub fn select_home(self: *Self, _: Ctx) Result {
        self.select_next(.home);
    }
    pub const select_home_meta: Meta = .{ .description = "Select top of the file list" };

    pub fn select_end(self: *Self, _: Ctx) Result {
        self.select_next(.end);
    }
    pub const select_end_meta: Meta = .{ .description = "Select end of the file list" };

    pub fn goto_selected_file(self: *Self, _: Ctx) Result {
        if (self.menu.selected == null) return tp.exit_error(error.NoSelectedFile, @errorReturnTrace());
        self.menu.activate_selected();
    }
    pub const goto_selected_file_meta: Meta = .{};

    pub fn goto_selected_file_alternate(self: *Self, _: Ctx) Result {
        if (self.menu.selected == null) return tp.exit_error(error.NoSelectedFile, @errorReturnTrace());
        self.activate = .alternate;
        self.menu.activate_selected();
    }
    pub const goto_selected_file_alternate_meta: Meta = .{};

    pub fn filelist_next(self: *Self, _: Ctx) Result {
        self.switch_filelist(.forwards);
    }
    pub const filelist_next_meta: Meta = .{ .description = "Select next file list" };

    pub fn filelist_prev(self: *Self, _: Ctx) Result {
        self.switch_filelist(.backwards);
    }
    pub const filelist_prev_meta: Meta = .{ .description = "Select previous file list" };

    pub fn unfocus_filelist(self: *Self, _: Ctx) Result {
        self.unfocus();
    }
    pub const unfocus_filelist_meta: Meta = .{ .description = "Return focus from the file list" };

    pub fn filelist_close(self: *Self, ctx: Ctx) Result {
        var list_name: []const u8 = undefined;
        if (ctx.args.buf.len > 0 and try ctx.args.match(.{tp.extract(&list_name)}))
            return self.close_list(list_name);
        const manager = self.manager orelse return;
        const fl = manager.active() orelse return;
        self.close_list(fl.name);
    }
    pub const filelist_close_meta: Meta = .{ .description = "Close file list" };
};
