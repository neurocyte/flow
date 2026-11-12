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
const ListBox = @import("ListBox.zig");
const scrollbar_v = @import("scrollbar_v.zig");
const editor = @import("editor.zig");
const FileList = @import("FileList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const Scroller = @import("Scroller.zig");

pub const name = @typeName(Self);

const Self = @This();
const Commands = command.Collection(cmds);

pub const Entry = FileList.Entry;
pub const ActivateMode = FileList.ActivateMode;

allocator: std.mem.Allocator,
plane: Plane,
list_box: *ListBoxType,
logger: log.Logger,
commands: Commands = undefined,
current: bool = false,
panel_input: PanelInput,

manager: *FileList.Manager,
list_id: FileList.Id,
activate: ActivateMode = .normal,
view_rows: usize = 0,
view_cols: usize = 0,
box: Widget.Box = .{},
scroller: Scroller = .{ .pixel_offsets = true },

const ListBoxType = ListBox.Options(*Self).ListBoxType;
const ButtonType = ListBoxType.ButtonType;
const path_column_ratio = 4;
const widget_type: Widget.Type = .none;

pub const panel_tag = "filelist";

pub fn create(allocator: Allocator, parent: Plane, manager: *FileList.Manager, list_id: FileList.Id) !Panel {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var plane = try Plane.init(&(Widget.Box{}).opts(name), parent);
    errdefer plane.deinit();

    var panel_input = try PanelInput.init(allocator, "filelist");
    errdefer panel_input.mode.deinit();

    const list_box = try ListBox.create(*Self, allocator, plane, .{
        .ctx = self,
        .style = widget_type,
        .on_render = handle_render_list_box,
        .on_mouse = handle_list_mouse,
        .pixel_scroll = true,
    });
    errdefer list_box.widget().deinit(allocator);

    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .logger = log.logger(@typeName(Self)),
        .panel_input = panel_input,
        .list_box = list_box,
        .manager = manager,
        .list_id = list_id,
    };
    try self.scroller.attach_scrollbar(allocator, self.list_box.container, plane);
    self.list_box.container.render_decoration = null;
    self.commands.init_unregistered(self);
    self.rebuild_list_box();
    return Panel.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.panel_input.deinit(Widget.to(self));
    if (self.current) self.commands.unregister();
    self.list_box.widget().deinit(allocator);
    self.scroller.deinit();
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

pub fn panel_write_state(self: *Self, writer: *std.Io.Writer) error{WriteFailed}!void {
    try cbor.writeValue(writer, self.list_id);
}

pub fn panel_restore(allocator: Allocator, parent: Plane, state: []const u8) !Panel {
    var list_id: FileList.Id = undefined;
    if (!try cbor.match(state, cbor.extract(&list_id))) return error.InvalidFileListPanelState;
    const mv = tui.mainview() orelse return error.NoMainView;
    if (mv.filelists.get(list_id) == null) return error.FileListNotFound;
    return create(allocator, parent, &mv.filelists, list_id);
}

pub fn panel_copy(self: *Self) void {
    const fl = self.list() orelse return;
    const sel = fl.selected orelse return;
    if (sel >= fl.entries.items.len) return;
    const entry = fl.entries.items[sel];
    var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    PanelInput.copy_to_clipboard(std.fmt.bufPrint(&buf, "{s}:{d}", .{ entry.path, entry.begin_line + 1 }) catch return);
}

pub fn is_list(self: *Self, list_id: FileList.Id) bool {
    return self.list_id == list_id;
}

pub fn list(self: *Self) ?*FileList {
    return self.manager.get(self.list_id);
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    const padding = tui.get_widget_style(widget_type).padding;
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.box = pos;
    self.list_box.container.plane.layer = self.plane.layer;
    self.list_box.container.plane.window.screen = self.plane.window.screen;
    self.list_box.container.resize(self.box);
    const client_box = self.box.to_client_box(padding);
    self.view_rows = client_box.h;
    self.view_cols = client_box.w;
    self.scroller.set_view(client_box, &self.plane);
    self.scroller.set_content(self.entry_count());
}

fn entry_count(self: *Self) usize {
    return if (self.list()) |fl| fl.entries.items.len else 0;
}

pub fn update(self: *Self) void {
    const fl = self.list() orelse return;
    self.scroller.set_content(fl.entries.items.len);
    self.scroller.sync(fl.view_pos);
    self.scroller.update();
    if (self.scroller.take_owner_top()) |top| fl.view_pos = top;
    self.update_selected();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (f(walk_ctx, Widget.to(self), .begin)) return true;
    return self.list_box.container_widget.walk(walk_ctx, f) or
        f(walk_ctx, Widget.to(self), .end);
}

fn rebuild_list_box(self: *Self) void {
    self.list_box.reset_items();
    self.list_box.selected = null;
    if (self.list()) |fl| {
        for (0..fl.entries.items.len) |i| {
            var label: std.Io.Writer.Allocating = .init(self.allocator);
            defer label.deinit();
            cbor.writeValue(&label.writer, i) catch continue;
            self.list_box.add_item_with_handler(label.written(), handle_list_box_action) catch continue;
        }
        self.list_box.resize(self.box);
        self.update_selected();
    }
    self.scroller.set_content(self.entry_count());
}

fn append_button(self: *Self) void {
    const fl = self.list() orelse return;
    if (fl.entries.items.len == 0) return;
    const idx = fl.entries.items.len - 1;
    var label: std.Io.Writer.Allocating = .init(self.allocator);
    defer label.deinit();
    cbor.writeValue(&label.writer, idx) catch return;
    self.list_box.add_item_with_handler(label.written(), handle_list_box_action) catch return;
    self.list_box.resize(self.box);
    self.scroller.set_content(self.entry_count());
}

pub fn handle_filelist_event(self: *Self, event: FileList.Event) void {
    switch (event) {
        .none => {},
        .rebuild => self.rebuild_list_box(),
        .append_one => self.append_button(),
    }
    tui.need_render(@src());
}

pub fn refresh(self: *Self) void {
    self.rebuild_list_box();
    tui.need_render(@src());
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(theme.panel);
    self.plane.erase();
    self.plane.home();
    const more = self.scroller.render();
    self.list_box.set_scroll(self.scroller.pos(), self.scroller.draw_rows(), self.scroller.view_px());
    return self.list_box.container_widget.render(theme) or more;
}

fn handle_render_list_box(self: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
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
    const style_severity = switch (entry.severity) {
        .Hint => style_hint,
        .Information => style_information,
        .Warning => style_warning,
        .Error => style_error,
    };
    button.plane.set_style(style_severity);
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
            '\n' => {
                button.plane.set_style(style_separator);
                _ = button.plane.putstr(" ⏎ ") catch {};
                button.plane.set_style(style_severity);
            },
            0x00...0x08, 0x0b...0x1f, 0x7f => _ = button.plane.print("\\x{x:0>2}", .{cp}) catch {},
            else => _ = button.plane.putstr(codepoint) catch {},
        }
    }
    return false;
}

