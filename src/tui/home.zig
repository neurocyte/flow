const std = @import("std");
const build_options = @import("build_options");
const tp = @import("thespian");

const Plane = @import("renderer").Plane;
const root = @import("root");

const Widget = @import("Widget.zig");
const Button = @import("Button.zig");
const Menu = @import("Menu.zig");
const tui = @import("tui.zig");
const command = @import("command");
const keybind = @import("keybind");

const fonts = @import("fonts.zig");

allocator: std.mem.Allocator,
plane: Plane,
parent: Plane,
fire: ?Fire = null,
commands: Commands = undefined,
menu: *Menu.State(*Self),
menu_w: usize = 0,
max_desc_len: usize = 0,
input_namespace: []const u8,

const Self = @This();

const menu_commands = if (build_options.gui) &[_][]const u8{
    "find_file",
    "create_new_file",
    "open_file",
    "open_recent_project",
    "find_in_files",
    "open_command_palette",
    "select_task",
    "add_task",
    "open_config",
    "open_gui_config",
    "change_fontface",
    "open_keybind_config",
    "toggle_input_mode",
    "change_theme",
    "open_help",
    "open_version_info",
    "quit",
} else &[_][]const u8{
    "find_file",
    "create_new_file",
    "open_file",
    "open_recent_project",
    "find_in_files",
    "open_command_palette",
    "select_task",
    "add_task",
    "open_config",
    "open_keybind_config",
    "toggle_input_mode",
    "change_theme",
    "open_help",
    "open_version_info",
    "quit",
};

pub fn create(allocator: std.mem.Allocator, parent: Widget) !Widget {
    const self: *Self = try allocator.create(Self);
    var n = try Plane.init(&(Widget.Box{}).opts("editor"), parent.plane.*);
    errdefer n.deinit();

    command.executeName("enter_mode", command.Context.fmt(.{"home"})) catch {};
    const keybind_mode = tui.get_keybind_mode() orelse @panic("no active keybind mode");

    const w = Widget.to(self);
    self.* = .{
        .allocator = allocator,
        .parent = parent.plane.*,
        .plane = n,
        .menu = try Menu.create(*Self, allocator, w.plane.*, .{ .ctx = self, .on_render = menu_on_render }),
        .input_namespace = keybind.get_namespace(),
    };
    try self.commands.init(self);
    self.get_max_desc_len(keybind_mode.keybind_hints);
    inline for (menu_commands) |command_name| try self.add_menu_command(command_name, self.menu, keybind_mode.keybind_hints);
    self.position_menu(15, 9);
    return w;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.menu.deinit(allocator);
    self.commands.deinit();
    self.plane.deinit();
    if (self.fire) |*fire| fire.deinit();
    allocator.destroy(self);
}

fn get_max_desc_len(self: *Self, hints_map: anytype) void {
    inline for (menu_commands) |command_name| {
        const id = command.get_id(command_name) orelse @panic(command_name ++ " is not defined");
        const description = command.get_description(id) orelse @panic(command_name ++ " has no description");
        var hints = std.mem.splitScalar(u8, hints_map.get(command_name) orelse "", ',');
        const hint = hints.first();
        self.max_desc_len = @max(self.max_desc_len, description.len + hint.len + 5);
    }
}

fn add_menu_command(self: *Self, comptime command_name: []const u8, menu: anytype, hints_map: anytype) !void {
    const id = command.get_id(command_name) orelse @panic(command_name ++ " is not defined");
    const description = command.get_description(id) orelse @panic(command_name ++ " has no description");
    var hints = std.mem.splitScalar(u8, hints_map.get(command_name) orelse "", ',');
    const hint = hints.first();
    const label_len = description.len + hint.len;
    var buf: [64]u8 = undefined;
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
    try menu.add_item_with_handler(label, menu_action(command_name));
    self.menu_w = @max(self.menu_w, label.len + 1);
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

fn menu_on_render(_: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
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
    const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    const sep = std.mem.indexOfScalar(u8, button.opts.label, ':') orelse button.opts.label.len;
    if (button.active) {
        button.plane.set_style(style_label);
    } else if (button.hover or selected) {
        button.plane.set_style(style_text);
    } else {
        button.plane.set_style_bg_transparent(style_text);
    }
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}{s}", .{ pointer, button.opts.label[0..sep] }) catch {};
    if (button.active or button.hover or selected) {
        button.plane.set_style(style_keybind);
    } else {
        button.plane.set_style_bg_transparent(style_keybind);
    }
    _ = button.plane.print("{s}", .{button.opts.label[sep + 1 ..]}) catch {};
    return false;
}

