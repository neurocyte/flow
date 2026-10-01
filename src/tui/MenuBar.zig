const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const log = @import("log");
const command = @import("command");
const Plane = @import("renderer").Plane;
const Layer = @import("renderer").Layer;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Button = @import("Button.zig");
const Menu = @import("Menu.zig");
const MenuPopup = @import("mode/overlay/MenuPopup.zig");

const Self = @This();
const separator_glyph = "│";

allocator: Allocator,
list: *WidgetList,
menu: *const Menu,
layer: ?*tui.WidgetLayerBox = null,
open_idx: ?usize = null,
pending_idx: ?usize = null,
commands: command.Collection(cmds) = undefined,
logger: log.Logger,

const Item = struct {
    bar: *Self,
    idx: usize,
};
const ButtonType = Button.Options(Item).ButtonType;

pub fn create(allocator: Allocator, parent: Plane, menu: *const Menu) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const list = try WidgetList.createH(allocator, parent, "menu_bar", .{ .static = 1 });
    errdefer list.deinit(allocator);
    self.* = .{
        .allocator = allocator,
        .list = list,
        .menu = menu,
        .logger = log.logger("menu_bar"),
    };
    list.ctx = self;
    list.on_render = render_bar;
    list.on_deinit = free_from_list;
    list.render_decoration = null;
    for (0..menu.items.len) |idx|
        try list.add(try Button.create_widget(Item, allocator, list.plane, .{
            .ctx = .{ .bar = self, .idx = idx },
            .label = "",
            .on_click = on_click,
            .on_layout = layout,
            .on_render = render,
        }));
    try self.commands.init(self);
    return self;
}

fn free_from_list(ctx: ?*anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx.?));
    self.commands.deinit();
    self.logger.deinit();
    self.allocator.destroy(self);
}

pub fn widget(self: *Self) Widget {
    return self.list.widget();
}

pub fn is_visible(self: *const Self) bool {
    return self.list.plane.dim_x() > 0 and self.list.plane.dim_y() > 0;
}

pub fn open_first(self: *Self) void {
    const idx = self.next_submenu(self.menu.items.len - 1, .next) orelse return;
    self.open(idx);
}

fn next_submenu(self: *const Self, from: usize, direction: MenuPopup.Direction) ?usize {
    const len = self.menu.items.len;
    if (len == 0) return null;
    var idx = from;
    for (0..len) |_| {
        idx = switch (direction) {
            .next => (idx + 1) % len,
            .prev => (idx + len - 1) % len,
        };
        if (self.menu.items[idx] == .submenu and self.is_shown(idx)) return idx;
    }
    return null;
}

fn is_shown(self: *const Self, idx: usize) bool {
    var it = self.menu.visible();
    while (it.next()) |item| if (item == &self.menu.items[idx]) return true;
    return false;
}

fn button(self: *const Self, idx: usize) ?*ButtonType {
    if (idx >= self.list.widgets.items.len) return null;
    return self.list.widgets.items[idx].widget.dynamic_cast(ButtonType);
}

fn open(self: *Self, idx: usize) void {
    const submenu = switch (self.menu.items[idx]) {
        .submenu => |submenu| submenu,
        else => return,
    };
    const btn = self.button(idx) orelse return;
    const y, const x = btn.plane.global_yx();
    tui.open_menu(submenu, .{
        .y = y + btn.plane.dim_y(),
        .x = x,
        .flip_x = x + btn.plane.dim_x(),
    }, .{
        .ctx = self,
        .on_close = on_popup_close,
        .on_cycle = on_popup_cycle,
    }) catch |e| return self.logger.err("open", e);
    self.open_idx = idx;
    self.set_raised(true);
}

fn open_async(self: *Self, idx: usize) void {
    self.pending_idx = idx;
    tp.self_pid().send(.{ "cmd", "menu_bar_open", .{idx} }) catch |e| self.logger.err("open", e);
}

fn set_raised(self: *Self, raised: bool) void {
    const layer = self.layer orelse return;
    const z: Layer.Level = if (raised) .overlay else .topbar;
    layer.z_index = z;
    layer.layer.z_index = z;
    tui.need_render(@src());
}

fn on_popup_close(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.open_idx = null;
    self.set_raised(false);
}

fn on_popup_cycle(ctx: *anyopaque, direction: MenuPopup.Direction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const current = self.open_idx orelse return;
    const idx = self.next_submenu(current, direction) orelse return;
    if (idx != current) self.open_async(idx);
}

fn on_click(item: *Item, _: *ButtonType, _: Widget.Pos) void {
    const self = item.bar;
    if (!self.is_shown(item.idx)) return;
    switch (self.menu.items[item.idx]) {
        .separator => {},
        .submenu => if (self.open_idx == item.idx)
            tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch {}
        else
            self.open(item.idx),
        .command => |*cmd| {
            if (self.open_idx != null and cmd.on_activate == .close_menu)
                tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch {};
            cmd.send() catch |e| self.logger.err("command", e);
        },
    }
}

fn label(self: *const Self, idx: usize) []const u8 {
    return switch (self.menu.items[idx]) {
        .separator => separator_glyph,
        .command => |*cmd| cmd.get_label(),
        .submenu => |submenu| submenu.label,
    };
}

fn layout(item: *Item, _: *ButtonType) Widget.Layout {
    const self = item.bar;
    if (!self.is_shown(item.idx)) return .{ .static = 0 };
    return .{ .static = tui.egc_chunk_width(self.label(item.idx), 0, 1) + 2 };
}

fn render_bar(ctx: ?*anyopaque, theme: *const Widget.Theme) void {
    const self: *Self = @ptrCast(@alignCast(ctx.?));
    self.list.plane.set_base_style(theme.tab_inactive);
    self.list.plane.erase();
    self.list.plane.home();
    self.list.plane.set_style(theme.tab_inactive);
    self.list.plane.fill(" ");
}

fn render(item: *Item, btn: *ButtonType, theme: *const Widget.Theme) bool {
    const self = item.bar;
    if (!self.is_shown(item.idx)) return false;
    const is_open = self.open_idx == item.idx;
    if (self.open_idx) |open_idx| if (btn.hover and open_idx != item.idx and
        self.menu.items[item.idx] == .submenu and self.pending_idx != item.idx)
        self.open_async(item.idx);
    const style = switch (self.menu.items[item.idx]) {
        .separator => Widget.Theme.Style{ .fg = theme.tab_inactive.fg, .bg = theme.tab_inactive.bg },
        else => if (btn.active)
            theme.editor_cursor
        else if (is_open)
            theme.editor_selection
        else if (btn.hover)
            theme.statusbar_hover
        else
            theme.tab_inactive,
    };
    btn.plane.set_base_style(theme.tab_inactive);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(style);
    btn.plane.fill(" ");
    btn.plane.home();
    _ = btn.plane.print(" {s} ", .{self.label(item.idx)}) catch {};
    return false;
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn menu_bar_open(self: *Self, ctx: Ctx) Result {
        var idx: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&idx)}))
            return error.InvalidMenuBarOpenArgument;
        self.pending_idx = null;
        if (idx >= self.menu.items.len or self.open_idx == idx or !self.is_shown(idx)) return;
        self.open(idx);
    }
    pub const menu_bar_open_meta: Meta = .{ .arguments = &.{.integer} };
};
