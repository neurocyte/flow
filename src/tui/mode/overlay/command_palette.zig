const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");

const Plane = @import("renderer").Plane;
const planeutils = @import("renderer").planeutils;
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;

const tui = @import("../../tui.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const MessageFilter = @import("../../MessageFilter.zig");
const Button = @import("../../Button.zig");
const InputBox = @import("../../InputBox.zig");
const Menu = @import("../../Menu.zig");
const Widget = @import("../../Widget.zig");
const mainview = @import("../../mainview.zig");
const project_manager = @import("project_manager");

const Self = @This();
const max_recent_files: usize = 25;
const max_menu_width = 80;

a: std.mem.Allocator,
f: usize = 0,
menu: *Menu.State(*Self),
inputbox: *InputBox.State(*Self),
logger: log.Logger,
longest: usize = 0,
commands: Commands = undefined,

pub fn create(a: std.mem.Allocator) !tui.Mode {
    const mv = if (tui.current().mainview.dynamic_cast(mainview)) |mv_| mv_ else return error.NotFound;
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .menu = try Menu.create(*Self, a, tui.current().mainview, .{ .ctx = self, .on_render = on_render_menu, .on_resize = on_resize_menu }),
        .logger = log.logger(@typeName(Self)),
        .inputbox = (try self.menu.add_header(try InputBox.create(*Self, self.a, self.menu.menu.parent, .{
            .ctx = self,
            .label = "Search commands",
        }))).dynamic_cast(InputBox.State(*Self)) orelse unreachable,
    };
    try self.commands.init(self);
    try self.start_query();
    self.menu.resize(.{ .y = 0, .x = 25, .w = 32 });
    try mv.floating_views.add(self.menu.menu_widget);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "󱊒 command",
        .description = "command",
    };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    tui.current().message_filters.remove_ptr(self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv|
        mv.floating_views.remove(self.menu.menu_widget);
    self.logger.deinit();
    self.a.destroy(self);
}

fn on_render_menu(_: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    button.plane.set_base_style(" ", style_base);
    button.plane.erase();
    button.plane.home();
    var command_name: []const u8 = undefined;
    var iter = button.opts.label; // label contains cbor, first the file name, then multiple match indexes
    if (!(cbor.matchString(&iter, &command_name) catch false))
        command_name = "#ERROR#";
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}{s} ", .{
        pointer,
        command_name,
    }) catch {};
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            render_cell(&button.plane, 0, index + 1, theme.editor_match) catch break;
        } else break;
    }
    return false;
}

fn render_cell(plane: *Plane, y: usize, x: usize, style: Widget.Theme.Style) !void {
    plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    cell.set_style(style);
    _ = plane.putc(&cell) catch {};
}

fn on_resize_menu(self: *Self, _: *Menu.State(*Self), _: Widget.Box) void {
    self.menu.resize(.{ .y = 0, .x = 25, .w = @min(self.longest, max_menu_width) + 2 });
}

