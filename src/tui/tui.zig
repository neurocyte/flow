const std = @import("std");
const nc = @import("notcurses");
const tp = @import("thespian");
const log = @import("log");
const config = @import("config");
const project_manager = @import("project_manager");
const build_options = @import("build_options");
const root = @import("root");

const tracy = @import("tracy");

const command = @import("command.zig");
const WidgetStack = @import("WidgetStack.zig");
const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");
const EventHandler = @import("EventHandler.zig");
const mainview = @import("mainview.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const STDIN_FILENO = std.os.STDIN_FILENO;
const Timer = std.time.Timer;
const Mutex = std.Thread.Mutex;
const maxInt = std.math.maxInt;

a: Allocator,
nc: nc.Context,
config: config,
frame_time: usize, // in microseconds
frame_clock: tp.metronome,
frame_clock_running: bool = false,
frame_last_time: i64 = 0,
fd_stdin: tp.file_descriptor,
receiver: Receiver,
mainview: Widget,
message_filters: MessageFilter.List,
input_mode: ?Mode,
input_mode_outer: ?Mode = null,
input_listeners: EventHandler.List,
keyboard_focus: ?Widget = null,
mini_mode: ?MiniModeState = null,
hover_focus: ?*Widget = null,
commands: Commands = undefined,
logger: log.Logger,
drag: bool = false,
drag_event: nc.Input = nc.input(),
drag_source: ?*Widget = null,
theme: Widget.Theme,
escape_state: EscapeState = .none,
escape_initial: ?nc.Input = null,
escape_code: ArrayList(u8),
bracketed_paste: bool = false,
bracketed_paste_buffer: ArrayList(u8),
idle_frame_count: usize = 0,
unrendered_input_events_count: usize = 0,
unflushed_events_count: usize = 0,
init_timer: ?tp.timeout,
sigwinch_signal: ?tp.signal = null,
no_sleep: bool = false,
mods: ModState = .{},

const idle_frames = 1;

const ModState = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

const init_delay = 1; // ms

const Self = @This();

const Receiver = tp.Receiver(*Self);
const Commands = command.Collection(cmds);

const StartArgs = struct { a: Allocator };

pub fn spawn(a: Allocator, ctx: *tp.context, eh: anytype, env: ?*const tp.env) !tp.pid {
    return try ctx.spawn_link(StartArgs{ .a = a }, start, "tui", eh, env);
}

fn start(args: StartArgs) tp.result {
    _ = tp.set_trap(true);
    var self = init(args.a) catch |e| return tp.exit_error(e);
    errdefer self.deinit();
    need_render();
    tp.receive(&self.receiver);
}

fn init(a: Allocator) !*Self {
    var opts = nc.Context.Options{
        .termtype = null,
        .loglevel = @intFromEnum(nc.LogLevel.silent),
        .margin_t = 0,
        .margin_r = 0,
        .margin_b = 0,
        .margin_l = 0,
        .flags = nc.Context.option.SUPPRESS_BANNERS | nc.Context.option.INHIBIT_SETLOCALE | nc.Context.option.NO_WINCH_SIGHANDLER,
    };
    if (tp.env.get().is("no-alternate"))
        opts.flags |= nc.Context.option.NO_ALTERNATE_SCREEN;
    const nc_ = try nc.Context.core_init(&opts, null);
    nc_.mice_enable(nc.mice.ALL_EVENTS) catch {};
    try nc_.linesigs_disable();

    var conf_buf: ?[]const u8 = null;
    var conf = root.read_config(a, &conf_buf);
    defer if (conf_buf) |buf| a.free(buf);

    const theme = get_theme_by_name(conf.theme) orelse get_theme_by_name("dark_modern") orelse return tp.exit("unknown theme");
    conf.theme = theme.name;
    conf.input_mode = try a.dupe(u8, conf.input_mode);

    const frame_rate: usize = @intCast(tp.env.get().num("frame-rate"));
    if (frame_rate != 0)
        conf.frame_rate = frame_rate;
    const frame_time = std.time.us_per_s / conf.frame_rate;
    const frame_clock = try tp.metronome.init(frame_time);

    const fd_stdin = try tp.file_descriptor.init("stdin", nc_.inputready_fd());
    // const fd_stdin = try tp.file_descriptor.init("stdin", std.os.STDIN_FILENO);
    const n = nc_.stdplane();

    try frame_clock.start();
    try fd_stdin.wait_read();

    var self = try a.create(Self);
    self.* = .{
        .a = a,
        .config = conf,
        .nc = nc_,
        .frame_time = frame_time,
        .frame_clock = frame_clock,
        .frame_clock_running = true,
        .fd_stdin = fd_stdin,
        .receiver = Receiver.init(receive, self),
        .mainview = undefined,
        .message_filters = MessageFilter.List.init(a),
        .input_mode = null,
        .input_listeners = EventHandler.List.init(a),
        .logger = log.logger("tui"),
        .escape_code = ArrayList(u8).init(a),
        .bracketed_paste_buffer = ArrayList(u8).init(a),
        .init_timer = try tp.timeout.init_ms(init_delay, tp.message.fmt(.{"init"})),
        .theme = theme,
        .no_sleep = tp.env.get().is("no-sleep"),
    };
    try self.commands.init(self);
    errdefer self.deinit();
    instance_ = self;
    defer instance_ = null;
    try self.listen_sigwinch();
    self.mainview = try mainview.create(a, n);
    try self.initUI();
    try nc_.render();
    try self.save_config();
    // self.request_mouse_cursor_support_detect();
    self.bracketed_paste_enable();
    if (tp.env.get().is("restore-session")) {
        command.executeName("restore_session", .{}) catch |e| self.logger.err("restore_session", e);
        self.logger.print("session restored", .{});
    }
    return self;
}

pub fn initUI(self: *Self) !void {
    const n = self.nc.stdplane();
    var channels: u64 = 0;
    try nc.channels_set_fg_rgb(&channels, 0x88aa00);
    try nc.channels_set_bg_rgb(&channels, 0x000088);
    try nc.channels_set_bg_alpha(&channels, nc.ALPHA_TRANSPARENT);
    _ = try n.set_base(" ", 0, channels);
    try n.set_fg_rgb(0x40f040);
    try n.set_fg_rgb(0x00dddd);
}

fn init_delayed(self: *Self) tp.result {
    if (self.input_mode) |_| {} else return cmds.enter_mode(self, command.Context.fmt(.{self.config.input_mode}));
}

fn deinit(self: *Self) void {
    self.bracketed_paste_buffer.deinit();
    self.escape_code.deinit();
    if (self.input_mode) |*m| m.deinit();
    self.commands.deinit();
    self.fd_stdin.deinit();
    self.mainview.deinit(self.a);
    self.message_filters.deinit();
    self.input_listeners.deinit();
    if (self.frame_clock_running)
        self.frame_clock.stop() catch {};
    if (self.sigwinch_signal) |sig| sig.deinit();
    self.frame_clock.deinit();
    self.nc.stop();
    self.logger.deinit();
    self.a.destroy(self);
}

fn listen_sigwinch(self: *Self) tp.result {
    if (self.sigwinch_signal) |old| old.deinit();
    self.sigwinch_signal = tp.signal.init(std.posix.SIG.WINCH, tp.message.fmt(.{"sigwinch"})) catch |e| return tp.exit_error(e);
}

fn receive(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
    const frame = tracy.initZone(@src(), .{ .name = "tui" });
    defer frame.deinit();
    instance_ = self;
    defer instance_ = null;
    errdefer self.deinit();
    errdefer self.fd_stdin.cancel() catch {};
    errdefer self.nc.leave_alternate_screen();
    self.receive_safe(from, m) catch |e| {
        if (std.mem.eql(u8, "normal", tp.error_text()))
            return e;
        if (std.mem.eql(u8, "restart", tp.error_text()))
            return e;
        self.logger.err("UI", e);
    };
}

fn receive_safe(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
    if (self.message_filters.filter(from, m) catch |e| return self.logger.err("filter", e))
        return;

    var cmd: []const u8 = undefined;
    var ctx: cmds.Ctx = .{};
    if (try m.match(.{ "cmd", tp.extract(&cmd) }))
        return command.executeName(cmd, ctx) catch |e| self.logger.err(cmd, e);

    var arg: []const u8 = undefined;

    if (try m.match(.{ "cmd", tp.extract(&cmd), tp.extract_cbor(&arg) })) {
        ctx.args = .{ .buf = arg };
        return command.executeName(cmd, ctx) catch |e| self.logger.err(cmd, e);
    }
    if (try m.match(.{"quit"})) {
        project_manager.shutdown();
        return tp.exit_normal();
    }
    if (try m.match(.{ "project_manager", "shutdown" })) {
        return tp.exit_normal();
    }

    if (try m.match(.{"restart"})) {
        _ = try self.mainview.msg(.{"write_restore_info"});
        project_manager.shutdown();
        return tp.exit("restart");
    }

    if (try m.match(.{"sigwinch"})) {
        try self.listen_sigwinch();
        self.nc.refresh() catch |e| return self.logger.err("refresh", e);
        self.mainview.resize(Widget.Box.from(self.nc.stdplane()));
        need_render();
        return;
    }

    if (try m.match(.{ "system_clipboard", tp.string })) {
        if (self.input_mode) |mode|
            mode.handler.send(tp.self_pid(), m) catch |e| self.logger.err("clipboard handler", e);
        return;
    }

    if (self.dispatch_input(m) catch |e| b: {
        self.logger.err("input dispatch", e);
        break :b true;
    })
        return;

    if (try m.match(.{"render"})) {
        if (!self.frame_clock_running)
            self.render(std.time.microTimestamp());
        return;
    }

    var counter: usize = undefined;
    if (try m.match(.{ "tick", tp.extract(&counter) })) {
        tracy.frameMark();
        const current_time = std.time.microTimestamp();
        if (current_time < self.frame_last_time) { // clock moved backwards
            self.frame_last_time = current_time;
            return;
        }
        const time_delta = current_time - self.frame_last_time;
        if (time_delta >= self.frame_time * 2 / 3) {
            self.frame_last_time = current_time;
            self.render(current_time);
        }
        return;
    }

    if (try m.match(.{"init"})) {
        try self.init_delayed();
        self.render(std.time.microTimestamp());
        if (self.init_timer) |*timer| {
            timer.deinit();
            self.init_timer = null;
        } else {
            return tp.unexpected(m);
        }
        return;
    }

    if (try self.send_widgets(from, m))
        return;

    if (try m.match(.{ "exit", "normal" }))
        return;

    if (try m.match(.{ "exit", "timeout_error", 125, "Operation aborted." }))
        return;

    if (try m.match(.{ "exit", "DEADSEND", tp.more }))
        return;

    if (try m.match(.{ "PRJ", tp.more })) // drop late project manager query responses
        return;

    return tp.unexpected(m);
}

fn render(self: *Self, current_time: i64) void {
    self.frame_last_time = current_time;

    {
        const frame = tracy.initZone(@src(), .{ .name = "tui update" });
        defer frame.deinit();
        self.mainview.update();
    }

    const more = ret: {
        const frame = tracy.initZone(@src(), .{ .name = "tui render" });
        defer frame.deinit();
        self.nc.stdplane().erase();
        break :ret self.mainview.render(&self.theme);
    };

    {
        const frame = tracy.initZone(@src(), .{ .name = "notcurses render" });
        defer frame.deinit();
        self.nc.render() catch |e| self.logger.err("render", e);
    }

    self.idle_frame_count = if (self.unrendered_input_events_count > 0)
        0
    else
        self.idle_frame_count + 1;

    if (more or self.idle_frame_count < idle_frames or self.no_sleep) {
        self.unrendered_input_events_count = 0;
        if (!self.frame_clock_running) {
            self.frame_clock.start() catch {};
            self.frame_clock_running = true;
        }
    } else {
        if (self.frame_clock_running) {
            self.frame_clock.stop() catch {};
            self.frame_clock_running = false;
        }
    }
}

fn dispatch_input(self: *Self, m: tp.message) error{Exit}!bool {
    const frame = tracy.initZone(@src(), .{ .name = "tui input" });
    defer frame.deinit();
    var err: i64 = 0;
    var err_msg: []u8 = "";
    if (try m.match(.{ "fd", "stdin", "read_ready" })) {
        self.fd_stdin.wait_read() catch |e| return tp.exit_error(e);
        try self.dispatch_notcurses();
        return true; // consume message
    }
    if (try m.match(.{ "fd", "stdin", "read_error", tp.extract(&err), tp.extract(&err_msg) })) {
        return tp.exit(err_msg);
    }
    return false;
}

fn dispatch_notcurses(self: *Self) tp.result {
    var input_buffer: [256]nc.Input = undefined;

    while (true) {
        const nivec = self.nc.getvec_nblock(&input_buffer) catch |e| return tp.exit_error(e);
        if (nivec.len == 0)
            break;
        for (nivec) |*ni| {
            if (ni.id == 27 or self.escape_state != .none) {
                try self.handle_escape(ni);
                continue;
            }
            self.dispatch_input_event(ni) catch |e|
                self.logger.err("input dispatch", e);
        }
    }
    if (self.escape_state == .init)
        try self.handle_escape_short();
    if (self.unflushed_events_count > 0)
        _ = try self.dispatch_flush_input_event();
    if (self.unrendered_input_events_count > 0 and !self.frame_clock_running)
        need_render();
}

fn dispatch_input_event(self: *Self, ni: *nc.Input) tp.result {
    const keypress: u32 = ni.id;
    var buf: [256]u8 = undefined;
    self.unrendered_input_events_count += 1;
    ni.modifiers &= nc.mod.CTRL | nc.mod.SHIFT | nc.mod.ALT | nc.mod.SUPER | nc.mod.META | nc.mod.HYPER;
    if (keypress == nc.key.RESIZE) return;
    try self.sync_mod_state(keypress, ni.modifiers);
    if (keypress == nc.key.MOTION) {
        if (ni.y == 0 and ni.x == 0 and ni.ypx == -1 and ni.xpx == -1) return;
        self.dispatch_mouse(ni.y, ni.x, tp.self_pid(), tp.message.fmtbuf(&buf, .{
            "M",
            ni.x,
            ni.y,
            ni.xpx,
            ni.ypx,
        }) catch |e| return tp.exit_error(e));
    } else if (keypress > nc.key.MOTION and keypress <= nc.key.BUTTON11) {
        if (ni.y == 0 and ni.x == 0 and ni.ypx == -1 and ni.xpx == -1) return;
        if (try self.detect_drag(ni)) return;
        self.dispatch_mouse(ni.y, ni.x, tp.self_pid(), tp.message.fmtbuf(&buf, .{
            "B",
            ni.evtype,
            keypress,
            nc.key_string(ni),
            ni.x,
            ni.y,
            ni.xpx,
            ni.ypx,
        }) catch |e| return tp.exit_error(e));
    } else {
        self.unflushed_events_count += 1;
        self.send_input(tp.self_pid(), tp.message.fmtbuf(&buf, .{
            "I",
            normalized_evtype(ni.evtype),
            keypress,
            if (@hasField(nc.Input, "eff_text")) ni.eff_text[0] else keypress,
            nc.key_string(ni),
            ni.modifiers,
        }) catch |e| return tp.exit_error(e));
    }
}

fn dispatch_flush_input_event(self: *Self) error{Exit}!bool {
    var buf: [32]u8 = undefined;
    self.unflushed_events_count = 0;
    if (self.input_mode) |mode|
        try mode.handler.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{"F"}) catch |e| return tp.exit_error(e));
    return false;
}

