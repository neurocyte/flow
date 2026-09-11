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
const Menu = @import("Menu.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const editor = @import("editor.zig");
const FileList = @import("FileList.zig");
const Panel = @import("Panel.zig");

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
current: bool = false,
input_mode: keybind.Mode,

manager: *FileList.Manager,
list_id: FileList.Id,
focused: bool = false,
activate: ActivateMode = .normal,
view_rows: usize = 0,
view_cols: usize = 0,
box: Widget.Box = .{},

const MenuType = Menu.Options(*Self).MenuType;
const ButtonType = MenuType.ButtonType;
const path_column_ratio = 4;
const widget_type: Widget.Type = .none;

pub const panel_tag = "filelist";

pub fn create(allocator: Allocator, parent: Plane, manager: *FileList.Manager, list_id: FileList.Id) !Panel {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var plane = try Plane.init(&(Widget.Box{}).opts(name), parent);
    errdefer plane.deinit();

    var input_mode = try keybind.mode("filelist", allocator, .{ .insert_command = "do_nothing" });
    errdefer input_mode.deinit();

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
        .menu = menu,
        .manager = manager,
        .list_id = list_id,
    };
    if (self.menu.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_style;
    self.menu.container.render_decoration = null;
    self.commands.init_unregistered(self);
    self.rebuild_menu();
    return Panel.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.focused) tui.release_keyboard_focus(Widget.to(self));
    if (self.current) self.commands.unregister();
    self.input_mode.deinit();
    self.menu.widget().deinit(allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn panel_title(self: *Self) []const u8 {
    return if (self.list()) |fl| fl.label else "File list";
}

pub fn panel_icon(self: *Self) []const u8 {
    return FileList.icon_for(if (self.list()) |fl| fl.kind else .find_in_files);
}

pub fn panel_close(self: *Self) Panel.CloseResult {
    // closing the tab discards the list too
    tp.self_pid().send(.{ "cmd", "filelist_close", .{self.list_id} }) catch {};
    return .closed;
}

pub fn panel_set_current(self: *Self, current: bool) void {
    if (current == self.current) return;
    self.current = current;
    if (current)
        self.commands.register() catch |e| self.logger.err("register", e)
    else
        self.commands.unregister();
}

pub fn is_list(self: *Self, list_id: FileList.Id) bool {
    return self.list_id == list_id;
}

pub fn list(self: *Self) ?*FileList {
    return self.manager.get(self.list_id);
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
    const padding = tui.get_widget_style(widget_type).padding;
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.box = pos;
    self.menu.container.plane.layer = self.plane.layer;
    self.menu.container.plane.window.screen = self.plane.window.screen;
    self.menu.container.resize(self.box);
    const client_box = self.box.to_client_box(padding);
    self.view_rows = client_box.h;
    self.view_cols = client_box.w;
    self.update_scrollbar();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (f(walk_ctx, Widget.to(self), .begin)) return true;
    return self.menu.container_widget.walk(walk_ctx, f) or
        f(walk_ctx, Widget.to(self), .end);
}

fn rebuild_menu(self: *Self) void {
    self.menu.reset_items();
    self.menu.selected = null;
    if (self.list()) |fl| {
        for (0..fl.entries.items.len) |i| {
            var label: std.Io.Writer.Allocating = .init(self.allocator);
            defer label.deinit();
            cbor.writeValue(&label.writer, i) catch continue;
            self.menu.add_item_with_handler(label.written(), handle_menu_action) catch continue;
        }
        self.menu.resize(self.box);
        self.update_selected();
    }
    self.update_scrollbar();
}

fn append_button(self: *Self) void {
    const fl = self.list() orelse return;
    if (fl.entries.items.len == 0) return;
    const idx = fl.entries.items.len - 1;
    var label: std.Io.Writer.Allocating = .init(self.allocator);
    defer label.deinit();
    cbor.writeValue(&label.writer, idx) catch return;
    self.menu.add_item_with_handler(label.written(), handle_menu_action) catch return;
    self.menu.resize(self.box);
    self.update_scrollbar();
}

pub fn handle_filelist_event(self: *Self, event: FileList.Event) void {
    switch (event) {
        .none => tui.need_render(@src()),
        .rebuild => self.rebuild_menu(),
        .append_one => self.append_button(),
    }
}

pub fn refresh(self: *Self) void {
    self.rebuild_menu();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    return self.menu.container_widget.render(theme);
}

fn handle_render_menu(self: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    const fl = self.list() orelse return false;
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
    const fl = self.list() orelse return;
    _ = try m.match(.{ "scroll_to", tp.extract(&fl.view_pos) });
    self.update_selected();
}

fn update_scrollbar(self: *Self) void {
    const scrollbar = self.menu.scrollbar orelse return;
    if (self.list()) |fl|
        scrollbar.set(@intCast(fl.entries.items.len), @intCast(self.view_rows), @intCast(fl.view_pos))
    else
        scrollbar.set(0, @intCast(self.view_rows), 0);
}

fn mouse_click_button4(menu: **MenuType, _: *ButtonType, _: Widget.Pos) void {
    const self = &menu.*.opts.ctx.*;
    const fl = self.list() orelse return;
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
    const fl = self.list() orelse return;
    fl.selected = if (self.menu.selected) |sel_| sel_ + fl.view_pos else fl.selected;
    if (fl.view_pos < @max(fl.entries.items.len, self.view_rows) - self.view_rows)
        fl.view_pos += Menu.scroll_lines;
    self.update_selected();
    self.update_scrollbar();
}

fn update_selected(self: *Self) void {
    const fl = self.list() orelse return;
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
    const fl = self.list() orelse return;
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
    const fl = self.list() orelse return;
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

    pub fn select_prev_file_page(self: *Self, _: Ctx) Result {
        self.select_next(.page_up);
    }
    pub const select_prev_file_page_meta: Meta = .{ .description = "Select previous page in the file list" };

    pub fn select_next_file_page(self: *Self, _: Ctx) Result {
        self.select_next(.page_down);
    }
    pub const select_next_file_page_meta: Meta = .{ .description = "Select next page in the file list" };

    pub fn select_file_begin(self: *Self, _: Ctx) Result {
        self.select_next(.home);
    }
    pub const select_file_begin_meta: Meta = .{ .description = "Select top of the file list" };

    pub fn select_file_end(self: *Self, _: Ctx) Result {
        self.select_next(.end);
    }
    pub const select_file_end_meta: Meta = .{ .description = "Select end of the file list" };

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

    pub fn unfocus_filelist(self: *Self, _: Ctx) Result {
        self.unfocus();
    }
    pub const unfocus_filelist_meta: Meta = .{ .description = "Return focus from the file list" };
};
