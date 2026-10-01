const std = @import("std");
const build_options = @import("build_options");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const input = @import("input");
const MouseEvent = @import("MouseEvent");
const builtin = @import("builtin");

const Plane = @import("renderer").Plane;
const root = @import("soft_root").root;

const Widget = @import("Widget.zig");
const WidgetLayerBox = @import("WidgetLayerBox.zig");
const Button = @import("Button.zig");
const ListBox = @import("ListBox.zig");
const tui = @import("tui.zig");
const command = @import("command");
const keybind = @import("keybind");

const fonts = @import("fonts.zig");

pub const subtext_root = "I am groot!";

const style = struct {
    title: []const u8 = root.application_title,
    subtext: []const u8 = root.application_subtext,
    subtext_root: []const u8 = subtext_root,

    centered: bool = false,

    menu_commands: []const u8 = splice(if (build_options.gui)
        \\find_file
        \\create_new_file
        \\open_file
        \\open_recent_project
        \\find_in_files
        \\open_command_palette
        \\open_terminal
        \\run_task
        \\add_task
        \\open_config
        \\open_gui_config
        \\change_fontface
        \\open_keybind_config
        \\toggle_input_mode
        \\change_theme
        \\open_help
        \\open_version_info
        \\quit
    else
        \\find_file
        \\create_new_file
        \\open_file
        \\open_recent_project
        \\find_in_files
        \\open_command_palette
        \\open_terminal
        \\run_task
        \\add_task
        \\open_config
        \\open_keybind_config
        \\toggle_input_mode
        \\change_theme
        \\open_help
        \\open_version_info
        \\quit
    ),

    include_files: []const u8 = "",
};
pub const Style = style;

allocator: std.mem.Allocator,
plane: Plane,
parent: Plane,
info: *WidgetLayerBox,
fire: ?Fire = null,
commands: Commands = undefined,
focused: bool = false,
list_box: *ListBox.State(*Self),
list_box_w: usize = 0,
list_box_desc_w: usize = 0,
list_box_label_max: usize = 0,
list_box_desc_max: usize = 0,
list_box_count: usize = 0,
list_box_len: usize = 0,
max_desc_len: usize = 0,
list_box_items: std.ArrayList([]const u8) = .empty,
list_box_view_pos: usize = 0,
list_box_rows: usize = 0,
list_box_hidden: bool = true,
list_box_hints: bool = true,
input_namespace: []const u8,
root_mode: bool = false,

home_style: style,
home_style_bufs: [][]const u8,

const Self = @This();

const info_debug_text = "debug build";
const info_margin_cols: u16 = 2; // gap from the right edge
const info_margin_rows: u16 = 1; // gap above the status bar
const info_bottom_bar_rows: u16 = 1; // status bar height the info sits above

fn info_version() []const u8 {
    return root.version_number;
}

const widget_type: Widget.Type = .home;
const ListBoxType = ListBox.Options(*Self).ListBoxType;
const ButtonType = ListBoxType.ButtonType;

pub fn create(allocator: std.mem.Allocator, parent: Widget) !Widget {
    const logger = log.logger("home");
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    var n = try Plane.init(&(Widget.Box{}).opts("editor"), parent.plane.*);
    errdefer n.deinit();

    const info = try WidgetLayerBox.create(allocator, n, .{
        .name = "home.info",
        .placement = .bottom_right,
        .offset_x = info_margin_cols,
        .offset_y = info_margin_rows + info_bottom_bar_rows,
    });
    errdefer info.deinit(allocator);
    info.z_index = .main;
    info.blend = .src_over;
    info.alpha = 0x80;
    {
        const debug = builtin.mode == .Debug;
        const version = info_version();
        info.content_w = @intCast(if (debug) @max(version.len, info_debug_text.len) else version.len);
        info.content_h = if (debug) 2 else 1;
    }
    info.handle_resize(.{ .frame = tui.window_frame() });

    command.executeName("enter_mode", command.Context.fmt(.{"home"})) catch {};
    const keybind_mode = tui.get_keybind_mode() orelse @panic("no active keybind mode");
    const home_style, const home_style_bufs = root.read_config(style, allocator);

    const w = Widget.to(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent.plane.*,
        .plane = n,
        .info = info,
        .list_box = try ListBox.create(*Self, allocator, w.plane.*, .{
            .ctx = self,
            .style = widget_type,
            .on_render = list_box_on_render,
        }),
        .input_namespace = keybind.get_namespace(),
        .home_style = home_style,
        .home_style_bufs = home_style_bufs,
    };
    if (builtin.os.tag != .windows and std.c.geteuid() == 0) {
        self.root_mode = true;
    }
    self.commands.init_unregistered(self);
    var it = std.mem.splitAny(u8, self.home_style.menu_commands, "\n ");
    while (it.next()) |command_name| {
        const id = command.get_id(command_name) orelse {
            logger.print("{s} is not defined", .{command_name});
            continue;
        };
        const description = command.get_description(id) orelse {
            logger.print("{s} has no description", .{command_name});
            continue;
        };
        self.list_box_count += 1;
        var hints = std.mem.splitScalar(u8, keybind_mode.keybind_hints.get(command_name) orelse "", ',');
        const hint = hints.first();
        self.max_desc_len = @max(self.max_desc_len, description.len + hint.len + 5);
        self.list_box_desc_max = @max(self.list_box_desc_max, description.len);
        try self.add_menu_command(command_name, description, hint);
    }
    const padding = tui.get_widget_style(widget_type).padding;
    self.list_box_len = self.list_box_count + padding.top + padding.bottom;
    self.position_list_box(15, 9);
    return w;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    root.free_config(self.allocator, self.home_style_bufs);
    for (self.list_box_items.items) |item| self.allocator.free(item);
    self.list_box_items.deinit(self.allocator);
    self.list_box.widget().deinit(allocator);
    if (self.focused) self.commands.deinit();
    self.info.deinit(allocator);
    self.plane.deinit();
    if (self.fire) |*fire| fire.deinit();
    allocator.destroy(self);
}

