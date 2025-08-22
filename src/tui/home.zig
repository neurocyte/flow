const std = @import("std");
const build_options = @import("build_options");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const builtin = @import("builtin");

const Plane = @import("renderer").Plane;
const root = @import("root");

const Widget = @import("Widget.zig");
const Button = @import("Button.zig");
const Menu = @import("Menu.zig");
const tui = @import("tui.zig");
const command = @import("command");
const keybind = @import("keybind");

const fonts = @import("fonts.zig");

const style = struct {
    title: []const u8 = root.application_title,
    subtext: []const u8 = root.application_subtext,

    centered: bool = false,

    menu_commands: []const u8 = splice(if (build_options.gui)
        \\find_file
        \\create_new_file
        \\open_file
        \\open_recent_project
        \\find_in_files
        \\open_command_palette
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
fire: ?Fire = null,
commands: Commands = undefined,
menu: *Menu.State(*Self),
menu_w: usize = 0,
menu_label_max: usize = 0,
menu_count: usize = 0,
menu_len: usize = 0,
max_desc_len: usize = 0,
input_namespace: []const u8,

home_style: style,
home_style_bufs: [][]const u8,

const Self = @This();

const widget_type: Widget.Type = .home;

pub fn create(allocator: std.mem.Allocator, parent: Widget) !Widget {
    const logger = log.logger("home");
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    var n = try Plane.init(&(Widget.Box{}).opts("editor"), parent.plane.*);
    errdefer n.deinit();

    command.executeName("enter_mode", command.Context.fmt(.{"home"})) catch {};
    const keybind_mode = tui.get_keybind_mode() orelse @panic("no active keybind mode");
    const home_style, const home_style_bufs = root.read_config(style, allocator);

    const w = Widget.to(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent.plane.*,
        .plane = n,
        .menu = try Menu.create(*Self, allocator, w.plane.*, .{
            .ctx = self,
            .style = widget_type,
            .on_render = menu_on_render,
        }),
        .input_namespace = keybind.get_namespace(),
        .home_style = home_style,
        .home_style_bufs = home_style_bufs,
    };
    try self.commands.init(self);
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
        self.menu_count += 1;
        var hints = std.mem.splitScalar(u8, keybind_mode.keybind_hints.get(command_name) orelse "", ',');
        const hint = hints.first();
        self.max_desc_len = @max(self.max_desc_len, description.len + hint.len + 5);
        try self.add_menu_command(command_name, description, hint, self.menu);
    }
    const padding = tui.get_widget_style(widget_type).padding;
    self.menu_len = self.menu_count + padding.top + padding.bottom;
    self.position_menu(15, 9);
    return w;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    root.free_config(self.allocator, self.home_style_bufs);
    self.menu.deinit(allocator);
    self.commands.deinit();
    self.plane.deinit();
    if (self.fire) |*fire| fire.deinit();
    allocator.destroy(self);
}

fn add_menu_command(self: *Self, command_name: []const u8, description: []const u8, hint: []const u8, menu: anytype) !void {
    const label_len = description.len + hint.len;
    var buf: [64]u8 = undefined;
    {
        var fis = std.io.fixedBufferStream(&buf);
        const writer = fis.writer();
        const leader = if (hint.len > 0) "." else " ";
        _ = try writer.write(description);
        _ = try writer.write(" ");
        _ = try writer.write(leader);
        _ = try writer.write(leader);
        for (0..(self.max_desc_len - label_len - 5)) |_|
            _ = try writer.write(leader);
        try writer.print(" :{s}", .{hint});
        const label = fis.getWritten();
        const padding = tui.get_widget_style(widget_type).padding;
        self.menu_label_max = @max(self.menu_label_max, label.len);
        self.menu_w = self.menu_label_max + 2 + padding.left + padding.right;
    }

    var value = std.ArrayList(u8).init(self.allocator);
    defer value.deinit();
    const writer = value.writer();
    try cbor.writeValue(writer, description);
    try cbor.writeValue(writer, hint);
    try cbor.writeValue(writer, command_name);

    try menu.add_item_with_handler(value.items, menu_action);
}

pub fn update(self: *Self) void {
    self.menu.update();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.menu.walk(walk_ctx, f) or f(walk_ctx, w);
}

pub fn receive(_: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var hover: bool = false;
    if (try m.match(.{ "H", tp.extract(&hover) })) {
        tui.rdr().request_mouse_cursor_default(hover);
        tui.need_render();
        return true;
    }
    return false;
}

fn menu_on_render(self: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
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

    const label_len = description.len + hint.len;
    var buf: [64]u8 = undefined;
    const leader = blk: {
        var fis = std.io.fixedBufferStream(&buf);
        const writer = fis.writer();
        const leader = if (hint.len > 0) "." else " ";
        _ = writer.write(" ") catch return false;
        _ = writer.write(leader) catch return false;
        _ = writer.write(leader) catch return false;
        for (0..(self.max_desc_len - label_len - 5)) |_|
            _ = writer.write(leader) catch return false;
        writer.print(" ", .{}) catch return false;
        break :blk fis.getWritten();
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

fn menu_action(_: **Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
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

    command.executeName(command_name, .{}) catch {};
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
    const style_subtext = if (tui.find_scope_style(theme, "comment")) |sty| sty.style else theme.editor;

    if (self.plane.dim_x() > 120 and self.plane.dim_y() > 22) {
        self.plane.cursor_move_yx(2, self.centerI(4, self.home_style.title.len * 8)) catch return false;
        fonts.print_string_large(&self.plane, self.home_style.title, style_title) catch return false;

        self.plane.cursor_move_yx(10, self.centerI(8, self.home_style.subtext.len * 4)) catch return false;
        fonts.print_string_medium(&self.plane, self.home_style.subtext, style_subtext) catch return false;

        self.position_menu(self.v_center(15, self.menu_len, 15), self.center(10, self.menu_w));
    } else if (self.plane.dim_x() > 55 and self.plane.dim_y() > 16) {
        self.plane.cursor_move_yx(2, self.centerI(4, self.home_style.title.len * 4)) catch return false;
        fonts.print_string_medium(&self.plane, self.home_style.title, style_title) catch return false;

        self.plane.set_style_bg_transparent(style_subtext);
        self.plane.cursor_move_yx(7, self.centerI(6, self.home_style.subtext.len)) catch return false;
        _ = self.plane.print("{s}", .{self.home_style.subtext}) catch {};
        self.plane.set_style(theme.editor);

        self.position_menu(self.v_center(9, self.menu_len, 9), self.center(8, self.menu_w));
    } else {
        self.plane.set_style_bg_transparent(style_title);
        self.plane.cursor_move_yx(1, self.centerI(4, self.home_style.title.len)) catch return false;
        _ = self.plane.print("{s}", .{self.home_style.title}) catch return false;

        self.plane.set_style_bg_transparent(style_subtext);
        self.plane.cursor_move_yx(3, self.centerI(6, self.home_style.subtext.len)) catch return false;
        _ = self.plane.print("{s}", .{self.home_style.subtext}) catch {};
        self.plane.set_style(theme.editor);

        const x = @min(self.plane.dim_x() -| 32, 8);
        self.position_menu(self.v_center(5, self.menu_len, 5), self.center(x, self.menu_w));
    }

    if (self.plane.dim_y() < 3 or self.plane.dim_x() < root.version.len + 4) return false;

    self.plane.cursor_move_yx(
        @intCast(self.plane.dim_y() - 2),
        @intCast(@max(self.plane.dim_x(), root.version.len + 3) - root.version.len - 3),
    ) catch {};
    self.plane.set_style_bg_transparent(style_subtext);
    _ = self.plane.print("{s}", .{root.version}) catch return false;
    if (builtin.mode == .Debug) {
        const debug_warning_text = "debug build";
        if (self.plane.dim_y() < 4 or self.plane.dim_x() < debug_warning_text.len + 4) return false;
        self.plane.cursor_move_yx(
            @intCast(self.plane.dim_y() - 3),
            @intCast(@max(self.plane.dim_x(), debug_warning_text.len + 3) - debug_warning_text.len - 3),
        ) catch {};
        self.plane.set_style_bg_transparent(theme.editor_error);
        _ = self.plane.print("{s}", .{debug_warning_text}) catch return false;
    }

    const more = self.menu.container.render(theme);
    return more or self.fire != null;
}

fn position_menu(self: *Self, y: usize, x: usize) void {
    const box = Widget.Box.from(self.plane);
    self.menu.resize(.{ .y = box.y + y, .x = box.x + x, .w = self.menu_w, .h = self.menu_len });
}

fn center(self: *Self, non_centered: usize, w: usize) usize {
    if (!self.home_style.centered) return non_centered;
    const box = Widget.Box.from(self.plane);
    const x = if (box.w > w) (box.w - w) / 2 else 0;
    return box.x + x;
}

fn centerI(self: *Self, non_centered: usize, w: usize) c_int {
    return @intCast(self.center(non_centered, w));
}

fn v_center(self: *Self, non_centered: usize, h: usize, minoffset: usize) usize {
    if (!self.home_style.centered) return non_centered;
    const box = Widget.Box.from(self.plane);
    const y = if (box.h > h) (box.h - h) / 2 else 0;
    return box.y + @max(y, minoffset);
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    if (self.fire) |*fire| {
        fire.deinit();
        self.fire = Fire.init(self.allocator, self.plane) catch return;
    }
}

const Commands = command.Collection(cmds);

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn save_all(_: *Self, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm|
            bm.save_all() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const save_all_meta: Meta = .{ .description = "Save all changed files" };

    pub fn home_menu_down(self: *Self, _: Ctx) Result {
        self.menu.select_down();
    }
    pub const home_menu_down_meta: Meta = .{};

    pub fn home_menu_up(self: *Self, _: Ctx) Result {
        self.menu.select_up();
    }
    pub const home_menu_up_meta: Meta = .{};

    pub fn home_menu_activate(self: *Self, _: Ctx) Result {
        self.menu.activate_selected();
    }
    pub const home_menu_activate_meta: Meta = .{};

    pub fn home_next_widget_style(self: *Self, _: Ctx) Result {
        tui.set_next_style(widget_type);
        const padding = tui.get_widget_style(widget_type).padding;
        self.menu_len = self.menu_count + padding.top + padding.bottom;
        self.menu_w = self.menu_label_max + 2 + padding.left + padding.right;
        tui.need_render();
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