fn detect_drag(self: *Self, ni: *nc.Input) error{Exit}!bool {
    return switch (ni.id) {
        nc.key.BUTTON1...nc.key.BUTTON3, nc.key.BUTTON6...nc.key.BUTTON9 => if (self.drag) self.detect_drag_end(ni) else self.detect_drag_begin(ni),
        else => false,
    };
}

fn detect_drag_begin(self: *Self, ni: *nc.Input) error{Exit}!bool {
    if (ni.evtype == nc.event_type.PRESS and self.drag_event.id == ni.id) {
        self.drag_source = self.find_coord_widget(@intCast(self.drag_event.y), @intCast(self.drag_event.x));
        self.drag_event = ni.*;
        self.drag = true;
        var buf: [256]u8 = undefined;
        _ = try self.send_mouse_drag(tp.self_pid(), tp.message.fmtbuf(&buf, .{
            "D",
            nc.event_type.PRESS,
            ni.id,
            nc.key_string(ni),
            ni.x,
            ni.y,
            ni.xpx,
            ni.ypx,
        }) catch |e| return tp.exit_error(e));
        return true;
    }
    if (ni.evtype == nc.event_type.PRESS)
        self.drag_event = ni.*
    else
        self.drag_event = nc.input();
    return false;
}

fn detect_drag_end(self: *Self, ni: *nc.Input) error{Exit}!bool {
    var buf: [256]u8 = undefined;
    if (ni.id == self.drag_event.id and ni.evtype != nc.event_type.PRESS) {
        _ = try self.send_mouse_drag(tp.self_pid(), tp.message.fmtbuf(&buf, .{
            "D",
            nc.event_type.RELEASE,
            ni.id,
            nc.key_string(ni),
            ni.x,
            ni.y,
            ni.xpx,
            ni.ypx,
        }) catch |e| return tp.exit_error(e));
        self.drag = false;
        self.drag_event = nc.input();
        self.drag_source = null;
        return true;
    }
    _ = try self.send_mouse_drag(tp.self_pid(), tp.message.fmtbuf(&buf, .{
        "D",
        ni.evtype,
        ni.id,
        nc.key_string(ni),
        ni.x,
        ni.y,
        ni.xpx,
        ni.ypx,
    }) catch |e| return tp.exit_error(e));
    return true;
}