pub fn focus(self: *Self) void {
    if (self.focused) return;
    self.commands.register() catch @panic("home.commands.register");
    self.focused = true;
    command.executeName("enter_mode", command.Context.fmt(.{"home"})) catch {};
    if (self.list_box.selected == null)
        self.list_box.select_down();
}

pub fn unfocus(self: *Self) void {
    if (self.focused) self.commands.unregister();
    self.focused = false;
    command.executeName("enter_mode_default", .empty()) catch {};
    self.list_box.selected = null;
}

fn add_menu_command(self: *Self, command_name: []const u8, description: []const u8, hint: []const u8) !void {
    const label_len = description.len + hint.len;
    var buf: [64]u8 = undefined;
    {
        var fis: std.Io.Writer = .fixed(&buf);
        const leader = if (hint.len > 0) "." else " ";
        try fis.writeAll(description);
        try fis.writeAll(" ");
        try fis.writeAll(leader);
        try fis.writeAll(leader);
        for (0..(self.max_desc_len - label_len - 5)) |_|
            try fis.writeAll(leader);
        try fis.print(" :{s}", .{hint});
        const label = fis.buffered();
        const padding = tui.get_widget_style(widget_type).padding;
        self.list_box_label_max = @max(self.list_box_label_max, label.len);
        self.list_box_w = self.list_box_label_max + 2 + padding.left + padding.right;
        self.list_box_desc_w = self.list_box_desc_max + 2 + padding.left + padding.right;
    }

    var value: std.Io.Writer.Allocating = .init(self.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, description);
    try cbor.writeValue(writer, hint);
    try cbor.writeValue(writer, command_name);

    (try self.list_box_items.addOne(self.allocator)).* = try self.allocator.dupe(u8, value.written());
}

fn rebuild_list_box(self: *Self) void {
    self.list_box.reset_items();
    const first = @min(self.list_box_view_pos, self.list_box_items.items.len);
    const last = @min(self.list_box_items.items.len, first + self.list_box_rows);
    for (self.list_box_items.items[first..last]) |label|
        self.list_box.add_item_with_handler(label, list_box_action) catch return;
    if (self.list_box.count() == 0) {
        self.list_box.selected = null;
    } else if (self.list_box.selected) |selected| {
        if (selected >= self.list_box.count()) self.list_box.selected = self.list_box.count() - 1;
    } else if (self.focused) {
        // focus may have landed before the first window was built
        self.list_box.selected = 0;
    }
}

fn select_list_box_item(self: *Self, item: usize) void {
    defer tui.need_render(@src());
    const count = self.list_box_items.items.len;
    if (count == 0 or self.list_box_rows == 0) return;
    const idx = @min(item, count - 1);
    const view_pos = if (idx < self.list_box_view_pos)
        idx
    else if (idx >= self.list_box_view_pos + self.list_box_rows)
        idx + 1 - self.list_box_rows
    else
        self.list_box_view_pos;
    if (view_pos != self.list_box_view_pos) {
        self.list_box_view_pos = view_pos;
        self.rebuild_list_box();
    }
    self.list_box.selected = idx - self.list_box_view_pos;
}

