const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");
const MouseEvent = @import("MouseEvent");
const build_options = @import("build_options");

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
closed: std.ArrayList(Closed) = .empty,
logger: log.Logger,
owner: ?Owner,
hints: ?*const tui.KeybindHints,

pub const Owner = struct {
    ctx: *anyopaque,
    on_close: *const fn (ctx: *anyopaque) void,
    on_cycle: *const fn (ctx: *anyopaque, direction: Direction) void,
};

pub const Direction = enum { prev, next };

const Closed = struct { menu: *const Menu, selected: ?usize };

pub const Anchor = struct {
    y: i32,
    x: i32,
    flip_x: i32,
    flip_y: ?i32 = null,
    offset_px: Widget.Pos = .{},
    flip_offset_px: Widget.Pos = .{},

    pub fn at(pos: Widget.Pos) Anchor {
        return .{ .y = pos.y, .x = pos.x, .flip_x = pos.x, .flip_y = pos.y };
    }

    pub fn below(pos: Widget.Pos) Anchor {
        if (!build_options.gui)
            return .{ .y = pos.y + 1, .x = pos.x, .flip_x = pos.x, .flip_y = pos.y };
        const cw: i32 = tui.plane().cell_x();
        const ch: i32 = tui.plane().cell_y();
        return .{
            .y = pos.y,
            .x = pos.x,
            .flip_x = pos.x,
            .flip_y = pos.y,
            .offset_px = .{ .y = @divFloor(ch * 3, 4), .x = @divFloor(cw, 2) },
            .flip_offset_px = .{ .y = @divFloor(ch, 4), .x = @divFloor(cw, 2) },
        };
    }
};

pub fn create(allocator: std.mem.Allocator, menu: *const Menu, anchor: Anchor, owner: ?Owner, hints: ?*const tui.KeybindHints) !tui.Mode {
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
        .hints = hints,
    };
    try self.commands.init(self);
    errdefer self.commands.deinit();
    self.mode.event_handler = EventHandler.to_owned(self);
    self.mode.name = "menu";
    try mv.floating_views.add(self.modal.widget());
    try self.open_level(menu, anchor);
    try tui.input_listeners().add(EventHandler.bind(self, listen));
    return self.mode;
}

pub fn deinit(self: *Self) void {
    tui.input_listeners().remove_ptr(self);
    self.commands.deinit();
    while (self.levels.items.len > 0) self.close_level();
    self.levels.deinit(self.allocator);
    self.closed.deinit(self.allocator);
    if (tui.mainview()) |mv| mv.floating_views.remove(self.modal.widget());
    self.logger.deinit();
    if (self.owner) |owner| owner.on_close(owner.ctx);
    self.allocator.destroy(self);
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}