fn normalized_evtype(evtype: c_uint) c_uint {
    return if (evtype == nc.event_type.UNKNOWN) @as(c_uint, @intCast(nc.event_type.PRESS)) else evtype;
}

const EscapeState = enum { none, init, OSC, st, CSI };

fn handle_escape(self: *Self, ni: *nc.Input) tp.result {
    switch (self.escape_state) {
        .none => switch (ni.id) {
            '\x1B' => {
                self.escape_state = .init;
                self.escape_initial = ni.*;
            },
            else => unreachable,
        },
        .init => switch (ni.id) {
            ']' => self.escape_state = .OSC,
            '[' => self.escape_state = .CSI,
            else => {
                try self.handle_escape_short();
                _ = try self.dispatch_input_event(ni);
            },
        },
        .OSC => switch (ni.id) {
            '\x1B' => self.escape_state = .st,
            '\\' => try self.handle_OSC_escape_code(),
            ' '...'\\' - 1, '\\' + 1...127 => {
                const p = self.escape_code.addOne() catch |e| return tp.exit_error(e);
                p.* = @intCast(ni.id);
            },
            else => try self.handle_OSC_escape_code(),
        },
        .st => switch (ni.id) {
            '\\' => try self.handle_OSC_escape_code(),
            else => try self.handle_OSC_escape_code(),
        },
        .CSI => switch (ni.id) {
            '0'...'9', ';', ' ', '-', '?' => {
                const p = self.escape_code.addOne() catch |e| return tp.exit_error(e);
                p.* = @intCast(ni.id);
            },
            else => {
                const p = self.escape_code.addOne() catch |e| return tp.exit_error(e);
                p.* = @intCast(ni.id);
                try self.handle_CSI_escape_code();
            },
        },
    }
}