fn selected_list_box_item(self: *Self) ?usize {
    return self.list_box_view_pos + (self.list_box.selected orelse return null);
}

fn move_list_box_selection(self: *Self, direction: enum { up, down, page_up, page_down, top, bottom }) void {
    const item = self.selected_list_box_item() orelse return self.select_list_box_item(0);
    self.select_list_box_item(switch (direction) {
        .up => item -| 1,
        .down => item + 1,
        .page_up => item -| self.list_box_rows,
        .page_down => item + self.list_box_rows,
        .top => 0,
        .bottom => self.list_box_items.items.len -| 1,
    });
}

pub fn update(self: *Self) void {
    self.list_box.update();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (f(walk_ctx, Widget.to(self), .begin)) return true;
    if (!self.list_box_hidden and self.list_box.walk(walk_ctx, f)) return true;
    return f(walk_ctx, Widget.to(self), .end);
}

pub fn receive(_: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var hover: bool = false;
    if (try m.match(.{ "H", tp.extract(&hover) })) {
        tui.rdr().request_mouse_cursor_default(hover);
        tui.need_render(@src());
        return true;
    }
    if (try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.left, tp.more }) or
        try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.middle, tp.more }) or
        try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.right, tp.more }))
        return switch (tui.set_focus_by_mouse_event()) {
            .changed, .same => true,
            .notfound => false,
        };
    return false;
}

fn list_box_on_render(self: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    var description: []const u8 = undefined;
    var hint: []const u8 = undefined;
    var command_name: []const u8 = undefined;
    var iter = button.opts.label; // label contains cbor
    if (!(cbor.matchString(&iter, &description) catch false))
        description = "#ERROR#";
    if (!(cbor.matchString(&iter, &hint) catch false))
        hint = "";
    if (!(cbor.matchString(&iter, &command_name) catch false))
        command_name = "";

    if (!self.list_box_hints) hint = "";
    const label_len = description.len + hint.len;
    var buf: [64]u8 = undefined;
    const leader = blk: {
        var fis: std.Io.Writer = .fixed(&buf);
        const leader = if (hint.len > 0) "." else " ";
        fis.writeAll(" ") catch return false;
        fis.writeAll(leader) catch return false;
        fis.writeAll(leader) catch return false;
        for (0..(self.max_desc_len - label_len - 5)) |_|
            fis.writeAll(leader) catch return false;
        fis.print(" ", .{}) catch return false;
        break :blk fis.buffered();
    };

    const style_base = theme.editor;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else style_base;
    if (button.active or button.hover or selected) {
        button.plane.set_base_style(style_base);
        button.plane.erase();
    } else {
        button.plane.set_base_style_bg_transparent(" ", style_base);
    }
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        button.plane.fill(" ");
        button.plane.home();
    }
    const style_text = if (tui.find_scope_style(theme, "keyword")) |sty| sty.style else style_label;
    const style_leader = if (tui.find_scope_style(theme, "comment")) |sty| sty.style else theme.editor;
    const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;

    if (button.active) {
        button.plane.set_style(style_label);
    } else if (button.hover or selected) {
        button.plane.set_style(style_text);
    } else {
        button.plane.set_style_bg_transparent(style_text);
    }
    tui.render_pointer(&button.plane, selected);
    _ = button.plane.print("{s}", .{description}) catch {};
    if (button.active or button.hover or selected) {
        button.plane.set_style(style_leader);
    } else {
        button.plane.set_style_bg_transparent(style_leader);
    }
    _ = button.plane.print("{s}", .{leader}) catch {};
    if (button.active or button.hover or selected) {
        button.plane.set_style(style_keybind);
    } else {
        button.plane.set_style_bg_transparent(style_keybind);
    }
    _ = button.plane.print("{s}", .{hint}) catch {};
    return false;
}

