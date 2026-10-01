const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const Widget = @import("../../Widget.zig");
const ListBox = @import("../../ListBox.zig");
const ModalBackground = @import("../../ModalBackground.zig");
const Menu = @import("../../Menu.zig");
const Layer = @import("renderer").Layer;

const Self = @This();
const module_name = @typeName(Self);
const widget_type: Widget.Type = .menu;
const submenu_hint = "▸";
const icon_column = 3;

allocator: std.mem.Allocator,
mode: keybind.Mode,
commands: command.Collection(cmds) = undefined,
modal: *ModalBackground.State(*Self),
levels: std.ArrayList(*Level) = .empty,
logger: log.Logger,
owner: ?Owner,

pub const Owner = struct {
    ctx: *anyopaque,
    on_close: *const fn (ctx: *anyopaque) void,
    on_cycle: *const fn (ctx: *anyopaque, direction: Direction) void,
};

pub const Direction = enum { prev, next };

pub const Anchor = struct {
    y: i32,
    x: i32,
    flip_x: i32,

    pub fn at(pos: Widget.Pos) Anchor {
        return .{ .y = pos.y, .x = pos.x, .flip_x = pos.x };
    }
};

pub fn create(allocator: std.mem.Allocator, menu: *const Menu, anchor: Anchor, owner: ?Owner) !tui.Mode {
    const mv = tui.mainview() orelse return error.NotFound;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .mode = try keybind.mode("overlay/menu", allocator, .{
            .insert_command = "menu_insert_bytes",
        }),
        .modal = try ModalBackground.create(*Self, allocator, tui.mainview_widget(), .{
            .ctx = self,
            .effect = .none,
        }),
        .logger = log.logger(module_name),
        .owner = owner,
    };
    try self.commands.init(self);
    errdefer self.commands.deinit();
    self.mode.event_handler = EventHandler.to_owned(self);
    self.mode.name = "menu";
    try mv.floating_views.add(self.modal.widget());
    try self.open_level(menu, anchor);
    return self.mode;
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    while (self.levels.items.len > 0) self.close_level();
    self.levels.deinit(self.allocator);
    if (tui.mainview()) |mv| mv.floating_views.remove(self.modal.widget());
    self.logger.deinit();
    if (self.owner) |owner| owner.on_close(owner.ctx);
    self.allocator.destroy(self);
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}

fn open_level(self: *Self, menu: *const Menu, anchor: Anchor) !void {
    const mv = tui.mainview() orelse return error.NotFound;
    const level = try self.allocator.create(Level);
    errdefer self.allocator.destroy(level);
    const layer = try tui.WidgetLayerBox.create(self.allocator, tui.plane(), .{ .name = "menu.layer" });
    errdefer layer.deinit(self.allocator);
    layer.blend = .src_over_blur;
    layer.alpha = tui.palette_opacity();
    layer.radius = 8;
    layer.shadow = .{};
    layer.z_index = @enumFromInt(@intFromEnum(Layer.Level.overlay) + @as(i32, @intCast(self.levels.items.len)));
    level.* = .{
        .popup = self,
        .menu = menu,
        .layer = layer,
        .list_box = try ListBox.create(*Level, self.allocator, layer.inner_plane(), .{
            .ctx = level,
            .style = widget_type,
            .on_render = Level.on_render,
        }),
        .anchor = anchor,
    };
    layer.ctx = level;
    layer.prepare_resize = Level.prepare_resize_layer;
    layer.set(level.list_box.container_widget);
    for (0..menu.items.len) |idx| {
        var buf: [16]u8 = undefined;
        try level.list_box.add_item_with_handler(cbor.fmt(&buf, idx), Level.on_click);
    }
    level.measure();
    level.select_first();
    try self.levels.ensureUnusedCapacity(self.allocator, 1);
    try mv.floating_views.add(layer.widget());
    self.levels.appendAssumeCapacity(level);
    level.resize();
}

fn close_level(self: *Self) void {
    const level = self.levels.pop() orelse return;
    if (tui.mainview()) |mv| mv.floating_views.remove(level.layer.widget());
    self.allocator.destroy(level);
}

fn close_levels_above(self: *Self, level_idx: usize) void {
    while (self.levels.items.len > level_idx + 1) self.close_level();
}

fn top(self: *Self) *Level {
    return self.levels.items[self.levels.items.len - 1];
}

fn open_submenu(self: *Self, level_idx: usize) !void {
    self.close_levels_above(level_idx);
    const level = self.levels.items[level_idx];
    const idx = level.list_box.selected orelse return;
    const submenu = switch (level.menu.items[idx]) {
        .submenu => |submenu| submenu,
        else => return,
    };
    const box = level.layer.box;
    try self.open_level(submenu, .{
        .y = @intCast(box.y + idx),
        .x = @intCast(box.x + box.w),
        .flip_x = @intCast(box.x),
    });
}