fn handle_escape_short(self: *Self) tp.result {
    self.escape_code.clearAndFree();
    self.escape_state = .none;
    defer self.escape_initial = null;
    if (self.escape_initial) |*ni|
        _ = try self.dispatch_input_event(ni);
}

fn find_coord_widget(self: *Self, y: usize, x: usize) ?*Widget {
    const Ctx = struct {
        widget: ?*Widget = null,
        y: usize,
        x: usize,
        fn find(ctx_: *anyopaque, w: *Widget) bool {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            if (w.box().is_abs_coord_inside(ctx.y, ctx.x)) {
                ctx.widget = w;
                return true;
            }
            return false;
        }
    };
    var ctx: Ctx = .{ .y = y, .x = x };
    _ = self.mainview.walk(&ctx, Ctx.find);
    return ctx.widget;
}

pub fn is_abs_coord_in_widget(w: *const Widget, y: usize, x: usize) bool {
    return w.box().is_abs_coord_inside(y, x);
}

fn is_live_widget_ptr(self: *Self, w_: *Widget) bool {
    const Ctx = struct {
        w: *Widget,
        fn find(ctx_: *anyopaque, w: *Widget) bool {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            return ctx.w == w;
        }
    };
    var ctx: Ctx = .{ .w = w_ };
    return self.mainview.walk(&ctx, Ctx.find);
}

fn send_widgets(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    const frame = tracy.initZone(@src(), .{ .name = "tui widgets" });
    defer frame.deinit();
    tp.trace(tp.channel.widget, m);
    return if (self.keyboard_focus) |w|
        w.send(from, m)
    else
        self.mainview.send(from, m);
}

fn dispatch_mouse(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) void {
    self.send_mouse(y, x, from, m) catch |e|
        self.logger.err("dispatch mouse", e);
}

fn send_mouse(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) tp.result {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners.send(from, m) catch {};
    if (self.keyboard_focus) |w| {
        _ = try w.send(from, m);
    } else if (self.find_coord_widget(@intCast(y), @intCast(x))) |w| {
        if (if (self.hover_focus) |h| h != w else true) {
            var buf: [256]u8 = undefined;
            if (self.hover_focus) |h| {
                if (self.is_live_widget_ptr(h))
                    _ = try h.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", false }) catch |e| return tp.exit_error(e));
            }
            self.hover_focus = w;
            _ = try w.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", true }) catch |e| return tp.exit_error(e));
        }
        _ = try w.send(from, m);
    } else {
        if (self.hover_focus) |h| {
            var buf: [256]u8 = undefined;
            _ = try h.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", false }) catch |e| return tp.exit_error(e));
        }
        self.hover_focus = null;
    }
}

fn send_mouse_drag(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners.send(from, m) catch {};
    return if (self.keyboard_focus) |w|
        w.send(from, m)
    else if (self.drag_source) |w|
        w.send(from, m)
    else
        false;
}

fn send_input(self: *Self, from: tp.pid_ref, m: tp.message) void {
    tp.trace(tp.channel.input, m);
    if (self.bracketed_paste and self.handle_bracketed_paste_input(m) catch |e| {
        self.bracketed_paste_buffer.clearAndFree();
        self.bracketed_paste = false;
        return self.logger.err("bracketed paste input handler", e);
    }) {
        return;
    }
    self.input_listeners.send(from, m) catch {};
    if (self.keyboard_focus) |w|
        if (w.send(from, m) catch |e| ret: {
            self.logger.err("focus", e);
            break :ret false;
        })
            return;
    if (self.input_mode) |mode|
        mode.handler.send(from, m) catch |e| self.logger.err("input handler", e);
}

pub fn save_config(self: *const Self) !void {
    try root.write_config(self.config, self.a);
}