fn list_box_action(_: **ListBox.State(*Self), button: *ButtonType, _: Widget.Pos) void {
    _ = tui.set_focus_by_mouse_event();
    var description: []const u8 = undefined;
    var hint: []const u8 = undefined;
    var command_name: []const u8 = undefined;
    var iter = button.opts.label; // label contains cbor
    if (!(cbor.matchString(&iter, &description) catch false))
        description = "#ERROR#";
    if (!(cbor.matchString(&iter, &hint) catch false))
        hint = "";
    if (!(cbor.matchString(&iter, &command_name) catch false))
        command_name = "";

    command.executeName(command_name, .empty()) catch {};
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (!std.mem.eql(u8, self.input_namespace, keybind.get_namespace()))
        tp.self_pid().send(.{ "cmd", "show_home" }) catch {};
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    if (self.fire) |*fire| fire.render();
    self.plane.set_base_style(theme.editor);

    const style_title = if (tui.find_scope_style(theme, "function")) |sty| sty.style else theme.editor;
    const style_subtext = if (self.root_mode)
        theme.editor_error
    else if (tui.find_scope_style(theme, "comment")) |sty|
        sty.style
    else
        theme.editor;

    const title = self.home_style.title;

    const subtext = if (self.root_mode)
        self.home_style.subtext_root
    else
        self.home_style.subtext;

    if (self.plane.dim_x() > 120 and self.plane.dim_y() > 22) {
        self.plane.cursor_move_yx(2, self.centerI(4, title.len * 8));
        fonts.print_string_large(&self.plane, title, style_title) catch return false;

        self.plane.cursor_move_yx(10, self.centerI(8, subtext.len * 4));
        fonts.print_string_medium(&self.plane, subtext, style_subtext) catch return false;

        self.position_list_box(self.v_center(15, self.list_box_len, 15), self.center(10, self.list_box_w));
    } else if (self.plane.dim_x() > 55 and self.plane.dim_y() > 16) {
        self.plane.cursor_move_yx(2, self.centerI(4, title.len * 4));
        fonts.print_string_medium(&self.plane, title, style_title) catch return false;

        self.plane.set_style_bg_transparent(style_subtext);
        self.plane.cursor_move_yx(7, self.centerI(6, subtext.len));
        _ = self.plane.print("{s}", .{subtext}) catch {};
        self.plane.set_style(theme.editor);

        self.position_list_box(self.v_center(9, self.list_box_len, 9), self.center(8, self.list_box_w));
    } else if (self.plane.dim_y() > 2) {
        self.plane.set_style_bg_transparent(style_title);
        self.plane.cursor_move_yx(1, self.centerI(4, title.len));
        _ = self.plane.print("{s}", .{title}) catch return false;

        self.plane.set_style_bg_transparent(style_subtext);
        self.plane.cursor_move_yx(3, self.centerI(7, subtext.len));
        _ = self.plane.print("{s}", .{subtext}) catch {};
        self.plane.set_style(theme.editor);

        const x = @min(self.plane.dim_x() -| 32, 8);
        self.position_list_box(self.v_center(5, self.list_box_len, 5), self.center(x, self.list_box_w));
    } else {
        self.plane.set_style_bg_transparent(style_title);
        self.plane.cursor_move_yx(0, self.centerI(2, title.len));
        _ = self.plane.print("{s}", .{title}) catch return false;
        self.plane.set_style_bg_transparent(style_subtext);
        _ = self.plane.print(" {s}", .{subtext}) catch {};
        self.plane.set_style(theme.editor);
        const x = @min(self.plane.dim_x() -| 32, 8);
        self.position_list_box(self.v_center(5, self.list_box_len, 5), self.center(x, self.list_box_w));
    }

    self.render_info(theme, style_subtext);

    const more = if (self.list_box_hidden) false else self.list_box.container.render(theme);
    return more or self.fire != null;
}

fn render_info(self: *Self, theme: *const Widget.Theme, style_subtext: Widget.Theme.Style) void {
    const cols: i32 = self.info.content_w;
    if (cols == 0) return;

    var p = self.info.inner_plane();
    p.set_base_style(theme.editor);
    p.erase();

    var row: c_int = 0;
    if (builtin.mode == .Debug) {
        p.cursor_move_yx(row, @intCast(cols - @as(i32, @intCast(info_debug_text.len))));
        p.set_style(theme.editor_error);
        _ = p.print("{s}", .{info_debug_text}) catch {};
        row += 1;
    }
    const version = info_version();
    p.cursor_move_yx(row, @intCast(cols - @as(i32, @intCast(version.len))));
    p.set_style(style_subtext);
    _ = p.print("{s}", .{version}) catch {};

    _ = self.info.render(theme);
}

fn position_list_box(self: *Self, y: usize, x: usize) void {
    const box = Widget.Box.from(self.plane);
    const padding = tui.get_widget_style(widget_type).padding;
    const deco_h: usize = @as(usize, padding.top) + @as(usize, padding.bottom);

    const avail_rows = (box.h -| y) -| deco_h;
    self.list_box_hidden = avail_rows == 0;
    if (self.list_box_hidden) return;

    const hints = box.w >= self.list_box_w;
    const want_w = if (hints) self.list_box_w else self.list_box_desc_w;
    const x_ = @min(x, box.w -| want_w);
    const w = @min(want_w, box.w -| x_);

    const rows = @min(avail_rows, self.list_box_items.items.len);
    if (rows != self.list_box_rows or hints != self.list_box_hints) {
        self.list_box_rows = rows;
        self.list_box_hints = hints;
        self.list_box_view_pos = @min(self.list_box_view_pos, self.list_box_items.items.len -| rows);
        self.rebuild_list_box();
    }
    self.list_box.resize(.{ .y = box.y + y, .x = box.x + x_, .w = w, .h = rows + deco_h });
}

