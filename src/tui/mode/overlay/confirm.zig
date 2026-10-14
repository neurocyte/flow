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

pub const Severity = enum { info, warning, err };

pub const Choice = struct {
    label: []const u8,
    /// message sent to the tui when the user activates this choice
    action: cbor.Raw,
    severity: Severity = .info,
    /// selected when the dialog opens, cancel is selected if no choice sets this
    default: bool = false,
};

pub const Options = struct {
    message: []const u8,
    choices: []const Choice,
    cancel_label: []const u8 = "Cancel",
    /// message sent to the tui when the dialog closes without a choice
    on_cancel: ?cbor.Raw = null,
};

const Row = union(enum) {
    text: []const u8,
    separator,
    choice: usize,
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
chosen: bool = false,

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
        .arena = undefined,
        .options = .{
            .message = try a.dupe(u8, options.message),
            .choices = choices: {
                const choices = try a.alloc(Choice, options.choices.len);
                for (options.choices, choices) |choice, *copy| copy.* = .{
                    .label = try a.dupe(u8, choice.label),
                    .action = .{ .bytes = try a.dupe(u8, choice.action.bytes) },
                    .severity = choice.severity,
                    .default = choice.default,
                };
                break :choices choices;
            },
            .cancel_label = try a.dupe(u8, options.cancel_label),
            .on_cancel = if (options.on_cancel) |msg| .{ .bytes = try a.dupe(u8, msg.bytes) } else null,
        },
    };
    try self.commands.init(self);
    errdefer self.commands.deinit();
    self.mode.event_handler = EventHandler.to_owned(self);
    self.mode.name = "confirm";

    var lines = std.mem.splitScalar(u8, self.options.message, '\n');
    while (lines.next()) |line| try self.rows.append(a, .{ .text = line });
    try self.rows.append(a, .separator);
    for (0..self.options.choices.len) |idx| try self.rows.append(a, .{ .choice = idx });
    try self.rows.append(a, .cancel);
    for (self.rows.items, 0..) |row, pos| {
        var buf: [16]u8 = undefined;
        try self.list_box.add_item_with_handler(cbor.fmt(&buf, pos), on_click);
        self.width = @max(self.width, tui.egc_chunk_width(self.row_label(row), 0, 1) + 2);
    }
    self.list_box.selected = self.rows.items.len - 1;
    for (self.rows.items, 0..) |row, pos| switch (row) {
        .choice => |idx| if (self.options.choices[idx].default) {
            self.list_box.selected = pos;
            break;
        },
        else => {},
    };

    layer.ctx = self;
    layer.prepare_resize = prepare_resize_layer;
    layer.set(self.list_box.container_widget);
    try mv.floating_views.add(self.modal.widget());
    try mv.floating_views.add(layer.widget());
    layer.handle_resize(.{});
    self.arena = arena;
    return self.mode;
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    if (tui.mainview()) |mv| {
        mv.floating_views.remove(self.layer.widget());
        mv.floating_views.remove(self.modal.widget());
    }
    if (!self.chosen) if (self.options.on_cancel) |msg|
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
        .choice => |idx| self.options.choices[idx].label,
        .cancel => self.options.cancel_label,
    };
}

fn selectable(row: Row) bool {
    return row == .choice or row == .cancel;
}

fn select_next(self: *Self, direction: enum { up, down }) void {
    const len = self.rows.items.len;
    var pos = self.list_box.selected orelse len - 1;
    for (0..len) |_| {
        pos = switch (direction) {
            .down => (pos + 1) % len,
            .up => (pos + len - 1) % len,
        };
        if (selectable(self.rows.items[pos])) {
            self.list_box.selected = pos;
            return;
        }
    }
}

fn select_by_prefix(self: *Self, text: []const u8) void {
    const len = self.rows.items.len;
    if (text.len == 0) return;
    const start = if (self.list_box.selected) |selected| selected + 1 else 0;
    for (0..len) |i| {
        const pos = (start + i) % len;
        const row = self.rows.items[pos];
        if (!selectable(row)) continue;
        const label = self.row_label(row);
        if (label.len >= text.len and std.ascii.eqlIgnoreCase(label[0..text.len], text)) {
            self.list_box.selected = pos;
            return;
        }
    }
}

fn activate(self: *Self, pos: usize) !void {
    if (pos >= self.rows.items.len) return;
    switch (self.rows.items[pos]) {
        .text, .separator => return,
        .choice => |idx| {
            self.chosen = true;
            const action = try self.allocator.dupe(u8, self.options.choices[idx].action.bytes);
            defer self.allocator.free(action);
            try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
            try tp.self_pid().send_raw(.{ .buf = action });
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
    const style_row = if (selectable(row) and button.active) theme.editor_cursor else if (highlight) theme.editor_selection else style_base;
    button.plane.set_style(style_row);
    button.plane.fill(" ");
    button.plane.home();
    _ = button.plane.putstr(" ") catch {};
    switch (row) {
        .choice => |idx| if (!button.active) button.plane.set_style(.{
            .fg = switch (self.options.choices[idx].severity) {
                .info => theme.editor_information.fg,
                .warning => theme.editor_warning.fg,
                .err => theme.editor_error.fg,
            },
            .bg = style_row.bg,
        }),
        else => {},
    }
    _ = button.plane.putstr(self.row_label(row)) catch {};
    return false;
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn confirm_up(self: *Self, _: Ctx) Result {
        self.select_next(.up);
    }
    pub const confirm_up_meta: Meta = .{};

    pub fn confirm_down(self: *Self, _: Ctx) Result {
        self.select_next(.down);
    }
    pub const confirm_down_meta: Meta = .{};

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
        self.select_by_prefix(bytes);
    }
    pub const confirm_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };
};