fn sync_mod_state(self: *Self, keypress: u32, modifiers: u32) tp.result {
    if (keypress == nc.key.LCTRL or keypress == nc.key.RCTRL or keypress == nc.key.LALT or keypress == nc.key.RALT or
        keypress == nc.key.LSHIFT or keypress == nc.key.RSHIFT or keypress == nc.key.LSUPER or keypress == nc.key.RSUPER) return;
    if (nc.isCtrl(modifiers) and !self.mods.ctrl)
        try self.send_key(nc.event_type.PRESS, nc.key.LCTRL, "lctrl", modifiers);
    if (!nc.isCtrl(modifiers) and self.mods.ctrl)
        try self.send_key(nc.event_type.RELEASE, nc.key.LCTRL, "lctrl", modifiers);
    if (nc.isAlt(modifiers) and !self.mods.alt)
        try self.send_key(nc.event_type.PRESS, nc.key.LALT, "lalt", modifiers);
    if (!nc.isAlt(modifiers) and self.mods.alt)
        try self.send_key(nc.event_type.RELEASE, nc.key.LALT, "lalt", modifiers);
    if (nc.isShift(modifiers) and !self.mods.shift)
        try self.send_key(nc.event_type.PRESS, nc.key.LSHIFT, "lshift", modifiers);
    if (!nc.isShift(modifiers) and self.mods.shift)
        try self.send_key(nc.event_type.RELEASE, nc.key.LSHIFT, "lshift", modifiers);
    self.mods = .{
        .ctrl = nc.isCtrl(modifiers),
        .alt = nc.isAlt(modifiers),
        .shift = nc.isShift(modifiers),
    };
}

fn send_key(self: *Self, event_type: c_int, keypress: u32, key_string: []const u8, modifiers: u32) tp.result {
    var buf: [256]u8 = undefined;
    self.send_input(tp.self_pid(), tp.message.fmtbuf(&buf, .{
        "I",
        event_type,
        keypress,
        keypress,
        key_string,
        modifiers,
    }) catch |e| return tp.exit_error(e));
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;

    pub fn restart(_: *Self, _: Ctx) tp.result {
        try tp.self_pid().send("restart");
    }

    pub fn log_widgets(self: *Self, _: Ctx) tp.result {
        const l = log.logger("z stack");
        defer l.deinit();
        var buf: [256]u8 = undefined;
        var buf_parent: [256]u8 = undefined;
        var z: i32 = 0;
        var n = self.nc.stdplane();
        while (n.below()) |n_| : (n = n_) {
            z -= 1;
            l.print("{d} {s} {s}", .{ z, n_.name(&buf), n_.parent().name(&buf_parent) });
        }
        z = 0;
        n = self.nc.stdplane();
        while (n.above()) |n_| : (n = n_) {
            z += 1;
            l.print("{d} {s} {s}", .{ z, n_.name(&buf), n_.parent().name(&buf_parent) });
        }
    }

    pub fn theme_next(self: *Self, _: Ctx) tp.result {
        self.theme = get_next_theme_by_name(self.theme.name);
        self.config.theme = self.theme.name;
        self.logger.print("theme: {s}", .{self.theme.description});
        self.save_config() catch |e| return tp.exit_error(e);
    }

    pub fn theme_prev(self: *Self, _: Ctx) tp.result {
        self.theme = get_prev_theme_by_name(self.theme.name);
        self.config.theme = self.theme.name;
        self.logger.print("theme: {s}", .{self.theme.description});
        self.save_config() catch |e| return tp.exit_error(e);
    }

    pub fn toggle_whitespace(self: *Self, _: Ctx) tp.result {
        self.config.show_whitespace = !self.config.show_whitespace;
        self.logger.print("show_whitspace {s}", .{if (self.config.show_whitespace) "enabled" else "disabled"});
        self.save_config() catch |e| return tp.exit_error(e);
        var buf: [32]u8 = undefined;
        const m = tp.message.fmtbuf(&buf, .{ "show_whitespace", self.config.show_whitespace }) catch |e| return tp.exit_error(e);
        _ = try self.send_widgets(tp.self_pid(), m);
    }

    pub fn toggle_input_mode(self: *Self, _: Ctx) tp.result {
        self.config.input_mode = if (std.mem.eql(u8, self.config.input_mode, "flow")) "vim/normal" else "flow";
        self.save_config() catch |e| return tp.exit_error(e);
        return enter_mode(self, Ctx.fmt(.{self.config.input_mode}));
    }

    pub fn enter_mode(self: *Self, ctx: Ctx) tp.result {
        var mode: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&mode)}))
            return tp.exit_error(error.InvalidArgument);
        if (self.mini_mode) |_| try cmds.exit_mini_mode(self, .{});
        if (self.input_mode) |*m| m.deinit();
        if (self.input_mode_outer) |*m| {
            m.deinit();
            self.input_mode_outer = null;
        }
        self.input_mode = if (std.mem.eql(u8, mode, "vim/normal"))
            @import("mode/input/vim/normal.zig").create(self.a) catch |e| return tp.exit_error(e)
        else if (std.mem.eql(u8, mode, "vim/insert"))
            @import("mode/input/vim/insert.zig").create(self.a) catch |e| return tp.exit_error(e)
        else if (std.mem.eql(u8, mode, "vim/visual"))
            @import("mode/input/vim/visual.zig").create(self.a) catch |e| return tp.exit_error(e)
        else if (std.mem.eql(u8, mode, "flow"))
            @import("mode/input/flow.zig").create(self.a) catch |e| return tp.exit_error(e)
        else if (std.mem.eql(u8, mode, "home"))
            @import("mode/input/home.zig").create(self.a) catch |e| return tp.exit_error(e)
        else ret: {
            self.logger.print("unknown mode {s}", .{mode});
            break :ret @import("mode/input/flow.zig").create(self.a) catch |e| return tp.exit_error(e);
        };
        // self.logger.print("input mode: {s}", .{(self.input_mode orelse return).description});
    }

    pub fn enter_mode_default(self: *Self, _: Ctx) tp.result {
        return enter_mode(self, Ctx.fmt(.{self.config.input_mode}));
    }

    pub fn enter_overlay_mode(self: *Self, ctx: Ctx) tp.result {
        var mode: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&mode)}))
            return tp.exit_error(error.InvalidArgument);
        if (self.mini_mode) |_| try cmds.exit_mini_mode(self, .{});
        if (self.input_mode_outer) |*m| {
            m.deinit();
            self.input_mode_outer = null;
        }
        self.input_mode = if (std.mem.eql(u8, mode, "open_recent")) ret: {
            self.input_mode_outer = self.input_mode;
            break :ret @import("mode/overlay/open_recent.zig").create(self.a) catch |e| return tp.exit_error(e);
        } else {
            self.logger.print("unknown mode {s}", .{mode});
            return;
        };
        // self.logger.print("input mode: {s}", .{(self.input_mode orelse return).description});
    }

    pub fn exit_overlay_mode(self: *Self, _: Ctx) tp.result {
        if (self.input_mode_outer) |_| {} else return;
        defer {
            self.input_mode = self.input_mode_outer;
            self.input_mode_outer = null;
        }
        if (self.input_mode) |*mode| mode.deinit();
    }

    pub fn enter_find_mode(self: *Self, ctx: Ctx) tp.result {
        return enter_mini_mode(self, @import("mode/mini/find.zig"), ctx);
    }

    pub fn enter_find_in_files_mode(self: *Self, ctx: Ctx) tp.result {
        return enter_mini_mode(self, @import("mode/mini/find_in_files.zig"), ctx);
    }

    pub fn enter_goto_mode(self: *Self, ctx: Ctx) tp.result {
        return enter_mini_mode(self, @import("mode/mini/goto.zig"), ctx);
    }

    pub fn enter_move_to_char_mode(self: *Self, ctx: Ctx) tp.result {
        return enter_mini_mode(self, @import("mode/mini/move_to_char.zig"), ctx);
    }

    pub fn enter_open_file_mode(self: *Self, ctx: Ctx) tp.result {
        return enter_mini_mode(self, @import("mode/mini/open_file.zig"), ctx);
    }

    const MiniModeFactory = fn (Allocator, Ctx) error{ NotFound, OutOfMemory }!EventHandler;

    fn enter_mini_mode(self: *Self, comptime mode: anytype, ctx: Ctx) tp.result {
        self.input_mode_outer = self.input_mode;
        errdefer {
            self.input_mode = self.input_mode_outer;
            self.input_mode_outer = null;
            self.mini_mode = null;
        }
        const mode_instance = mode.create(self.a, ctx) catch |e| return tp.exit_error(e);
        self.input_mode = .{
            .handler = mode_instance.handler(),
            .name = mode_instance.name(),
            .description = mode_instance.name(),
        };
        self.mini_mode = .{};
    }

    pub fn exit_mini_mode(self: *Self, _: Ctx) tp.result {
        if (self.mini_mode) |_| {} else return;
        defer {
            self.input_mode = self.input_mode_outer;
            self.input_mode_outer = null;
            self.mini_mode = null;
        }
        if (self.input_mode) |*mode| mode.deinit();
    }
};

