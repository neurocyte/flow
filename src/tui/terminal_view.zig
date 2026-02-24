const std = @import("std");
const Allocator = std.mem.Allocator;

const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const vaxis = @import("renderer").vaxis;
const shell = @import("shell");

const Plane = @import("renderer").Plane;
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const MessageFilter = @import("MessageFilter.zig");
const tui = @import("tui.zig");
const input = @import("input");

pub const name = @typeName(Self);

const Self = @This();
const widget_type: Widget.Type = .panel;

const Terminal = vaxis.widgets.Terminal;

/// Poll interval in microseconds – how often we check the pty for new output.
/// 16 ms ≈ 60 Hz; Flow's render loop will coalesce multiple need_render calls.
const poll_interval_us: u64 = 16 * std.time.us_per_ms;

allocator: Allocator,
plane: Plane,
vt: Terminal,
env: std.process.EnvMap,
write_buf: [4096]u8,
poll_timer: ?tp.Cancellable = null,
focused: bool = false,
cwd: std.ArrayListUnmanaged(u8) = .empty,
title: std.ArrayListUnmanaged(u8) = .empty,

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    return create_with_args(allocator, parent, .{});
}

pub fn create_with_args(allocator: Allocator, parent: Plane, ctx: command.Context) !Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const container = try WidgetList.createHStyled(
        allocator,
        parent,
        "panel_frame",
        .dynamic,
        widget_type,
    );

    var plane = try Plane.init(&(Widget.Box{}).opts(name), parent);
    errdefer plane.deinit();

    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();

    var cmd_arg: []const u8 = "";
    const argv_msg: ?tp.message = if (ctx.args.match(.{tp.extract(&cmd_arg)}) catch false and cmd_arg.len > 0)
        try shell.parse_arg0_to_argv(allocator, &cmd_arg)
    else
        null;
    defer if (argv_msg) |msg| allocator.free(msg.buf);

    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    if (argv_msg) |msg| {
        var iter = msg.buf;
        var len = try cbor.decodeArrayHeader(&iter);
        while (len > 0) : (len -= 1) {
            var arg: []const u8 = undefined;
            if (try cbor.matchValue(&iter, cbor.extract(&arg)))
                try argv_list.append(allocator, arg);
        }
    } else {
        try argv_list.append(allocator, env.get("SHELL") orelse "bash");
    }
    const argv: []const []const u8 = argv_list.items;
    const home = env.get("HOME") orelse "/tmp";

    // Use the current plane dimensions for the initial pty size. The plane
    // starts at 0×0 before the first resize, so use a sensible fallback
    // so the pty isn't created with a zero-cell screen.
    const cols: u16 = @intCast(@max(80, plane.dim_x()));
    const rows: u16 = @intCast(@max(24, plane.dim_y()));

    // write_buf must outlive the Terminal because the pty writer holds a
    // pointer into it. It lives inside Self so the lifetimes match.
    self.write_buf = undefined;
    const vt = try Terminal.init(
        allocator,
        argv,
        &env,
        .{
            .winsize = .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 },
            .scrollback_size = 0,
            .initial_working_directory = blk: {
                const project = tp.env.get().str("project");
                break :blk if (project.len > 0) project else home;
            },
        },
        &self.write_buf,
    );

    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .vt = vt,
        .env = env,
        .write_buf = undefined, // managed via self.vt's pty_writer pointer
        .poll_timer = null,
    };

    try self.vt.spawn();

    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));

    container.ctx = self;
    try container.add(Widget.to(self));

    self.schedule_poll();

    return container.widget();
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (!self.focused) return false;
    var evtype: u8 = 0;
    var keycode: u21 = 0;
    var shifted: u21 = 0;
    var text: []const u8 = "";
    var mods: u8 = 0;
    if (!(try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keycode), tp.extract(&shifted), tp.extract(&text), tp.extract(&mods) })))
        return false;
    // Only forward press and repeat events; ignore releases.
    if (evtype != input.event.press and evtype != input.event.repeat) return true;
    const key: vaxis.Key = .{
        .codepoint = keycode,
        .shifted_codepoint = if (shifted != keycode) shifted else null,
        .mods = @bitCast(mods),
        .text = if (text.len > 0) text else null,
    };
    self.vt.update(.{ .key_press = key }) catch |e|
        std.log.err("terminal_view: input failed: {}", .{e});
    tui.need_render(@src());
    return true;
}

pub fn focus(self: *Self) void {
    self.focused = true;
    tui.set_keyboard_focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    self.focused = false;
    tui.release_keyboard_focus(Widget.to(self));
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.focused) tui.release_keyboard_focus(Widget.to(self));
    self.cwd.deinit(self.allocator);
    self.title.deinit(self.allocator);
    tui.message_filters().remove_ptr(self);
    if (self.poll_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
    }
    self.vt.deinit();
    self.env.deinit();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn render(self: *Self, _: *const Widget.Theme) bool {
    // Drain the vt event queue.
    while (self.vt.tryEvent()) |event| {
        switch (event) {
            .exited => {
                tp.self_pid().send(.{ "cmd", "toggle_terminal_view" }) catch {};
                return false;
            },
            .redraw, .bell => {},
            .pwd_change => |path| {
                self.cwd.clearRetainingCapacity();
                self.cwd.appendSlice(self.allocator, path) catch {};
            },
            .title_change => |t| {
                self.title.clearRetainingCapacity();
                self.title.appendSlice(self.allocator, t) catch {};
            },
        }
    }

    // Blit the terminal's front screen into our vaxis.Window.
    self.vt.draw(self.allocator, self.plane.window) catch |e| {
        std.log.err("terminal_view: draw failed: {}", .{e});
    };

    return false;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;

    const cols: u16 = @intCast(@max(1, pos.w));
    const rows: u16 = @intCast(@max(1, pos.h));
    self.vt.resize(.{
        .rows = rows,
        .cols = cols,
        .x_pixel = 0,
        .y_pixel = 0,
    }) catch |e| {
        std.log.err("terminal_view: resize failed: {}", .{e});
    };
}

// The pty read thread pushes output into vt asynchronously.  We use a
// recurring thespian delay_send to wake up every ~16 ms and check whether
// new output has arrived, requesting a render frame when it has.
fn schedule_poll(self: *Self) void {
    self.poll_timer = tp.self_pid().delay_send_cancellable(
        self.allocator,
        "terminal_view.poll",
        poll_interval_us,
        .{"TERMINAL_VIEW_POLL"},
    ) catch null;
}

fn receive_filter(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (try cbor.match(m.buf, .{"TERMINAL_VIEW_POLL"})) {
        if (self.poll_timer) |*t| {
            t.deinit();
            self.poll_timer = null;
        }

        if (self.vt.dirty)
            tui.need_render(@src());

        self.schedule_poll();
        return true;
    }
    return false;
}
