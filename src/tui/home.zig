const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");

const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Button = @import("Button.zig");
const tui = @import("tui.zig");
const command = @import("command.zig");
const fonts = @import("fonts.zig");

a: std.mem.Allocator,
plane: nc.Plane,
parent: nc.Plane,
fire: ?Fire = null,
commands: Commands = undefined,
menu: *WidgetList,
menu_widget: Widget,

const Self = @This();

pub fn create(a: std.mem.Allocator, parent: Widget) !Widget {
    const self: *Self = try a.create(Self);
    var n = try nc.Plane.init(&(Widget.Box{}).opts("editor"), parent.plane.*);
    errdefer n.deinit();

    self.* = .{
        .a = a,
        .parent = parent.plane.*,
        .plane = n,
        .menu = undefined,
        .menu_widget = undefined,
    };
    try self.commands.init(self);
    const w = Widget.to(self);
    const menu = try WidgetList.createV(a, w, @typeName(Self), .{ .static = 32 });
    self.menu = menu;
    self.menu_widget = menu.widget();
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Help ······················· :h", .on_click = on_click_help, .on_render = render_menu_item }));
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Open file ·················· :o", .on_click = on_click_open_file, .on_render = render_menu_item }));
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Open recent file ····(wip)·· :e", .on_click = on_click_open_recent_file, .on_render = render_menu_item }));
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Open recent project ·(wip)·· :r", .on_click = on_click_open_recent_project, .on_render = render_menu_item }));
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Show/Run commands ···(wip)·· :p", .on_click = on_click_show_commands, .on_render = render_menu_item }));
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Open config file ··········· :c", .on_click = on_click_open_config, .on_render = render_menu_item }));
    try menu.add(try Button.create(a, parent.plane.*, .{ .on_layout = menu_layout, .label = "Quit/Close ················· :q", .on_click = on_click_quit, .on_render = render_menu_item }));
    menu.resize(.{ .y = 15, .x = 9, .w = 32, .h = menu.widgets.items.len });
    command.executeName("enter_mode", command.Context.fmt(.{"home"})) catch {};
    return w;
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    self.menu.deinit(a);
    self.commands.deinit();
    self.plane.deinit();
    if (self.fire) |*fire| fire.deinit();
    a.destroy(self);
}

pub fn update(self: *Self) void {
    self.menu.update();
}

pub fn walk(self: *Self, walk_ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.menu.walk(walk_ctx, f, &self.menu_widget) or f(walk_ctx, w);
}

pub fn receive(_: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var hover: bool = false;
    if (try m.match(.{ "H", tp.extract(&hover) })) {
        tui.current().request_mouse_cursor_default(hover);
        return true;
    }
    return false;
}

fn menu_layout(_: ?*anyopaque, _: *Button) Widget.Layout {
    return .{ .static = 1 };
}

pub fn on_click_help(_: ?*anyopaque, _: *Button) void {
    command.executeName("open_help", .{}) catch {};
}

pub fn on_click_open_file(_: ?*anyopaque, _: *Button) void {
    command.executeName("enter_open_file_mode", .{}) catch {};
}

pub fn on_click_open_recent_file(_: ?*anyopaque, _: *Button) void {
    tp.self_pid().send(.{ "log", "home", "open recent file not implemented" }) catch {};
}

pub fn on_click_open_recent_project(_: ?*anyopaque, _: *Button) void {
    tp.self_pid().send(.{ "log", "home", "open recent project not implemented" }) catch {};
}

pub fn on_click_show_commands(_: ?*anyopaque, _: *Button) void {
    tp.self_pid().send(.{ "log", "home", "open command palette not implemented" }) catch {};
}

pub fn on_click_open_config(_: ?*anyopaque, _: *Button) void {
    command.executeName("open_config", .{}) catch {};
}