fn menu_action_execute_command(menu: **Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
    var command_name: []const u8 = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &command_name) catch false)) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
    tp.self_pid().send(.{ "cmd", command_name, .{} }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;
    var text: []const u8 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        try self.mapEvent(evtype, keypress, egc, modifiers);
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        try self.insert_bytes(text);
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) tp.result {
    return switch (evtype) {
        event_type.PRESS => self.mapPress(keypress, egc, modifiers),
        event_type.REPEAT => self.mapPress(keypress, egc, modifiers),
        event_type.RELEASE => self.mapRelease(keypress, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'J' => self.cmd("toggle_logview", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            'E' => self.cmd("command_palette_menu_down", .{}),
            'P' => self.cmd("command_palette_menu_up", .{}),
            'N' => self.cmd("command_palette_menu_down", .{}),
            'V' => self.cmd("system_paste", .{}),
            'C' => self.cmd("exit_overlay_mode", .{}),
            'G' => self.cmd("exit_overlay_mode", .{}),
            key.ESC => self.cmd("exit_overlay_mode", .{}),
            key.UP => self.cmd("command_palette_menu_up", .{}),
            key.DOWN => self.cmd("command_palette_menu_down", .{}),
            key.ENTER => self.cmd("command_palette_menu_activate", .{}),
            key.BACKSPACE => self.delete_word(),
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'Q' => self.cmd("quit_without_saving", .{}),
            'W' => self.cmd("close_file_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            'E' => self.cmd("command_palette_menu_up", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'L' => self.cmd("toggle_logview", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        0 => switch (keypress) {
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.F11 => self.cmd("toggle_logview", .{}),
            key.F12 => self.cmd("toggle_inputview", .{}),
            key.ESC => self.cmd("exit_overlay_mode", .{}),
            key.UP => self.cmd("command_palette_menu_up", .{}),
            key.DOWN => self.cmd("command_palette_menu_down", .{}),
            key.ENTER => self.cmd("command_palette_menu_activate", .{}),
            key.BACKSPACE => self.delete_code_point(),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32) tp.result {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => if (self.menu.selected orelse 0 > 0) return self.cmd("command_palette_menu_activate", .{}),
        else => {},
    };
}

fn start_query(self: *Self) tp.result {
    for (command.commands.items) |cmd_|
        if (cmd_) |p|
            self.add_item(p.name, null) catch |e| return tp.exit_error(e);
}

fn add_item(self: *Self, command_name: []const u8, matches: ?[]const u8) !void {
    var label = std.ArrayList(u8).init(self.a);
    defer label.deinit();
    const writer = label.writer();
    try cbor.writeValue(writer, command_name);
    if (matches) |cb| _ = try writer.write(cb);
    try self.menu.add_item_with_handler(label.items, menu_action_execute_command);
}

fn delete_word(self: *Self) tp.result {
    if (std.mem.lastIndexOfAny(u8, self.inputbox.text.items, "/\\. -_")) |pos| {
        self.inputbox.text.shrinkRetainingCapacity(pos);
    } else {
        self.inputbox.text.shrinkRetainingCapacity(0);
    }
    self.inputbox.cursor = self.inputbox.text.items.len;
    return self.start_query();
}

fn delete_code_point(self: *Self) tp.result {
    if (self.inputbox.text.items.len > 0) {
        self.inputbox.text.shrinkRetainingCapacity(self.inputbox.text.items.len - 1);
        self.inputbox.cursor = self.inputbox.text.items.len;
    }
    return self.start_query();
}

fn insert_code_point(self: *Self, c: u32) tp.result {
    var buf: [6]u8 = undefined;
    const bytes = ucs32_to_utf8(&[_]u32{c}, &buf) catch |e| return tp.exit_error(e);
    self.inputbox.text.appendSlice(buf[0..bytes]) catch |e| return tp.exit_error(e);
    self.inputbox.cursor = self.inputbox.text.items.len;
    return self.start_query();
}

fn insert_bytes(self: *Self, bytes: []const u8) tp.result {
    self.inputbox.text.appendSlice(bytes) catch |e| return tp.exit_error(e);
    self.inputbox.cursor = self.inputbox.text.items.len;
    return self.start_query();
}

fn cmd(_: *Self, name_: []const u8, ctx: command.Context) tp.result {
    try command.executeName(name_, ctx);
}

fn msg(_: *Self, text: []const u8) tp.result {
    return tp.self_pid().send(.{ "log", "home", text });
}

fn cmd_async(_: *Self, name_: []const u8) tp.result {
    return tp.self_pid().send(.{ "cmd", name_ });
}

const Commands = command.Collection(cmds);
const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;

    pub fn command_palette_menu_down(self: *Self, _: Ctx) tp.result {
        self.menu.select_down();
    }

    pub fn command_palette_menu_up(self: *Self, _: Ctx) tp.result {
        self.menu.select_up();
    }

    pub fn command_palette_menu_activate(self: *Self, _: Ctx) tp.result {
        self.menu.activate_selected();
    }
};