fn handle_list_mouse(self: *Self, m: tp.message) error{Exit}!bool {
    return self.scroller.receive_mouse(m);
}

fn update_selected(self: *Self) void {
    const fl = self.list() orelse return;
    const sel = fl.selected orelse return;
    self.list_box.selected = if (sel >= fl.view_pos and sel < fl.view_pos + self.scroller.draw_rows())
        sel - fl.view_pos
    else
        null;
}

fn handle_list_box_action(list_box: **ListBoxType, button: *ButtonType, _: Widget.Pos) void {
    const self = list_box.*.opts.ctx;
    const fl = self.list() orelse return;
    var idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchValue(&iter, cbor.extract(&idx)) catch return)) {
        const json = cbor.toJsonAlloc(self.allocator, button.opts.label) catch return;
        self.logger.print_err(name, "invalid table entry: {s}", .{json});
        return;
    }
    self.activate_entry(idx + fl.view_pos);
}

fn activate_entry(self: *Self, idx: usize) void {
    const fl = self.list() orelse return;
    if (idx >= fl.entries.items.len) return;
    fl.selected = idx;
    self.update_selected();
    const entry = &fl.entries.items[idx];

    const cmd_ = switch (self.activate) {
        .normal => "navigate",
        .alternate => "navigate_split_vertical",
    };
    self.activate = .normal; // reset transient mode after use

    if (entry.begin_line == entry.end_line and entry.begin_pos == entry.end_pos)
        tp.self_pid().send(.{ "cmd", cmd_, .{
            .file = entry.path,
            .goto = .{ entry.end_line + 1, entry.end_pos + 1, entry.pos_type },
        } }) catch |e| self.logger.err("navigate", e)
    else
        tp.self_pid().send(.{ "cmd", cmd_, .{
            .file = entry.path,
            .goto = .{
                entry.end_line + 1,
                entry.end_pos + 1,
                entry.begin_line,
                entry.begin_pos,
                entry.end_line,
                entry.end_pos,
                entry.pos_type,
            },
        } }) catch |e| self.logger.err("navigate", e);
}