pub fn on_click_quit(_: ?*anyopaque, _: *Button) void {
    command.executeName("quit", .{}) catch {};
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const more = self.menu.render(theme);

    tui.set_base_style(&self.plane, " ", theme.editor);
    self.plane.erase();
    self.plane.home();
    if (self.fire) |*fire| fire.render() catch unreachable;

    const style_title = if (tui.find_scope_style(theme, "function")) |sty| sty.style else theme.editor;
    const style_subtext = if (tui.find_scope_style(theme, "comment")) |sty| sty.style else theme.editor;

    const title = "Flow Control";
    const subtext = "a programmer's text editor";

    if (self.plane.dim_x() > 120 and self.plane.dim_y() > 22) {
        tui.set_style(&self.plane, style_title);
        self.plane.cursor_move_yx(2, 4) catch return more;
        fonts.print_string_large(self.plane, title) catch return more;

        tui.set_style(&self.plane, style_subtext);
        self.plane.cursor_move_yx(10, 8) catch return more;
        fonts.print_string_medium(self.plane, subtext) catch return more;

        self.menu.resize(.{ .y = 15, .x = 10, .w = 32, .h = self.menu.widgets.items.len });
    } else if (self.plane.dim_x() > 55 and self.plane.dim_y() > 16) {
        tui.set_style(&self.plane, style_title);
        self.plane.cursor_move_yx(2, 4) catch return more;
        fonts.print_string_medium(self.plane, title) catch return more;

        tui.set_style(&self.plane, style_subtext);
        self.plane.cursor_move_yx(7, 6) catch return more;
        _ = self.plane.print(subtext, .{}) catch {};

        self.menu.resize(.{ .y = 9, .x = 8, .w = 32, .h = self.menu.widgets.items.len });
    } else {
        tui.set_style(&self.plane, style_title);
        self.plane.cursor_move_yx(1, 4) catch return more;
        _ = self.plane.print(title, .{}) catch return more;

        tui.set_style(&self.plane, style_subtext);
        self.plane.cursor_move_yx(3, 6) catch return more;
        _ = self.plane.print(subtext, .{}) catch {};

        self.menu.resize(.{ .y = 5, .x = 8, .w = 32, .h = self.menu.widgets.items.len });
    }
    return true;
}

fn render_menu_item(_: ?*anyopaque, button: *Button, theme: *const Widget.Theme) bool {
    tui.set_base_style(&button.plane, " ", if (button.active) theme.editor_cursor else if (button.hover) theme.editor_selection else theme.editor);
    button.plane.erase();
    button.plane.home();
    const style_subtext = if (tui.find_scope_style(theme, "comment")) |sty| sty.style else theme.editor;
    const style_text = if (tui.find_scope_style(theme, "keyword")) |sty| sty.style else theme.editor;
    const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else theme.editor;
    const sep = std.mem.indexOfScalar(u8, button.opts.label, ':') orelse button.opts.label.len;
    tui.set_style(&button.plane, style_subtext);
    tui.set_style(&button.plane, style_text);
    _ = button.plane.print(" {s}", .{button.opts.label[0..sep]}) catch {};
    tui.set_style(&button.plane, style_keybind);
    _ = button.plane.print("{s}", .{button.opts.label[sep + 1 ..]}) catch {};
    return false;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    if (self.fire) |*fire| {
        fire.deinit();
        self.fire = Fire.init(self.a, self.plane, pos) catch unreachable;
    }
}

const Commands = command.Collection(cmds);

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;

    pub fn home_sheeran(self: *Self, _: Ctx) tp.result {
        self.fire = if (self.fire) |*fire| ret: {
            fire.deinit();
            break :ret null;
        } else Fire.init(self.a, self.plane, Widget.Box.from(self.plane)) catch |e| return tp.exit_error(e);
    }
};