fn menu_action(comptime command_name: []const u8) *const fn (_: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
    return struct {
        fn action(_: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
            command.executeName(command_name, .{}) catch {};
        }
    }.action;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    if (!std.mem.eql(u8, self.input_namespace, keybind.get_namespace()))
        tp.self_pid().send(.{ "cmd", "show_home" }) catch {};
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    if (self.fire) |*fire| fire.render();

    const style_title = if (tui.find_scope_style(theme, "function")) |sty| sty.style else theme.editor;
    const style_subtext = if (tui.find_scope_style(theme, "comment")) |sty| sty.style else theme.editor;

    if (self.plane.dim_x() > 120 and self.plane.dim_y() > 22) {
        self.plane.cursor_move_yx(2, 4) catch return false;
        fonts.print_string_large(&self.plane, root.application_title, style_title) catch return false;

        self.plane.cursor_move_yx(10, 8) catch return false;
        fonts.print_string_medium(&self.plane, root.application_subtext, style_subtext) catch return false;

        self.position_menu(15, 10);
    } else if (self.plane.dim_x() > 55 and self.plane.dim_y() > 16) {
        self.plane.cursor_move_yx(2, 4) catch return false;
        fonts.print_string_medium(&self.plane, root.application_title, style_title) catch return false;

        self.plane.set_style_bg_transparent(style_subtext);
        self.plane.cursor_move_yx(7, 6) catch return false;
        _ = self.plane.print(root.application_subtext, .{}) catch {};
        self.plane.set_style(theme.editor);

        self.position_menu(9, 8);
    } else {
        self.plane.set_style_bg_transparent(style_title);
        self.plane.cursor_move_yx(1, 4) catch return false;
        _ = self.plane.print(root.application_title, .{}) catch return false;

        self.plane.set_style_bg_transparent(style_subtext);
        self.plane.cursor_move_yx(3, 6) catch return false;
        _ = self.plane.print(root.application_subtext, .{}) catch {};
        self.plane.set_style(theme.editor);

        const x = @min(self.plane.dim_x() -| 32, 8);
        self.position_menu(5, x);
    }
    const more = self.menu.render(theme);

    return more or self.fire != null;
}

fn position_menu(self: *Self, y: usize, x: usize) void {
    const box = Widget.Box.from(self.plane);
    self.menu.resize(.{ .y = box.y + y, .x = box.x + x, .w = self.menu_w });
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
    const Result = command.Result;

    pub fn save_all(_: *Self, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm|
            bm.save_all() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const save_all_meta = .{ .description = "Save all changed files" };

    pub fn home_menu_down(self: *Self, _: Ctx) Result {
        self.menu.select_down();
    }
    pub const home_menu_down_meta = .{};

    pub fn home_menu_up(self: *Self, _: Ctx) Result {
        self.menu.select_up();
    }
    pub const home_menu_up_meta = .{};

    pub fn home_menu_activate(self: *Self, _: Ctx) Result {
        self.menu.activate_selected();
    }
    pub const home_menu_activate_meta = .{};

    pub fn home_sheeran(self: *Self, _: Ctx) Result {
        self.fire = if (self.fire) |*fire| ret: {
            fire.deinit();
            break :ret null;
        } else try Fire.init(self.allocator, self.plane);
    }
    pub const home_sheeran_meta = .{};
};

const Fire = @import("Fire.zig");
