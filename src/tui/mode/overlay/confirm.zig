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

const Self = @This();
const module_name = @typeName(Self);
const widget_type: Widget.Type = .dialog;

pub const Options = struct {
    message: []const u8,
    confirm_label: []const u8 = "Yes",
    cancel_label: []const u8 = "Cancel",
    /// message sent to the tui when the user confirms
    on_confirm: cbor.Raw,
    /// message sent to the tui when the dialog closes in any other way
    on_cancel: ?cbor.Raw = null,
};

const Row = union(enum) {
    text: []const u8,
    separator,
    confirm,
    cancel,
};

allocator: std.mem.Allocator,
mode: keybind.Mode,
commands: command.Collection(cmds) = undefined,
modal: *ModalBackground.State(*Self),
layer: *tui.WidgetLayerBox,
list_box: *ListBox.State(*Self),
logger: log.Logger,
arena: std.heap.ArenaAllocator,
options: Options,
rows: std.ArrayList(Row) = .empty,
width: usize = 0,
confirmed: bool = false,

const ListBoxType = ListBox.Options(*Self).ListBoxType;
const ButtonType = ListBoxType.ButtonType;

pub fn create(allocator: std.mem.Allocator, options: Options) !tui.Mode {
    const mv = tui.mainview() orelse return error.NotFound;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const layer = try tui.WidgetLayerBox.create(allocator, tui.plane(), .{ .name = "confirm.layer" });
    errdefer layer.deinit(allocator);
    layer.blend = .src_over_blur;
    layer.alpha = tui.palette_opacity();
    layer.radius = 8;
    layer.shadow = .{};
    self.* = .{
        .allocator = allocator,
        .mode = try keybind.mode("overlay/confirm", allocator, .{
            .insert_command = "confirm_insert_bytes",
        }),
        .modal = try ModalBackground.create(*Self, allocator, tui.mainview_widget(), .{ .ctx = self }),
        .layer = layer,
        .list_box = try ListBox.create(*Self, allocator, layer.inner_plane(), .{
            .ctx = self,
            .style = widget_type,
            .on_render = on_render,
        }),
        .logger = log.logger(module_name),
        .arena = arena,
        .options = .{
            .message = try a.dupe(u8, options.message),
            .confirm_label = try a.dupe(u8, options.confirm_label),
            .cancel_label = try a.dupe(u8, options.cancel_label),
            .on_confirm = .{ .bytes = try a.dupe(u8, options.on_confirm.bytes) },
            .on_cancel = if (options.on_cancel) |msg| .{ .bytes = try a.dupe(u8, msg.bytes) } else null,
        },
    };
    try self.commands.init(self);
    errdefer self.commands.deinit();
    self.mode.event_handler = EventHandler.to_owned(self);
    self.mode.name = "confirm";

    var lines = std.mem.splitScalar(u8, self.options.message, '\n');
    while (lines.next()) |line| try self.rows.append(self.arena.allocator(), .{ .text = line });
    try self.rows.append(self.arena.allocator(), .separator);
    try self.rows.append(self.arena.allocator(), .confirm);
    try self.rows.append(self.arena.allocator(), .cancel);
    for (self.rows.items, 0..) |row, pos| {
        var buf: [16]u8 = undefined;
        try self.list_box.add_item_with_handler(cbor.fmt(&buf, pos), on_click);
        self.width = @max(self.width, tui.egc_chunk_width(self.row_label(row), 0, 1) + 2);
    }
    // the safe choice is selected first
    self.list_box.selected = self.rows.items.len - 1;

    layer.ctx = self;
    layer.prepare_resize = prepare_resize_layer;
    layer.set(self.list_box.container_widget);
    try mv.floating_views.add(self.modal.widget());
    try mv.floating_views.add(layer.widget());
    layer.handle_resize(.{});
    return self.mode;
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    if (tui.mainview()) |mv| {
        mv.floating_views.remove(self.layer.widget());
        mv.floating_views.remove(self.modal.widget());
    }
    if (!self.confirmed) if (self.options.on_cancel) |msg|
        tp.self_pid().send_raw(.{ .buf = msg.bytes }) catch {};
    self.logger.deinit();
    self.arena.deinit();
    self.allocator.destroy(self);
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}