pub const Mode = struct {
    handler: EventHandler,
    name: []const u8,
    description: []const u8,
    line_numbers: enum { absolute, relative } = .absolute,

    fn deinit(self: *Mode) void {
        self.handler.deinit();
    }
};

pub const MiniModeState = struct {
    text: []const u8 = "",
    cursor: ?usize = null,
};

threadlocal var instance_: ?*Self = null;

pub fn current() *Self {
    return if (instance_) |p| p else @panic("tui call out of context");
}

const OSC = "\x1B]"; // Operating System Command
const ST = "\x1B\\"; // String Terminator
const BEL = "\x07";
const OSC0_title = OSC ++ "0;";
const OSC52_clipboard = OSC ++ "52;c;";
const OSC52_clipboard_paste = OSC ++ "52;p;";
const OSC22_cursor = OSC ++ "22;";
const OSC22_cursor_reply = OSC ++ "22:";

pub fn set_terminal_title(text: []const u8) void {
    var writer = std.io.getStdOut().writer();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const term_cmd = std.fmt.bufPrint(&buf, OSC0_title ++ "{s}" ++ BEL, .{text}) catch return;
    _ = writer.write(term_cmd) catch return;
}

pub fn copy_to_system_clipboard(self: *const Self, text: []const u8) void {
    self.copy_to_system_clipboard_with_errors(text) catch |e| self.logger.err("copy_to_system_clipboard", e);
}

pub fn copy_to_system_clipboard_with_errors(self: *const Self, text: []const u8) !void {
    var writer = std.io.getStdOut().writer();
    const encoder = std.base64.standard.Encoder;
    const size = OSC52_clipboard.len + encoder.calcSize(text.len) + ST.len;
    const buf = try self.a.alloc(u8, size);
    defer self.a.free(buf);
    @memcpy(buf[0..OSC52_clipboard.len], OSC52_clipboard);
    const b64 = encoder.encode(buf[OSC52_clipboard.len..], text);
    @memcpy(buf[OSC52_clipboard.len + b64.len ..], ST);
    _ = try writer.write(buf);
}

pub fn write_stdout(self: *const Self, bytes: []const u8) void {
    _ = std.io.getStdOut().writer().write(bytes) catch |e| self.logger.err("stdout", e);
}

pub fn request_system_clipboard(self: *const Self) void {
    self.write_stdout(OSC52_clipboard ++ "?" ++ ST);
}

pub fn request_mouse_cursor_text(self: *const Self, push_or_pop: bool) void {
    if (push_or_pop) self.mouse_cursor_push("text") else self.mouse_cursor_pop();
}

pub fn request_mouse_cursor_pointer(self: *const Self, push_or_pop: bool) void {
    if (push_or_pop) self.mouse_cursor_push("pointer") else self.mouse_cursor_pop();
}

pub fn request_mouse_cursor_default(self: *const Self, push_or_pop: bool) void {
    if (push_or_pop) self.mouse_cursor_push("default") else self.mouse_cursor_pop();
}

fn mouse_cursor_push(self: *const Self, comptime name: []const u8) void {
    self.write_stdout(OSC22_cursor ++ name ++ ST);
}

fn mouse_cursor_pop(self: *const Self) void {
    self.write_stdout(OSC22_cursor ++ "default" ++ ST);
}