fn center(self: *Self, non_centered: usize, w: usize) usize {
    const box = Widget.Box.from(self.plane);
    if (!self.home_style.centered) return @min(non_centered, box.w -| w);
    return if (box.w > w) (box.w - w) / 2 else 0;
}

fn centerI(self: *Self, non_centered: usize, w: usize) c_int {
    return @intCast(self.center(non_centered, w));
}

fn v_center(self: *Self, non_centered: usize, h: usize, minoffset: usize) usize {
    if (!self.home_style.centered) return non_centered;
    const box = Widget.Box.from(self.plane);
    const y = if (box.h > h) (box.h - h) / 2 else 0;
    return @max(y, minoffset);
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    if (self.fire) |*fire| {
        fire.deinit();
        self.fire = Fire.init(self.allocator, self.plane) catch return;
    }
    if (pos.frame.is_set()) {
        self.info.offset_y = info_margin_rows;
        self.info.handle_resize(.{ .frame = pos.frame });
    } else {
        self.info.offset_y = info_margin_rows + info_bottom_bar_rows;
        self.info.handle_resize(.{ .frame = tui.window_frame() });
    }
}

const Commands = command.Collection(cmds);

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn close_file(_: *Self, ctx: Ctx) Result {
        try command.executeName("close_split", ctx);
    }
    pub const close_file_meta: Meta = .{};

    pub fn save_all(_: *Self, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm|
            bm.save_all(.{}) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const save_all_meta: Meta = .{ .description = "Save all changed files" };

    pub fn home_menu_down(self: *Self, _: Ctx) Result {
        self.move_list_box_selection(.down);
    }
    pub const home_menu_down_meta: Meta = .{};

    pub fn home_menu_up(self: *Self, _: Ctx) Result {
        self.move_list_box_selection(.up);
    }
    pub const home_menu_up_meta: Meta = .{};

    pub fn home_menu_pagedown(self: *Self, _: Ctx) Result {
        self.move_list_box_selection(.page_down);
    }
    pub const home_menu_pagedown_meta: Meta = .{};

    pub fn home_menu_pageup(self: *Self, _: Ctx) Result {
        self.move_list_box_selection(.page_up);
    }
    pub const home_menu_pageup_meta: Meta = .{};

    pub fn home_menu_top(self: *Self, _: Ctx) Result {
        self.move_list_box_selection(.top);
    }
    pub const home_menu_top_meta: Meta = .{};

    pub fn home_menu_bottom(self: *Self, _: Ctx) Result {
        self.move_list_box_selection(.bottom);
    }
    pub const home_menu_bottom_meta: Meta = .{};

    pub fn home_menu_activate(self: *Self, _: Ctx) Result {
        self.list_box.activate_selected();
    }
    pub const home_menu_activate_meta: Meta = .{};

    pub fn home_next_widget_style(self: *Self, _: Ctx) Result {
        tui.set_next_style(widget_type);
        const padding = tui.get_widget_style(widget_type).padding;
        self.list_box_len = self.list_box_count + padding.top + padding.bottom;
        self.list_box_w = self.list_box_label_max + 2 + padding.left + padding.right;
        self.list_box_desc_w = self.list_box_desc_max + 2 + padding.left + padding.right;
        tui.need_render(@src());
        try tui.save_config();
    }
    pub const home_next_widget_style_meta: Meta = .{};

    pub fn home_sheeran(self: *Self, _: Ctx) Result {
        self.fire = if (self.fire) |*fire| ret: {
            fire.deinit();
            break :ret null;
        } else try Fire.init(self.allocator, self.plane);
    }
    pub const home_sheeran_meta: Meta = .{};
};

const Fire = @import("Fire.zig");

fn splice(in: []const u8) []const u8 {
    var out: []const u8 = "";
    var it = std.mem.splitAny(u8, in, "\n ");
    var first = true;
    while (it.next()) |item| {
        if (first) {
            first = false;
        } else {
            out = out ++ " ";
        }
        out = out ++ item;
    }
    return out;
}