fn listen(_: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.button_8, tp.more }))
        try tp.self_pid().send(.{ "cmd", "menu_cancel" })
    else if (try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.button_9, tp.more }))
        try tp.self_pid().send(.{ "cmd", "menu_reopen_submenu" });
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
    layer.z_index = @fromBackingInt(@intCast(@backingInt(Layer.Level.overlay) + @as(i32, @intCast(self.levels.items.len))));
    level.* = .{
        .popup = self,
        .menu = menu,
        .layer = layer,
        .label = menu.label,
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
    errdefer level.items.deinit(self.allocator);
    var it = menu.visible();
    while (it.next()) |item| try level.items.append(self.allocator, item);
    for (0..level.items.items.len) |pos| {
        var buf: [16]u8 = undefined;
        try level.list_box.add_item_with_handler(cbor.fmt(&buf, pos), Level.on_click);
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
    level.items.deinit(self.allocator);
    self.allocator.destroy(level);
}

fn close_submenu(self: *Self) void {
    const level = self.top();
    self.closed.append(self.allocator, .{ .menu = level.menu, .selected = level.list_box.selected }) catch {};
    self.close_level();
}

fn reopen_submenu(self: *Self) !void {
    const closed = self.closed.pop() orelse return;
    const level = self.top();
    const pos = for (level.items.items, 0..) |item, pos| switch (item.*) {
        .submenu => |submenu| if (submenu == closed.menu) break pos,
        else => {},
    } else return self.closed.clearRetainingCapacity();
    level.list_box.selected = pos;
    try self.open_submenu(self.levels.items.len - 1);
    self.top().list_box.selected = closed.selected;
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
    const pos = level.list_box.selected orelse return;
    const submenu = switch (level.items.items[pos].*) {
        .submenu => |submenu| submenu,
        else => return,
    };
    const box = level.layer.box;
    try self.open_level(submenu, .{
        .y = @intCast(box.y + pos),
        .x = @intCast(box.x + box.w),
        .flip_x = @intCast(box.x),
        .offset_px = level.offset_px,
        .flip_offset_px = level.offset_px,
    });
}

fn activate(self: *Self, level_idx: usize, pos: usize) !void {
    if (level_idx >= self.levels.items.len) return;
    const level = self.levels.items[level_idx];
    if (pos >= level.items.items.len) return;
    level.list_box.selected = pos;
    switch (level.items.items[pos].*) {
        .separator => self.close_levels_above(level_idx),
        .submenu => {
            self.closed.clearRetainingCapacity();
            try self.open_submenu(level_idx);
            self.top().select_first();
        },
        .command => |*cmd| {
            if (cmd.on_activate == .close_menu)
                try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
            try cmd.send();
        },
    }
}

fn get_hints(self: *const Self) ?*const tui.KeybindHints {
    if (self.hints) |hints| return hints;
    const mode = tui.input_mode_outer() orelse tui.input_mode() orelse return null;
    return mode.keybind_hints;
}

fn get_hint(hints: ?*const tui.KeybindHints, cmd: *const Menu.Command) []const u8 {
    if (cmd.has_args()) return "";
    const hint = (hints orelse return "").get(cmd.command) orelse return "";
    return hint[0 .. std.mem.indexOf(u8, hint, ", ") orelse hint.len];
}

const Level = struct {
    popup: *Self,
    menu: *const Menu,
    layer: *tui.WidgetLayerBox,
    list_box: *ListBox.State(*Level),
    anchor: Anchor,
    label: []const u8,
    items: std.ArrayList(*const Menu.Item) = .empty,
    width: usize = 0,
    has_icons: bool = false,
    offset_px: Widget.Pos = .{},

    const ListBoxType = ListBox.Options(*Level).ListBoxType;
    const ButtonType = ListBoxType.ButtonType;

    fn index(self: *const Level) usize {
        return std.mem.indexOfScalar(*Level, self.popup.levels.items, @constCast(self)) orelse 0;
    }

    fn command_label(self: *const Level, cmd: *const Menu.Command) []const u8 {
        const label = cmd.get_label();
        if (self.label.len == 0 or !std.mem.startsWith(u8, label, self.label)) return label;
        const rest = label[self.label.len..];
        return if (std.mem.startsWith(u8, rest, ": ")) rest[2..] else label;
    }

    fn item_pos(button: *ButtonType) ?usize {
        var pos: usize = undefined;
        return if (cbor.match(button.opts.label, cbor.extract(&pos)) catch false) pos else null;
    }

    fn measure(self: *Level) void {
        const hints = self.popup.get_hints();
        var label_w: usize = 0;
        var hint_w: usize = 0;
        for (self.items.items) |item| switch (item.*) {
            .separator => {},
            .command => |*cmd| {
                label_w = @max(label_w, tui.egc_chunk_width(self.command_label(cmd), 0, 1));
                hint_w = @max(hint_w, tui.egc_chunk_width(get_hint(hints, cmd), 0, 1));
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

    fn selectable(self: *const Level, pos: usize) bool {
        return self.items.items[pos].* != .separator;
    }

    fn select_first(self: *Level) void {
        self.list_box.selected = null;
        for (0..self.items.items.len) |pos| if (self.selectable(pos)) {
            self.list_box.selected = pos;
            return;
        };
    }

    fn select_last(self: *Level) void {
        self.list_box.selected = null;
        var pos = self.items.items.len;
        while (pos > 0) {
            pos -= 1;
            if (self.selectable(pos)) {
                self.list_box.selected = pos;
                return;
            }
        }
    }

    fn select_next(self: *Level, direction: enum { up, down }) void {
        const len = self.items.items.len;
        if (len == 0) return;
        var pos = self.list_box.selected orelse return switch (direction) {
            .down => self.select_first(),
            .up => self.select_last(),
        };
        for (0..len) |_| {
            pos = switch (direction) {
                .down => (pos + 1) % len,
                .up => (pos + len - 1) % len,
            };
            if (self.selectable(pos)) {
                self.list_box.selected = pos;
                return;
            }
        }
    }

    fn select_by_prefix(self: *Level, text: []const u8) void {
        const len = self.items.items.len;
        if (len == 0 or text.len == 0) return;
        const start = if (self.list_box.selected) |selected| selected + 1 else 0;
        for (0..len) |i| {
            const pos = (start + i) % len;
            const label = switch (self.items.items[pos].*) {
                .separator => continue,
                .command => |*cmd| self.command_label(cmd),
                .submenu => |submenu| submenu.label,
            };
            if (label.len >= text.len and std.ascii.eqlIgnoreCase(label[0..text.len], text)) {
                self.list_box.selected = pos;
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
        var box = self.prepare_resize(padding).from_client_box(padding);
        if (self.offset_px.x != 0 or self.offset_px.y != 0) {
            const cw: i32 = tui.plane().cell_x();
            const ch: i32 = tui.plane().cell_y();
            box.frame = .{
                .x = @as(i32, @intCast(box.x)) * cw + self.offset_px.x,
                .y = @as(i32, @intCast(box.y)) * ch + self.offset_px.y,
                .w = @as(i32, @intCast(box.w)) * cw,
                .h = @as(i32, @intCast(box.h)) * ch,
            };
        }
        return box;
    }

    fn prepare_resize(self: *Level, padding: Widget.Style.Margin) Widget.Box {
        const screen = tui.screen();
        const pl: i32 = @intCast(padding.left);
        const pr: i32 = @intCast(padding.right);
        const pt: i32 = @intCast(padding.top);
        const pb: i32 = @intCast(padding.bottom);
        const w: i32 = @intCast(@min(self.width, screen.w -| (padding.left + padding.right)));
        const h: i32 = @intCast(@min(self.items.items.len, screen.h -| (padding.top + padding.bottom)));
        const screen_w: i32 = @intCast(screen.w);
        const screen_h: i32 = @intCast(screen.h);
        const anchor = self.anchor;
        const spare_x: i32 = if (anchor.offset_px.x > 0) 1 else 0;
        const spare_y: i32 = if (anchor.offset_px.y > 0) 1 else 0;
        self.offset_px = .{};
        var x = anchor.x + pl;
        if (x + spare_x + w + pr <= screen_w) {
            self.offset_px.x = anchor.offset_px.x;
        } else {
            const flipped = anchor.flip_x - pr - w;
            if (flipped >= pl) {
                x = flipped;
                self.offset_px.x = anchor.flip_offset_px.x;
            } else x = screen_w - w - pr;
        }
        x = @max(pl, @min(x, screen_w - w - pr));
        var y = anchor.y + pt;
        if (y + spare_y + h + pb <= screen_h) {
            self.offset_px.y = anchor.offset_px.y;
        } else if (anchor.flip_y) |flip_y| {
            const flipped = flip_y - pb - h;
            if (flipped >= pt) {
                y = flipped;
                self.offset_px.y = anchor.flip_offset_px.y;
            }
        }
        y = @max(pt, @min(y, screen_h - h - pb));
        return .{ .y = @intCast(y), .x = @intCast(x), .w = @intCast(w), .h = @intCast(h) };
    }

    fn on_click(list_box: **ListBoxType, button: *ButtonType, _: Widget.Pos) void {
        const self = list_box.*.opts.ctx;
        const pos = item_pos(button) orelse return;
        tp.self_pid().send(.{ "cmd", "menu_activate_item", .{ self.index(), pos } }) catch |e|
            self.popup.logger.err("click", e);
    }

    fn on_render(self: *Level, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
        const pos = item_pos(button) orelse return false;
        if (pos >= self.items.items.len) return false;
        const style_base = theme.editor_widget;
        button.plane.set_base_style(style_base);
        button.plane.erase();
        button.plane.home();
        const label, const icon, const hint = switch (self.items.items[pos].*) {
            .separator => {
                button.plane.set_style(.{ .fg = theme.editor_widget_border.fg, .bg = style_base.bg });
                button.plane.fill("─");
                return false;
            },
            .command => |*cmd| .{
                self.command_label(cmd),
                cmd.get_icon(),
                get_hint(self.popup.get_hints(), cmd),
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
        const pos = self.top().list_box.selected orelse return;
        if (self.top().items.items[pos].* == .submenu)
            try self.activate(level_idx, pos)
        else if (self.owner) |owner|
            owner.on_cycle(owner.ctx, .next);
    }
    pub const menu_open_submenu_meta: Meta = .{};

    pub fn menu_close_submenu(self: *Self, _: Ctx) Result {
        if (self.levels.items.len > 1)
            self.close_submenu()
        else if (self.owner) |owner|
            owner.on_cycle(owner.ctx, .prev);
    }
    pub const menu_close_submenu_meta: Meta = .{};

    pub fn menu_activate(self: *Self, _: Ctx) Result {
        const pos = self.top().list_box.selected orelse return;
        try self.activate(self.levels.items.len - 1, pos);
    }
    pub const menu_activate_meta: Meta = .{};

    pub fn menu_activate_item(self: *Self, ctx: Ctx) Result {
        var level_idx: usize = 0;
        var pos: usize = 0;
        if (!try ctx.args.match(.{ tp.extract(&level_idx), tp.extract(&pos) }))
            return error.InvalidMenuActivateItemArgument;
        try self.activate(level_idx, pos);
    }
    pub const menu_activate_item_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    pub fn menu_cancel(self: *Self, _: Ctx) Result {
        if (self.levels.items.len > 1)
            self.close_submenu()
        else
            try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
    }
    pub const menu_cancel_meta: Meta = .{};

    pub fn menu_reopen_submenu(self: *Self, _: Ctx) Result {
        try self.reopen_submenu();
    }
    pub const menu_reopen_submenu_meta: Meta = .{};

    pub fn menu_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidMenuInsertBytesArgument;
        self.top().select_by_prefix(bytes);
    }
    pub const menu_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };
};