fn match_code(self: *const Self, match: []const u8, skip: usize) bool {
    const code = self.escape_code.items;
    if (!(code.len >= match.len - skip)) return false;
    const code_prefix = code[0 .. match.len - skip];
    return std.mem.eql(u8, match[skip..], code_prefix);
}

fn handle_OSC_escape_code(self: *Self) tp.result {
    self.escape_state = .none;
    self.escape_initial = null;
    defer self.escape_code.clearAndFree();
    const code = self.escape_code.items;
    if (self.match_code(OSC52_clipboard, OSC.len))
        return self.handle_system_clipboard(code[OSC52_clipboard.len - OSC.len ..]);
    if (self.match_code(OSC52_clipboard_paste, OSC.len))
        return self.handle_system_clipboard(code[OSC52_clipboard_paste.len - OSC.len ..]);
    if (self.match_code(OSC22_cursor_reply, OSC.len))
        return self.handle_mouse_cursor(code[OSC22_cursor_reply.len - OSC.len ..]);
    self.logger.print("ignored escape code: OSC {s}", .{std.fmt.fmtSliceEscapeLower(code)});
}

fn handle_system_clipboard(self: *Self, base64: []const u8) tp.result {
    const decoder = std.base64.standard.Decoder;
    // try self.logger.print("clipboard: b64 {s}", .{base64});
    const text = self.a.alloc(
        u8,
        decoder.calcSizeForSlice(base64) catch |e| return tp.exit_error(e),
    ) catch |e| return tp.exit_error(e);
    decoder.decode(text, base64) catch |e| return tp.exit_error(e);
    // try self.logger.print("clipboard: txt {s}", .{std.fmt.fmtSliceEscapeLower(text)});
    return tp.self_pid().send(.{ "system_clipboard", text });
}

fn handle_mouse_cursor(self: *Self, text: []const u8) tp.result {
    self.logger.print("mouse cursor report: {s}", .{text});
}

const CSI = "\x1B["; // Control Sequence Introducer
const CSI_bracketed_paste_enable = CSI ++ "?2004h";
const CSI_bracketed_paste_disable = CSI ++ "?2004h";
const CIS_bracketed_paste_begin = CSI ++ "200~";
const CIS_bracketed_paste_end = CSI ++ "201~";

fn handle_CSI_escape_code(self: *Self) tp.result {
    self.escape_state = .none;
    self.escape_initial = null;
    defer self.escape_code.clearAndFree();
    const code = self.escape_code.items;
    if (self.match_code(CIS_bracketed_paste_begin, CSI.len))
        return self.handle_bracketed_paste_begin();
    if (self.match_code(CIS_bracketed_paste_end, CSI.len))
        return self.handle_bracketed_paste_end();
    self.logger.print("ignored escape code: CSI {s}", .{std.fmt.fmtSliceEscapeLower(code)});
}

fn handle_bracketed_paste_begin(self: *Self) tp.result {
    _ = try self.dispatch_flush_input_event();
    self.bracketed_paste_buffer.clearAndFree();
    self.bracketed_paste = true;
}

fn handle_bracketed_paste_input(self: *Self, m: tp.message) !bool {
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    if (try m.match(.{ "I", tp.number, tp.extract(&keypress), tp.extract(&egc), tp.string, 0 })) {
        switch (keypress) {
            nc.key.ENTER => try self.bracketed_paste_buffer.appendSlice("\n"),
            else => if (!nc.key.synthesized_p(keypress)) {
                var buf: [6]u8 = undefined;
                const bytes = try nc.ucs32_to_utf8(&[_]u32{egc}, &buf);
                try self.bracketed_paste_buffer.appendSlice(buf[0..bytes]);
            } else {
                try self.handle_bracketed_paste_end();
                return false;
            },
        }
        return true;
    }
    return false;
}

fn handle_bracketed_paste_end(self: *Self) tp.result {
    defer self.bracketed_paste_buffer.clearAndFree();
    if (!self.bracketed_paste) return;
    self.bracketed_paste = false;
    return tp.self_pid().send(.{ "system_clipboard", self.bracketed_paste_buffer.items });
}

fn bracketed_paste_enable(self: *const Self) void {
    self.write_stdout(CSI_bracketed_paste_enable);
}

fn bracketed_paste_disable(self: *const Self) void {
    self.write_stdout(CSI_bracketed_paste_disable);
}

pub inline fn fg_channels_from_style(channels: *u64, style: Widget.Theme.Style) void {
    if (style.fg) |fg| {
        nc.channels_set_fg_rgb(channels, fg) catch {};
        nc.channels_set_fg_alpha(channels, nc.ALPHA_OPAQUE) catch {};
    }
}

pub inline fn bg_channels_from_style(channels: *u64, style: Widget.Theme.Style) void {
    if (style.bg) |bg| {
        nc.channels_set_bg_rgb(channels, bg) catch {};
        nc.channels_set_bg_alpha(channels, nc.ALPHA_OPAQUE) catch {};
    }
}

pub inline fn channels_from_style(channels: *u64, style: Widget.Theme.Style) void {
    fg_channels_from_style(channels, style);
    bg_channels_from_style(channels, style);
}

pub inline fn set_cell_style(cell: *nc.Cell, style: Widget.Theme.Style) void {
    channels_from_style(&cell.channels, style);
    if (style.fs) |fs| switch (fs) {
        .normal => nc.cell_set_styles(cell, nc.style.none),
        .bold => nc.cell_set_styles(cell, nc.style.bold),
        .italic => nc.cell_set_styles(cell, nc.style.italic),
        .underline => nc.cell_set_styles(cell, nc.style.underline),
        .strikethrough => nc.cell_set_styles(cell, nc.style.struck),
    };
}

pub inline fn set_cell_style_fg(cell: *nc.Cell, style: Widget.Theme.Style) void {
    fg_channels_from_style(&cell.channels, style);
}

pub inline fn set_cell_style_bg(cell: *nc.Cell, style: Widget.Theme.Style) void {
    bg_channels_from_style(&cell.channels, style);
}

