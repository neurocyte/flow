const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");
const log = @import("log");

const tui = @import("../../tui.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const MessageFilter = @import("../../MessageFilter.zig");
const Button = @import("../../Button.zig");
const Menu = @import("../../Menu.zig");
const Widget = @import("../../Widget.zig");
const mainview = @import("../../mainview.zig");
const project_manager = @import("project_manager");

const Self = @This();
const max_recent_files: usize = 25;

a: std.mem.Allocator,
f: usize = 0,
menu: *Menu.State(*Self),
logger: log.Logger,
count: usize = 0,
longest: usize = 0,
commands: Commands = undefined,

pub fn create(a: std.mem.Allocator) !tui.Mode {
    const mv = if (tui.current().mainview.dynamic_cast(mainview)) |mv_| mv_ else return error.NotFound;
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .menu = try Menu.create(*Self, a, tui.current().mainview, .{ .ctx = self, .on_render = on_render_menu, .on_resize = on_resize_menu }),
        .logger = log.logger(@typeName(Self)),
    };
    try self.commands.init(self);
    try tui.current().message_filters.add(MessageFilter.bind(self, receive_project_manager));
    try project_manager.request_recent_files(max_recent_files);
    self.menu.resize(.{ .y = 0, .x = 25, .w = 32 });
    try mv.floating_views.add(self.menu.menu_widget);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "󰈞 open recent",
        .description = "open recent",
    };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    tui.current().message_filters.remove_ptr(self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv|
        mv.floating_views.remove(self.menu.menu_widget);
    self.a.destroy(self);
}

fn on_render_menu(_: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    try tui.set_base_style_alpha(button.plane, " ", style_base, nc.ALPHA_OPAQUE, nc.ALPHA_OPAQUE);
    button.plane.erase();
    button.plane.home();
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}{s} ", .{ pointer, button.opts.label }) catch {};
    return false;
}

fn on_resize_menu(self: *Self, state: *Menu.State(*Self), box: Widget.Box) void {
    const w = @min(box.w, @min(self.longest, 80) + 2);
    self.menu.resize(.{
        .y = 0,
        .x = box.w - w / 2,
        .h = state.menu.widgets.items.len,
        .w = w,
    });
}

fn menu_action_open_file(menu: *Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.opts.ctx.logger.err("navigate", e);
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = button.label.items } }) catch |e| menu.opts.ctx.logger.err("navigate", e);
}

fn receive_project_manager(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "PRJ", tp.more })) {
        try self.process_project_manager(m);
        return true;
    }
    return false;
}

fn process_project_manager(self: *Self, m: tp.message) tp.result {
    var file_name: []const u8 = undefined;
    if (try m.match(.{ "PRJ", "recent", tp.extract(&file_name) })) {
        if (self.count < max_recent_files) {
            self.count += 1;
            self.longest = @max(self.longest, file_name.len);
            self.menu.add_item_with_handler(file_name, menu_action_open_file) catch |e| return tp.exit_error(e);
            self.menu.resize(.{ .y = 0, .x = 25, .w = @min(self.longest, 80) + 2 });
            tui.need_render();
        }
    } else {
        self.logger.err("receive", tp.unexpected(m));
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var modifiers: u32 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.any, tp.string, tp.extract(&modifiers) })) {
        try self.mapEvent(evtype, keypress, modifiers);
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, modifiers: u32) tp.result {
    return switch (evtype) {
        nc.event_type.PRESS => self.mapPress(keypress, modifiers),
        nc.event_type.REPEAT => self.mapPress(keypress, modifiers),
        nc.event_type.RELEASE => self.mapRelease(keypress, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        nc.mod.CTRL => switch (keynormal) {
            'J' => self.cmd("toggle_logview", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            'E' => self.cmd("open_recent_menu_down", .{}),
            nc.key.ESC => self.cmd("exit_overlay_mode", .{}),
            nc.key.UP => self.cmd("open_recent_menu_up", .{}),
            nc.key.DOWN => self.cmd("open_recent_menu_down", .{}),
            nc.key.ENTER => self.cmd("open_recent_menu_activate", .{}),
            else => {},
        },
        nc.mod.CTRL | nc.mod.SHIFT => switch (keynormal) {
            'Q' => self.cmd("quit_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            'E' => self.cmd("open_recent_menu_up", .{}),
            else => {},
        },
        nc.mod.ALT => switch (keynormal) {
            'L' => self.cmd("toggle_logview", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            else => {},
        },
        0 => switch (keypress) {
            nc.key.F09 => self.cmd("theme_prev", .{}),
            nc.key.F10 => self.cmd("theme_next", .{}),
            nc.key.F11 => self.cmd("toggle_logview", .{}),
            nc.key.F12 => self.cmd("toggle_inputview", .{}),
            nc.key.ESC => self.cmd("exit_overlay_mode", .{}),
            nc.key.UP => self.cmd("open_recent_menu_up", .{}),
            nc.key.DOWN => self.cmd("open_recent_menu_down", .{}),
            nc.key.ENTER => self.cmd("open_recent_menu_activate", .{}),
            else => {},
        },
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32) tp.result {
    return switch (keypress) {
        nc.key.LCTRL, nc.key.RCTRL => self.cmd("open_recent_menu_activate", .{}),
        else => {},
    };
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

    pub fn open_recent_menu_down(self: *Self, _: Ctx) tp.result {
        self.menu.select_down();
    }

    pub fn open_recent_menu_up(self: *Self, _: Ctx) tp.result {
        self.menu.select_up();
    }

    pub fn open_recent_menu_activate(self: *Self, _: Ctx) tp.result {
        self.menu.activate_selected();
    }
};