fn select_next(self: *Self, dir: enum { up, down, page_up, page_down, home, end }) void {
    const fl = self.list() orelse return;
    if (fl.entries.items.len == 0) return;
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
    const rows = @max(1, self.scroller.view_rows());
    const top = self.scroller.dest();
    const new_top = if (sel < top) sel else if (sel >= top + rows) sel + 1 - rows else top;
    switch (dir) {
        .page_up, .page_down => self.scroller.glide_to(new_top),
        .up, .down, .home, .end => self.scroller.jump_to(new_top),
    }
    fl.view_pos = self.scroller.top();
    self.update_selected();
}

fn activate_selected(self: *Self) void {
    const fl = self.list() orelse return;
    self.activate_entry(fl.selected orelse return);
}

pub fn focus(self: *Self) void {
    self.panel_input.focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    self.panel_input.unfocus(Widget.to(self));
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try PanelInput.receive_mouse(self, m)) return true;
    return self.panel_input.receive(from, m);
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn goto_prev_file(self: *Self, _: Ctx) Result {
        self.select_next(.up);
        self.activate_selected();
    }
    pub const goto_prev_file_meta: Meta = .{ .description = "Go to previous" };

    pub fn goto_next_file(self: *Self, _: Ctx) Result {
        self.select_next(.down);
        self.activate_selected();
    }
    pub const goto_next_file_meta: Meta = .{ .description = "Go to next" };

    pub fn select_prev_file(self: *Self, _: Ctx) Result {
        self.select_next(.up);
    }
    pub const select_prev_file_meta: Meta = .{ .description = "Select previous" };

    pub fn select_next_file(self: *Self, _: Ctx) Result {
        self.select_next(.down);
    }
    pub const select_next_file_meta: Meta = .{ .description = "Select next" };

    pub fn select_prev_file_page(self: *Self, _: Ctx) Result {
        self.select_next(.page_up);
    }
    pub const select_prev_file_page_meta: Meta = .{ .description = "Select previous page" };

    pub fn select_next_file_page(self: *Self, _: Ctx) Result {
        self.select_next(.page_down);
    }
    pub const select_next_file_page_meta: Meta = .{ .description = "Select next page" };

    pub fn select_file_begin(self: *Self, _: Ctx) Result {
        self.select_next(.home);
    }
    pub const select_file_begin_meta: Meta = .{ .description = "Select top" };

    pub fn select_file_end(self: *Self, _: Ctx) Result {
        self.select_next(.end);
    }
    pub const select_file_end_meta: Meta = .{ .description = "Select end" };

    pub fn goto_selected_file(self: *Self, _: Ctx) Result {
        const fl = self.list() orelse return;
        if (fl.selected == null) return tp.exit_error(error.NoSelectedFile, @errorReturnTrace());
        self.activate_selected();
    }
    pub const goto_selected_file_meta: Meta = .{ .description = "Go to location" };

    pub fn goto_selected_file_alternate(self: *Self, _: Ctx) Result {
        const fl = self.list() orelse return;
        if (fl.selected == null) return tp.exit_error(error.NoSelectedFile, @errorReturnTrace());
        self.activate = .alternate;
        self.activate_selected();
    }
    pub const goto_selected_file_alternate_meta: Meta = .{ .description = "Go to location in split" };

    pub fn unfocus_filelist(self: *Self, _: Ctx) Result {
        if (tui.mainview()) |mv| if (mv.is_panel_maximized()) return;
        self.unfocus();
    }
    pub const unfocus_filelist_meta: Meta = .{ .description = "Return focus" };
};