fn row_label(self: *const Self, row: Row) []const u8 {
    return switch (row) {
        .text => |text| text,
        .separator => "",
        .confirm => self.options.confirm_label,
        .cancel => self.options.cancel_label,
    };
}

fn selectable(row: Row) bool {
    return row == .confirm or row == .cancel;
}

fn select(self: *Self, choice: std.meta.Tag(Row)) void {
    for (self.rows.items, 0..) |row, pos| if (row == choice) {
        self.list_box.selected = pos;
    };
}

fn activate(self: *Self, pos: usize) !void {
    if (pos >= self.rows.items.len) return;
    switch (self.rows.items[pos]) {
        .text, .separator => return,
        .confirm => {
            self.confirmed = true;
            const on_confirm = try self.allocator.dupe(u8, self.options.on_confirm.bytes);
            defer self.allocator.free(on_confirm);
            try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
            try tp.self_pid().send_raw(.{ .buf = on_confirm });
        },
        .cancel => try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }),
    }
}

fn prepare_resize_layer(ctx_: ?*anyopaque, _: *tui.WidgetLayerBox, _: Widget.Box) Widget.Box {
    const self: *Self = @ptrCast(@alignCast(ctx_.?));
    const padding = tui.get_widget_style(widget_type).padding;
    const screen = tui.screen();
    const w = @min(self.width, screen.w -| (padding.left + padding.right));
    const h = @min(self.rows.items.len, screen.h -| (padding.top + padding.bottom));
    const box: Widget.Box = .{
        .y = (screen.h -| h) / 2,
        .x = (screen.w -| w) / 2,
        .w = w,
        .h = h,
    };
    return box.from_client_box(padding);
}

fn item_pos(button: *ButtonType) ?usize {
    var pos: usize = undefined;
    return if (cbor.match(button.opts.label, cbor.extract(&pos)) catch false) pos else null;
}

fn on_click(list_box: **ListBoxType, button: *ButtonType, _: Widget.Pos) void {
    const self = list_box.*.opts.ctx;
    const pos = item_pos(button) orelse return;
    self.activate(pos) catch |e| self.logger.err("click", e);
}

fn on_render(self: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    const pos = item_pos(button) orelse return false;
    if (pos >= self.rows.items.len) return false;
    const row = self.rows.items[pos];
    const style_base = theme.editor_widget;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    if (row == .separator) {
        button.plane.set_style(.{ .fg = theme.editor_widget_border.fg, .bg = style_base.bg });
        button.plane.fill("─");
        return false;
    }
    const highlight = selectable(row) and (button.hover or selected);
    button.plane.set_style(if (selectable(row) and button.active) theme.editor_cursor else if (highlight) theme.editor_selection else style_base);
    button.plane.fill(" ");
    button.plane.home();
    _ = button.plane.putstr(" ") catch {};
    _ = button.plane.putstr(self.row_label(row)) catch {};
    return false;
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn confirm_toggle(self: *Self, _: Ctx) Result {
        const pos = self.list_box.selected orelse return self.select(.cancel);
        self.select(if (self.rows.items[pos] == .confirm) .cancel else .confirm);
    }
    pub const confirm_toggle_meta: Meta = .{};

    pub fn confirm_activate(self: *Self, _: Ctx) Result {
        try self.activate(self.list_box.selected orelse return);
    }
    pub const confirm_activate_meta: Meta = .{};

    pub fn confirm_cancel(_: *Self, _: Ctx) Result {
        try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
    }
    pub const confirm_cancel_meta: Meta = .{};

    pub fn confirm_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidConfirmInsertBytesArgument;
        if (bytes.len == 0) return;
        for ([_]std.meta.Tag(Row){ .confirm, .cancel }) |choice| {
            const label = self.row_label(if (choice == .confirm) .confirm else .cancel);
            if (label.len > 0 and std.ascii.toLower(label[0]) == std.ascii.toLower(bytes[0])) {
                self.select(choice);
                return;
            }
        }
    }
    pub const confirm_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };
};