const Fire = struct {
    const px = "▀";

    allocator: std.mem.Allocator,
    plane: nc.Plane,
    prng: std.rand.DefaultPrng,

    //scope cache - spread fire
    spread_px: u8 = 0,
    spread_rnd_idx: u8 = 0,
    spread_dst: u16 = 0,

    FIRE_H: u16,
    FIRE_W: u16,
    FIRE_SZ: u16,
    FIRE_LAST_ROW: u16,

    screen_buf: []u8,

    const MAX_COLOR = 256;
    const LAST_COLOR = MAX_COLOR - 1;

    fn init(a: std.mem.Allocator, plane: nc.Plane, pos: Widget.Box) !Fire {
        const FIRE_H = @as(u16, @intCast(pos.h)) * 2;
        const FIRE_W = @as(u16, @intCast(pos.w));
        var self: Fire = .{
            .allocator = a,
            .plane = plane,
            .prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            }),
            .FIRE_H = FIRE_H,
            .FIRE_W = FIRE_W,
            .FIRE_SZ = FIRE_H * FIRE_W,
            .FIRE_LAST_ROW = (FIRE_H - 1) * FIRE_W,
            .screen_buf = try a.alloc(u8, FIRE_H * FIRE_W),
        };

        var buf_idx: u16 = 0;
        while (buf_idx < self.FIRE_SZ) : (buf_idx += 1) {
            self.screen_buf[buf_idx] = fire_black;
        }

        // last row is white...white is "fire source"
        buf_idx = 0;
        while (buf_idx < self.FIRE_W) : (buf_idx += 1) {
            self.screen_buf[self.FIRE_LAST_ROW + buf_idx] = fire_white;
        }
        return self;
    }

    fn deinit(self: *Fire) void {
        self.allocator.free(self.screen_buf);
    }

    const fire_palette = [_]u8{ 0, 233, 234, 52, 53, 88, 89, 94, 95, 96, 130, 131, 132, 133, 172, 214, 215, 220, 220, 221, 3, 226, 227, 230, 195, 230 };
    const fire_black: u8 = 0;
    const fire_white: u8 = fire_palette.len - 1;

    fn render(self: *Fire) !void {
        var rand = self.prng.random();

        //update fire buf
        var doFire_x: u16 = 0;
        while (doFire_x < self.FIRE_W) : (doFire_x += 1) {
            var doFire_y: u16 = 0;
            while (doFire_y < self.FIRE_H) : (doFire_y += 1) {
                const doFire_idx: u16 = doFire_y * self.FIRE_W + doFire_x;

                //spread fire
                self.spread_px = self.screen_buf[doFire_idx];

                //bounds checking
                if ((self.spread_px == 0) and (doFire_idx >= self.FIRE_W)) {
                    self.screen_buf[doFire_idx - self.FIRE_W] = 0;
                } else {
                    self.spread_rnd_idx = rand.intRangeAtMost(u8, 0, 3);
                    if (doFire_idx >= (self.spread_rnd_idx + 1)) {
                        self.spread_dst = doFire_idx - self.spread_rnd_idx + 1;
                    } else {
                        self.spread_dst = doFire_idx;
                    }
                    if (self.spread_dst >= self.FIRE_W) {
                        if (self.spread_px > (self.spread_rnd_idx & 1)) {
                            self.screen_buf[self.spread_dst - self.FIRE_W] = self.spread_px - (self.spread_rnd_idx & 1);
                        } else {
                            self.screen_buf[self.spread_dst - self.FIRE_W] = 0;
                        }
                    }
                }
            }
        }

        //scope cache - fire 2 screen buffer
        var frame_x: u16 = 0;
        var frame_y: u16 = 0;

        // for each row
        frame_y = 0;
        while (frame_y < self.FIRE_H) : (frame_y += 2) { // 'paint' two rows at a time because of half height char
            // for each col
            frame_x = 0;
            while (frame_x < self.FIRE_W) : (frame_x += 1) {
                //each character rendered is actually to rows of 'pixels'
                // - "hi" (current px row => fg char)
                // - "low" (next row => bg color)
                const px_hi = self.screen_buf[frame_y * self.FIRE_W + frame_x];
                const px_lo = self.screen_buf[(frame_y + 1) * self.FIRE_W + frame_x];

                try self.plane.set_fg_palindex(fire_palette[px_hi]);
                try self.plane.set_bg_palindex(fire_palette[px_lo]);
                _ = try self.plane.putstr(px);
            }
            self.plane.cursor_move_yx(-1, 0) catch {};
            self.plane.cursor_move_rel(1, 0) catch {};
        }
    }
};