pub inline fn set_base_style(plane: *const nc.Plane, egc: [*c]const u8, style: Widget.Theme.Style) void {
    var channels: u64 = 0;
    channels_from_style(&channels, style);
    if (style.fg) |fg| plane.set_fg_rgb(fg) catch {};
    if (style.bg) |bg| plane.set_bg_rgb(bg) catch {};
    _ = plane.set_base(egc, 0, channels) catch {};
}

pub fn set_base_style_alpha(plane: nc.Plane, egc: [*:0]const u8, style: Widget.Theme.Style, fg_alpha: c_uint, bg_alpha: c_uint) !void {
    var channels: u64 = 0;
    if (style.fg) |fg| {
        nc.channels_set_fg_rgb(&channels, fg) catch {};
        nc.channels_set_fg_alpha(&channels, fg_alpha) catch {};
    }
    if (style.bg) |bg| {
        nc.channels_set_bg_rgb(&channels, bg) catch {};
        nc.channels_set_bg_alpha(&channels, bg_alpha) catch {};
    }
    if (style.fg) |fg| plane.set_fg_rgb(fg) catch {};
    if (style.bg) |bg| plane.set_bg_rgb(bg) catch {};
    _ = plane.set_base(egc, 0, channels) catch {};
}

pub inline fn set_style(plane: *const nc.Plane, style: Widget.Theme.Style) void {
    var channels: u64 = 0;
    channels_from_style(&channels, style);
    plane.set_channels(channels);
    if (style.fs) |fs| switch (fs) {
        .normal => plane.set_styles(nc.style.none),
        .bold => plane.set_styles(nc.style.bold),
        .italic => plane.set_styles(nc.style.italic),
        .underline => plane.set_styles(nc.style.underline),
        .strikethrough => plane.set_styles(nc.style.struck),
    };
}

pub fn get_mode() []const u8 {
    return if (current().input_mode) |m| m.name else "INI";
}

pub fn need_render() void {
    tp.self_pid().send(.{"render"}) catch {};
}

pub fn get_theme_by_name(name: []const u8) ?Widget.Theme {
    for (Widget.themes) |theme| {
        if (std.mem.eql(u8, theme.name, name))
            return theme;
    }
    return null;
}

pub fn get_next_theme_by_name(name: []const u8) Widget.Theme {
    var next = false;
    for (Widget.themes) |theme| {
        if (next)
            return theme;
        if (std.mem.eql(u8, theme.name, name))
            next = true;
    }
    return Widget.themes[0];
}

pub fn get_prev_theme_by_name(name: []const u8) Widget.Theme {
    var prev: ?Widget.Theme = null;
    for (Widget.themes) |theme| {
        if (std.mem.eql(u8, theme.name, name))
            return prev orelse Widget.themes[Widget.themes.len - 1];
        prev = theme;
    }
    return Widget.themes[Widget.themes.len - 1];
}

pub fn find_scope_style(theme: *const Widget.Theme, scope: []const u8) ?Widget.Theme.Token {
    return if (find_scope_fallback(scope)) |tm_scope| find_scope_style_nofallback(theme, tm_scope) orelse find_scope_style_nofallback(theme, scope) else find_scope_style_nofallback(theme, scope);
}

fn find_scope_style_nofallback(theme: *const Widget.Theme, scope: []const u8) ?Widget.Theme.Token {
    var idx = theme.tokens.len - 1;
    var done = false;
    while (!done) : (if (idx == 0) {
        done = true;
    } else {
        idx -= 1;
    }) {
        const token = theme.tokens[idx];
        const name = Widget.scopes[token.id];
        if (name.len > scope.len)
            continue;
        if (std.mem.eql(u8, name, scope[0..name.len]))
            return token;
    }
    return null;
}

fn find_scope_fallback(scope: []const u8) ?[]const u8 {
    for (fallbacks) |fallback| {
        if (fallback.ts.len > scope.len)
            continue;
        if (std.mem.eql(u8, fallback.ts, scope[0..fallback.ts.len]))
            return fallback.tm;
    }
    return null;
}

pub const FallBack = struct { ts: []const u8, tm: []const u8 };
pub const fallbacks: []const FallBack = &[_]FallBack{
    .{ .ts = "namespace", .tm = "entity.name.namespace" },
    .{ .ts = "type", .tm = "entity.name.type" },
    .{ .ts = "type.defaultLibrary", .tm = "support.type" },
    .{ .ts = "struct", .tm = "storage.type.struct" },
    .{ .ts = "class", .tm = "entity.name.type.class" },
    .{ .ts = "class.defaultLibrary", .tm = "support.class" },
    .{ .ts = "interface", .tm = "entity.name.type.interface" },
    .{ .ts = "enum", .tm = "entity.name.type.enum" },
    .{ .ts = "function", .tm = "entity.name.function" },
    .{ .ts = "function.defaultLibrary", .tm = "support.function" },
    .{ .ts = "method", .tm = "entity.name.function.member" },
    .{ .ts = "macro", .tm = "entity.name.function.macro" },
    .{ .ts = "variable", .tm = "variable.other.readwrite , entity.name.variable" },
    .{ .ts = "variable.readonly", .tm = "variable.other.constant" },
    .{ .ts = "variable.readonly.defaultLibrary", .tm = "support.constant" },
    .{ .ts = "parameter", .tm = "variable.parameter" },
    .{ .ts = "property", .tm = "variable.other.property" },
    .{ .ts = "property.readonly", .tm = "variable.other.constant.property" },
    .{ .ts = "enumMember", .tm = "variable.other.enummember" },
    .{ .ts = "event", .tm = "variable.other.event" },

    // zig
    .{ .ts = "attribute", .tm = "keyword" },
    .{ .ts = "number", .tm = "constant.numeric" },
    .{ .ts = "conditional", .tm = "keyword.control.conditional" },
    .{ .ts = "operator", .tm = "keyword.operator" },
    .{ .ts = "boolean", .tm = "keyword.constant.bool" },
    .{ .ts = "string", .tm = "string.quoted" },
    .{ .ts = "repeat", .tm = "keyword.control.flow" },
    .{ .ts = "field", .tm = "variable" },
};
