const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const zeit = @import("zeit");
const root = @import("soft_root").root;

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;

const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const MessageFilter = @import("../MessageFilter.zig");
const Menu = @import("../Menu.zig");
const MenuButton = @import("../MenuButton.zig");
const tui = @import("../tui.zig");
const fonts = @import("../fonts.zig");

const DigitStyle = fonts.DigitStyle;

allocator: std.mem.Allocator,
tick_timer: ?tp.Cancellable = null,
tz: zeit.timezone.TimeZone,
style: DigitStyle,

const Self = @This();
const ButtonType = Button.Options(Self).ButtonType;

const menu: Menu = .{ .items = &.{
    .{ .command = .{ .command = "open_main_menu" } },
    .{ .command = .{ .command = "toggle_menu", .on_activate = .keep_open } },
    .separator,
    .{ .command = .{ .command = "switch_terminals" } },
    .{ .command = .{ .command = "run_task" } },
    .separator,
    .{ .command = .{ .command = "toggle_keybind_hints", .on_activate = .keep_open } },
    .{ .command = .{ .command = "toggle_panel" } },
    .{ .command = .{ .command = "toggle_input_mode", .on_activate = .keep_open } },
    .separator,
    .{ .command = .{ .command = "change_theme" } },
    .{ .command = .{ .command = "toggle_color_scheme", .on_activate = .keep_open } },
    .{ .command = .{ .command = "theme_next", .on_activate = .keep_open } },
    .{ .command = .{ .command = "theme_prev", .on_activate = .keep_open } },
    .separator,
    .{ .command = .{ .command = "open_config" } },
    .{ .command = .{ .command = "open_keybind_config" } },
} };

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler, arg: ?[]const u8) @import("widget.zig").CreateError!Widget {
    var tz = root.local_timezone(allocator) catch |e| {
        std.log.err("clock: zeit.local failed with {any}", .{e});
        return error.WidgetInitFailed;
    };
    errdefer tz.deinit();
    return Button.create_widget(Self, allocator, parent, .{
        .ctx = .{
            .allocator = allocator,
            .tz = tz,
            .style = if (arg) |style| std.meta.stringToEnum(DigitStyle, style) orelse .ascii else .ascii,
        },
        .label = "",
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
        .on_event = event_handler,
    });
}

pub fn ctx_init(self: *Self) error{OutOfMemory}!void {
    try tui.message_filters().add(MessageFilter.bind(self, receive_tick));
    self.start_tick_timer();
}

pub fn ctx_deinit(self: *Self) void {
    tui.message_filters().remove_ptr(self);
    if (self.tick_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
    }
    self.tz.deinit();
}

fn on_click(_: *Self, btn: *ButtonType, _: Widget.Pos) void {
    tui.open_menu(&menu, MenuButton.anchor(btn), null) catch |e|
        std.log.err("clock menu: {t}", .{e});
}

pub fn layout(_: *Self, _: *ButtonType) Widget.Layout {
    return .{ .static = if (tui.screen().w < 80) 0 else 5 };
}

pub fn render(self: *Self, btn: *ButtonType, theme: *const Widget.Theme) bool {
    btn.plane.set_base_style(theme.editor);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
    btn.plane.fill(" ");
    btn.plane.home();

    const now = zeit.instant(.{ .now = root.get_io() }, &self.tz);
    const dt = now.time();
    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute }) catch return false;
    for (0..text.len) |i| _ = btn.plane.putstr(fonts.get_digit_ascii(text[i .. i + 1], self.style)) catch {};
    return false;
}

fn receive_tick(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (!try cbor.match(m.buf, .{"CLOCK"})) return false;
    tui.need_render(@src());
    if (self.tick_timer) |*t| t.deinit();
    self.start_tick_timer();
    return true;
}

fn start_tick_timer(self: *Self) void {
    const current = zeit.instant(.{ .now = root.get_io() }, &self.tz);
    var next = current.time();
    next.minute += 1;
    next.second = 0;
    next.millisecond = 0;
    next.microsecond = 0;
    next.nanosecond = 0;
    const delay_us: u64 = @intCast(@divTrunc(next.instant().timestamp - current.timestamp, std.time.ns_per_us));
    self.tick_timer = tp.self_pid().delay_send_cancellable(self.allocator, "clock.tick_timer", delay_us, .{"CLOCK"}) catch null;
}