fn activate(self: *Self, level_idx: usize, idx: usize) !void {
    if (level_idx >= self.levels.items.len) return;
    const level = self.levels.items[level_idx];
    if (idx >= level.menu.items.len) return;
    level.list_box.selected = idx;
    switch (level.menu.items[idx]) {
        .separator => self.close_levels_above(level_idx),
        .submenu => {
            try self.open_submenu(level_idx);
            self.top().select_first();
        },
        .command => |*cmd| {
            try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
            try cmd.send();
        },
    }
}

fn get_hints() ?*const tui.KeybindHints {
    const mode = tui.input_mode_outer() orelse tui.input_mode() orelse return null;
    return mode.keybind_hints;
}

fn get_hint(hints: ?*const tui.KeybindHints, command_name: []const u8) []const u8 {
    const hint = (hints orelse return "").get(command_name) orelse return "";
    return hint[0 .. std.mem.indexOf(u8, hint, ", ") orelse hint.len];
}

const Level = struct {
    popup: *Self,
    menu: *const Menu,
    layer: *tui.WidgetLayerBox,
    list_box: *ListBox.State(*Level),
    anchor: Anchor,
    width: usize = 0,
    has_icons: bool = false,

    const ListBoxType = ListBox.Options(*Level).ListBoxType;
    const ButtonType = ListBoxType.ButtonType;

    fn index(self: *const Level) usize {
        return std.mem.indexOfScalar(*Level, self.popup.levels.items, @constCast(self)) orelse 0;
    }

    fn item_index(button: *ButtonType) ?usize {
        var idx: usize = undefined;
        return if (cbor.match(button.opts.label, cbor.extract(&idx)) catch false) idx else null;
    }

    fn measure(self: *Level) void {
        const hints = get_hints();
        var label_w: usize = 0;
        var hint_w: usize = 0;
        for (self.menu.items) |*item| switch (item.*) {
            .separator => {},
            .command => |*cmd| {
                label_w = @max(label_w, tui.egc_chunk_width(cmd.get_label(), 0, 1));
                hint_w = @max(hint_w, tui.egc_chunk_width(get_hint(hints, cmd.command), 0, 1));
                if (cmd.get_icon()) |_| self.has_icons = true;
            },
            .submenu => |submenu| {
                label_w = @max(label_w, tui.egc_chunk_width(submenu.label, 0, 1));
                hint_w = @max(hint_w, tui.egc_chunk_width(submenu_hint, 0, 1));
            },
        };
        const icon_w: usize = if (self.has_icons) icon_column else 0;
        const hint_gap: usize = if (hint_w > 0) 3 else 0;
        self.width = 1 + icon_w + label_w + hint_gap + hint_w + 1;
    }

    fn selectable(self: *const Level, idx: usize) bool {
        return self.menu.items[idx] != .separator;
    }

    fn select_first(self: *Level) void {
        self.list_box.selected = null;
        for (0..self.menu.items.len) |idx| if (self.selectable(idx)) {
            self.list_box.selected = idx;
            return;
        };
    }

    fn select_last(self: *Level) void {
        self.list_box.selected = null;
        var idx = self.menu.items.len;
        while (idx > 0) {
            idx -= 1;
            if (self.selectable(idx)) {
                self.list_box.selected = idx;
                return;
            }
        }
    }

    fn select_next(self: *Level, direction: enum { up, down }) void {
        const len = self.menu.items.len;
        if (len == 0) return;
        var idx = self.list_box.selected orelse return switch (direction) {
            .down => self.select_first(),
            .up => self.select_last(),
        };
        for (0..len) |_| {
            idx = switch (direction) {
                .down => (idx + 1) % len,
                .up => (idx + len - 1) % len,
            };
            if (self.selectable(idx)) {
                self.list_box.selected = idx;
                return;
            }
        }
    }

    fn select_by_prefix(self: *Level, text: []const u8) void {
        const len = self.menu.items.len;
        if (len == 0 or text.len == 0) return;
        const start = if (self.list_box.selected) |selected| selected + 1 else 0;
        for (0..len) |i| {
            const idx = (start + i) % len;
            const label = switch (self.menu.items[idx]) {
                .separator => continue,
                .command => |*cmd| cmd.get_label(),
                .submenu => |submenu| submenu.label,
            };
            if (label.len >= text.len and std.ascii.eqlIgnoreCase(label[0..text.len], text)) {
                self.list_box.selected = idx;
                return;
            }
        }
    }

    fn resize(self: *Level) void {
        self.layer.handle_resize(.{});
    }

    fn prepare_resize_layer(ctx_: ?*anyopaque, _: *tui.WidgetLayerBox, _: Widget.Box) Widget.Box {
        const self: *Level = @ptrCast(@alignCast(ctx_.?));
        const padding = tui.get_widget_style(widget_type).padding;
        return self.prepare_resize(padding).from_client_box(padding);
    }

    fn prepare_resize(self: *Level, padding: Widget.Style.Margin) Widget.Box {
        const screen = tui.screen();
        const pl: i32 = @intCast(padding.left);
        const pr: i32 = @intCast(padding.right);
        const pt: i32 = @intCast(padding.top);
        const pb: i32 = @intCast(padding.bottom);
        const w: i32 = @intCast(@min(self.width, screen.w -| (padding.left + padding.right)));
        const h: i32 = @intCast(@min(self.menu.items.len, screen.h -| (padding.top + padding.bottom)));
        const screen_w: i32 = @intCast(screen.w);
        const screen_h: i32 = @intCast(screen.h);
        var x = self.anchor.x + pl;
        if (x + w + pr > screen_w) {
            const flipped = self.anchor.flip_x - pr - w;
            x = if (flipped >= pl) flipped else screen_w - w - pr;
        }
        x = @max(pl, @min(x, screen_w - w - pr));
        const y = @max(pt, @min(self.anchor.y + pt, screen_h - h - pb));
        return .{ .y = @intCast(y), .x = @intCast(x), .w = @intCast(w), .h = @intCast(h) };
    }

    fn on_click(list_box: **ListBoxType, button: *ButtonType, _: Widget.Pos) void {
        const self = list_box.*.opts.ctx;
        const idx = item_index(button) orelse return;
        tp.self_pid().send(.{ "cmd", "menu_activate_item", .{ self.index(), idx } }) catch |e|
            self.popup.logger.err("click", e);
    }

    fn on_render(self: *Level, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
        const idx = item_index(button) orelse return false;
        if (idx >= self.menu.items.len) return false;
        const style_base = theme.editor_widget;
        button.plane.set_base_style(style_base);
        button.plane.erase();
        button.plane.home();
        const label, const icon, const hint = switch (self.menu.items[idx]) {
            .separator => {
                button.plane.set_style(.{ .fg = theme.editor_widget_border.fg, .bg = style_base.bg });
                button.plane.fill("─");
                return false;
            },
            .command => |*cmd| .{
                cmd.get_label(),
                cmd.get_icon(),
                get_hint(get_hints(), cmd.command),
            },
            .submenu => |submenu| .{ submenu.label, null, submenu_hint },
        };
        const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else style_base;
        const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
        button.plane.set_style(style_label);
        button.plane.fill(" ");
        button.plane.home();
        _ = button.plane.putstr(" ") catch {};
        if (icon) |icon_| _ = button.plane.putstr(icon_) catch {};
        if (self.has_icons) button.plane.cursor_move_yx(0, 1 + icon_column);
        _ = button.plane.putstr(label) catch {};
        button.plane.set_style(style_hint);
        _ = button.plane.print_aligned_right(0, "{s} ", .{hint}) catch {};
        return false;
    }
};

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn menu_down(self: *Self, _: Ctx) Result {
        self.top().select_next(.down);
    }
    pub const menu_down_meta: Meta = .{};

    pub fn menu_up(self: *Self, _: Ctx) Result {
        self.top().select_next(.up);
    }
    pub const menu_up_meta: Meta = .{};

    pub fn menu_first(self: *Self, _: Ctx) Result {
        self.top().select_first();
    }
    pub const menu_first_meta: Meta = .{};

    pub fn menu_last(self: *Self, _: Ctx) Result {
        self.top().select_last();
    }
    pub const menu_last_meta: Meta = .{};

    pub fn menu_open_submenu(self: *Self, _: Ctx) Result {
        const level_idx = self.levels.items.len - 1;
        const idx = self.top().list_box.selected orelse return;
        if (self.top().menu.items[idx] == .submenu)
            try self.activate(level_idx, idx)
        else if (self.owner) |owner|
            owner.on_cycle(owner.ctx, .next);
    }
    pub const menu_open_submenu_meta: Meta = .{};

    pub fn menu_close_submenu(self: *Self, _: Ctx) Result {
        if (self.levels.items.len > 1)
            self.close_level()
        else if (self.owner) |owner|
            owner.on_cycle(owner.ctx, .prev);
    }
    pub const menu_close_submenu_meta: Meta = .{};

    pub fn menu_activate(self: *Self, _: Ctx) Result {
        const idx = self.top().list_box.selected orelse return;
        try self.activate(self.levels.items.len - 1, idx);
    }
    pub const menu_activate_meta: Meta = .{};

    pub fn menu_activate_item(self: *Self, ctx: Ctx) Result {
        var level_idx: usize = 0;
        var idx: usize = 0;
        if (!try ctx.args.match(.{ tp.extract(&level_idx), tp.extract(&idx) }))
            return error.InvalidMenuActivateItemArgument;
        try self.activate(level_idx, idx);
    }
    pub const menu_activate_item_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    pub fn menu_cancel(self: *Self, _: Ctx) Result {
        if (self.levels.items.len > 1)
            self.close_level()
        else
            try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
    }
    pub const menu_cancel_meta: Meta = .{};

    pub fn menu_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidMenuInsertBytesArgument;
        self.top().select_by_prefix(bytes);
    }
    pub const menu_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };
};
