const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const config = @import("config");
const project_manager = @import("project_manager");
const root = @import("root");
const tracy = @import("tracy");
const builtin = @import("builtin");

pub const renderer = @import("renderer");
const command = @import("command");
const EventHandler = @import("EventHandler");
const keybind = @import("keybind");

const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");
const mainview = @import("mainview.zig");

const Allocator = std.mem.Allocator;

allocator: Allocator,
rdr: renderer,
config: config,
frame_time: usize, // in microseconds
frame_clock: tp.metronome,
frame_clock_running: bool = false,
frame_last_time: i64 = 0,
receiver: Receiver,
mainview: Widget,
message_filters: MessageFilter.List,
input_mode: ?Mode,
input_mode_outer: ?Mode = null,
input_listeners: EventHandler.List,
keyboard_focus: ?Widget = null,
mini_mode: ?MiniMode = null,
hover_focus: ?*Widget = null,
last_hover_x: c_int = -1,
last_hover_y: c_int = -1,
commands: Commands = undefined,
logger: log.Logger,
drag_source: ?*Widget = null,
theme: Widget.Theme,
idle_frame_count: usize = 0,
unrendered_input_events_count: usize = 0,
init_timer: ?tp.timeout,
sigwinch_signal: ?tp.signal = null,
no_sleep: bool = false,
final_exit: []const u8 = "normal",
render_pending: bool = false,
keepalive_timer: ?tp.Cancellable = null,
mouse_idle_timer: ?tp.Cancellable = null,

const keepalive = std.time.us_per_day * 365; // one year
const idle_frames = 0;
const mouse_idle_time_milliseconds = 3000;

const init_delay = 1; // ms

const Self = @This();

const Receiver = tp.Receiver(*Self);
const Commands = command.Collection(cmds);

const StartArgs = struct { allocator: Allocator };

pub fn spawn(allocator: Allocator, ctx: *tp.context, eh: anytype, env: ?*const tp.env) !tp.pid {
    return try ctx.spawn_link(StartArgs{ .allocator = allocator }, start, "tui", eh, env);
}

fn start(args: StartArgs) tp.result {
    command.context_check = &context_check;
    _ = tp.set_trap(true);
    var self = init(args.allocator) catch |e| return tp.exit_error(e, @errorReturnTrace());
    errdefer self.deinit();
    tp.receive(&self.receiver);
}

fn init(allocator: Allocator) !*Self {
    var self = try allocator.create(Self);
    var conf_buf: ?[]const u8 = null;
    var conf = root.read_config(allocator, &conf_buf);
    defer if (conf_buf) |buf| allocator.free(buf);

    const theme = get_theme_by_name(conf.theme) orelse get_theme_by_name("dark_modern") orelse return tp.exit("unknown theme");
    conf.theme = theme.name;
    conf.whitespace_mode = try allocator.dupe(u8, conf.whitespace_mode);
    conf.input_mode = try allocator.dupe(u8, conf.input_mode);
    conf.top_bar = try allocator.dupe(u8, conf.top_bar);
    conf.bottom_bar = try allocator.dupe(u8, conf.bottom_bar);

    const frame_rate: usize = @intCast(tp.env.get().num("frame-rate"));
    if (frame_rate != 0)
        conf.frame_rate = frame_rate;
    tp.env.get().num_set("frame-rate", @intCast(conf.frame_rate));
    tp.env.get().num_set("lsp-request-timeout", @intCast(conf.lsp_request_timeout));
    const frame_time = std.time.us_per_s / conf.frame_rate;
    const frame_clock = try tp.metronome.init(frame_time);

    self.* = .{
        .allocator = allocator,
        .config = conf,
        .rdr = try renderer.init(allocator, self, tp.env.get().is("no-alternate")),
        .frame_time = frame_time,
        .frame_clock = frame_clock,
        .frame_clock_running = true,
        .receiver = Receiver.init(receive, self),
        .mainview = undefined,
        .message_filters = MessageFilter.List.init(allocator),
        .input_mode = null,
        .input_listeners = EventHandler.List.init(allocator),
        .logger = log.logger("tui"),
        .init_timer = try tp.timeout.init_ms(init_delay, tp.message.fmt(.{"init"})),
        .theme = theme,
        .no_sleep = tp.env.get().is("no-sleep"),
    };
    instance_ = self;
    defer instance_ = null;

    self.rdr.handler_ctx = self;
    self.rdr.dispatch_input = dispatch_input;
    self.rdr.dispatch_mouse = dispatch_mouse;
    self.rdr.dispatch_mouse_drag = dispatch_mouse_drag;
    self.rdr.dispatch_event = dispatch_event;
    try self.rdr.run();

    try frame_clock.start();
    try self.commands.init(self);
    errdefer self.deinit();
    switch (builtin.os.tag) {
        .windows => {
            self.keepalive_timer = try tp.self_pid().delay_send_cancellable(allocator, "tui.keepalive", keepalive, .{"keepalive"});
        },
        else => {
            try self.listen_sigwinch();
        },
    }
    self.mainview = try mainview.create(allocator);
    self.resize();
    self.set_terminal_style();
    try self.rdr.render();
    try self.save_config();
    if (tp.env.get().is("restore-session")) {
        command.executeName("restore_session", .{}) catch |e| self.logger.err("restore_session", e);
        self.logger.print("session restored", .{});
    }
    need_render();
    return self;
}

fn init_delayed(self: *Self) !void {
    if (self.input_mode) |_| {} else return cmds.enter_mode(self, command.Context.fmt(.{self.config.input_mode}));
}

fn deinit(self: *Self) void {
    if (self.mouse_idle_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.mouse_idle_timer = null;
    }
    if (self.keepalive_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.keepalive_timer = null;
    }
    if (self.input_mode) |*m| m.deinit();
    self.commands.deinit();
    self.mainview.deinit(self.allocator);
    self.message_filters.deinit();
    self.input_listeners.deinit();
    if (self.frame_clock_running)
        self.frame_clock.stop() catch {};
    if (self.sigwinch_signal) |sig| sig.deinit();
    self.frame_clock.deinit();
    self.rdr.stop();
    self.rdr.deinit();
    self.logger.deinit();
    self.allocator.destroy(self);
}

fn listen_sigwinch(self: *Self) tp.result {
    if (self.sigwinch_signal) |old| old.deinit();
    self.sigwinch_signal = tp.signal.init(std.posix.SIG.WINCH, tp.message.fmt(.{"sigwinch"})) catch |e| return tp.exit_error(e, @errorReturnTrace());
}

fn update_mouse_idle_timer(self: *Self) void {
    const delay = std.time.us_per_ms * @as(u64, mouse_idle_time_milliseconds);
    if (self.mouse_idle_timer) |*t| {
        t.cancel() catch {};
        t.deinit();
        self.mouse_idle_timer = null;
    }
    self.mouse_idle_timer = tp.self_pid().delay_send_cancellable(self.allocator, "tui.mouse_idle_timer", delay, .{"MOUSE_IDLE"}) catch return;
}

fn receive(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
    const frame = tracy.initZone(@src(), .{ .name = "tui" });
    defer frame.deinit();
    instance_ = self;
    defer instance_ = null;
    errdefer {
        var err: tp.ScopedError = .{};
        tp.store_error(&err);
        defer tp.restore_error(&err);
        self.deinit();
    }

    self.receive_safe(from, m) catch |e| {
        if (std.mem.eql(u8, "normal", tp.error_text()))
            return error.Exit;
        if (std.mem.eql(u8, "restart", tp.error_text()))
            return error.Exit;
        self.logger.err("UI", tp.exit_error(e, @errorReturnTrace()));
    };
}

fn receive_safe(self: *Self, from: tp.pid_ref, m: tp.message) !void {
    var input: []const u8 = undefined;
    var text: []const u8 = undefined;
    if (try m.match(.{ "VXS", tp.extract(&input), tp.extract(&text) })) {
        try self.rdr.process_input_event(input, if (text.len > 0) text else null);
        try self.dispatch_flush_input_event();
        if (self.unrendered_input_events_count > 0 and !self.frame_clock_running)
            need_render();
        return;
    }

    if (self.message_filters.filter(from, m) catch |e| return self.logger.err("filter", e))
        return;

    var cmd: []const u8 = undefined;
    var cmd_id: command.ID = undefined;
    var ctx: cmds.Ctx = .{};
    if (try m.match(.{ "cmd", tp.extract(&cmd) }))
        return command.executeName(cmd, ctx) catch |e| self.logger.err(cmd, e);
    if (try m.match(.{ "cmd", tp.extract(&cmd_id) }))
        return command.execute(cmd_id, ctx) catch |e| self.logger.err("command", e);

    var arg: []const u8 = undefined;

    if (try m.match(.{ "cmd", tp.extract(&cmd), tp.extract_cbor(&arg) })) {
        ctx.args = .{ .buf = arg };
        return command.executeName(cmd, ctx) catch |e| self.logger.err(cmd, e);
    }
    if (try m.match(.{ "cmd", tp.extract(&cmd_id), tp.extract_cbor(&arg) })) {
        ctx.args = .{ .buf = arg };
        return command.execute(cmd_id, ctx) catch |e| self.logger.err("command", e);
    }
    if (try m.match(.{"quit"})) {
        project_manager.shutdown();
        return;
    }
    if (try m.match(.{ "project_manager", "shutdown" })) {
        return tp.exit(self.final_exit);
    }

    if (try m.match(.{"restart"})) {
        _ = try self.mainview.msg(.{"write_restore_info"});
        project_manager.shutdown();
        self.final_exit = "restart";
        return;
    }

    if (builtin.os.tag != .windows)
        if (try m.match(.{"sigwinch"})) {
            try self.listen_sigwinch();
            self.rdr.sigwinch() catch |e| return self.logger.err("query_resize", e);
            return;
        };

    if (try m.match(.{"resize"})) {
        self.resize();
        return;
    }

    if (try m.match(.{ "system_clipboard", tp.string })) {
        if (self.active_event_handler()) |eh|
            eh.send(tp.self_pid(), m) catch |e| self.logger.err("clipboard handler", e);
        return;
    }

    if (try m.match(.{"render"})) {
        self.render_pending = false;
        if (!self.frame_clock_running)
            self.render();
        return;
    }

    var counter: usize = undefined;
    if (try m.match(.{ "tick", tp.extract(&counter) })) {
        self.render();
        return;
    }

    if (try m.match(.{"init"})) {
        try self.init_delayed();
        self.render();
        if (self.init_timer) |*timer| {
            timer.deinit();
            self.init_timer = null;
        } else {
            return tp.unexpected(m);
        }
        return;
    }

    if (try m.match(.{"focus_in"}))
        return;

    if (try m.match(.{"focus_out"}))
        return;

    if (try self.send_widgets(from, m))
        return;

    if (try m.match(.{ "exit", tp.more })) {
        if (try m.match(.{ tp.string, "normal" }) or
            try m.match(.{ tp.string, "timeout_error", 125, "Operation aborted." }) or
            try m.match(.{ tp.string, "DEADSEND", tp.more }) or
            try m.match(.{ tp.string, "error.LspFailed", tp.more }) or
            try m.match(.{ tp.string, "error.NoLsp", tp.more }))
            return;
    }

    var msg: []const u8 = undefined;
    if (try m.match(.{ "exit", tp.extract(&msg) }) or try m.match(.{ "exit", tp.extract(&msg), tp.more })) {
        self.logger.err_msg("tui", msg);
        return;
    }

    if (try m.match(.{ "PRJ", tp.more })) // drop late project manager query responses
        return;

    if (try m.match(.{"MOUSE_IDLE"})) {
        if (self.mouse_idle_timer) |*t| t.deinit();
        self.mouse_idle_timer = null;
        try self.clear_hover_focus();
        return;
    }

    return tp.unexpected(m);
}

fn render(self: *Self) void {
    const current_time = std.time.microTimestamp();
    if (current_time < self.frame_last_time) { // clock moved backwards
        self.frame_last_time = current_time;
        return;
    }
    const time_delta = current_time - self.frame_last_time;
    if (!(time_delta >= self.frame_time * 2 / 3)) {
        if (self.frame_clock_running)
            return;
    }
    self.frame_last_time = current_time;

    {
        const frame = tracy.initZone(@src(), .{ .name = "tui update" });
        defer frame.deinit();
        self.mainview.update();
    }

    const more = ret: {
        const frame = tracy.initZone(@src(), .{ .name = "tui render" });
        defer frame.deinit();
        self.rdr.stdplane().erase();
        break :ret self.mainview.render(&self.theme);
    };

    {
        const frame = tracy.initZone(@src(), .{ .name = renderer.log_name ++ " render" });
        defer frame.deinit();
        self.rdr.render() catch |e| self.logger.err("render", e);
        tracy.frameMark();
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

fn active_event_handler(self: *Self) ?EventHandler {
    const mode = self.input_mode orelse return null;
    return mode.event_handler orelse mode.input_handler;
}

fn dispatch_flush_input_event(self: *Self) !void {
    var buf: [32]u8 = undefined;
    if (self.active_event_handler()) |eh|
        try eh.send(tp.self_pid(), try tp.message.fmtbuf(&buf, .{"F"}));
}

fn dispatch_input(ctx: *anyopaque, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const m: tp.message = .{ .buf = cbor_msg };
    const from = tp.self_pid();
    self.unrendered_input_events_count += 1;
    tp.trace(tp.channel.input, m);
    self.input_listeners.send(from, m) catch {};
    if (self.keyboard_focus) |w|
        if (w.send(from, m) catch |e| ret: {
            self.logger.err("focus", e);
            break :ret false;
        })
            return;
    if (self.input_mode) |mode|
        mode.input_handler.send(from, m) catch |e| self.logger.err("input handler", e);
}

fn dispatch_mouse(ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.update_mouse_idle_timer();
    const m: tp.message = .{ .buf = cbor_msg };
    const from = tp.self_pid();
    self.unrendered_input_events_count += 1;
    const send_func = if (self.drag_source) |_| &send_mouse_drag else &send_mouse;
    send_func(self, y, x, from, m) catch |e| self.logger.err("dispatch mouse", e);
    self.drag_source = null;
}

fn dispatch_mouse_drag(ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.update_mouse_idle_timer();
    const m: tp.message = .{ .buf = cbor_msg };
    const from = tp.self_pid();
    self.unrendered_input_events_count += 1;
    if (self.drag_source == null) self.drag_source = self.find_coord_widget(@intCast(y), @intCast(x));
    self.send_mouse_drag(y, x, from, m) catch |e| self.logger.err("dispatch mouse", e);
}

fn dispatch_event(ctx: *anyopaque, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const m: tp.message = .{ .buf = cbor_msg };
    self.unrendered_input_events_count += 1;
    self.dispatch_flush_input_event() catch |e| self.logger.err("dispatch event flush", e);
    tp.self_pid().send_raw(m) catch |e| self.logger.err("dispatch event", e);
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

fn send_mouse(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) tp.result {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners.send(from, m) catch {};
    if (self.keyboard_focus) |w| {
        _ = try w.send(from, m);
        return;
    }
    if (try self.update_hover(y, x)) |w|
        _ = try w.send(from, m);
}

fn send_mouse_drag(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) tp.result {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners.send(from, m) catch {};
    if (self.keyboard_focus) |w| {
        _ = try w.send(from, m);
        return;
    }
    _ = try self.update_hover(y, x);
    if (self.drag_source) |w| _ = try w.send(from, m);
}

fn update_hover(self: *Self, y: c_int, x: c_int) !?*Widget {
    self.last_hover_y = y;
    self.last_hover_x = x;
    if (y > 0 and x > 0) if (self.find_coord_widget(@intCast(y), @intCast(x))) |w| {
        if (if (self.hover_focus) |h| h != w else true) {
            var buf: [256]u8 = undefined;
            if (self.hover_focus) |h| {
                if (self.is_live_widget_ptr(h))
                    _ = try h.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", false }) catch |e| return tp.exit_error(e, @errorReturnTrace()));
            }
            self.hover_focus = w;
            _ = try w.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", true }) catch |e| return tp.exit_error(e, @errorReturnTrace()));
        }
        return w;
    };
    try self.clear_hover_focus();
    return null;
}

fn clear_hover_focus(self: *Self) tp.result {
    if (self.hover_focus) |h| {
        var buf: [256]u8 = undefined;
        if (self.is_live_widget_ptr(h))
            _ = try h.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", false }) catch |e| return tp.exit_error(e, @errorReturnTrace()));
    }
    self.hover_focus = null;
}

pub fn refresh_hover(self: *Self) void {
    self.clear_hover_focus() catch return;
    _ = self.update_hover(self.last_hover_y, self.last_hover_x) catch {};
}

pub fn save_config(self: *const Self) !void {
    try root.write_config(self.config, self.allocator);
}

fn enter_overlay_mode(self: *Self, mode: type) command.Result {
    if (self.mini_mode) |_| try cmds.exit_mini_mode(self, .{});
    if (self.input_mode_outer) |_| try cmds.exit_overlay_mode(self, .{});
    self.input_mode_outer = self.input_mode;
    self.input_mode = try mode.create(self.allocator);
    self.refresh_hover();
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn restart(_: *Self, _: Ctx) Result {
        try tp.self_pid().send("restart");
    }
    pub const restart_meta = .{ .description = "Restart flow (without saving)" };

    pub fn force_terminate(self: *Self, _: Ctx) Result {
        self.deinit();
        root.print_exit_status({}, "FORCE TERMINATE");
        root.exit(99);
    }
    pub const force_terminate_meta = .{ .description = "Force quit without saving" };

    pub fn set_theme(self: *Self, ctx: Ctx) Result {
        var name: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&name)}))
            return tp.exit_error(error.InvalidArgument, null);
        self.theme = get_theme_by_name(name) orelse {
            self.logger.print("theme not found: {s}", .{name});
            return;
        };
        self.config.theme = self.theme.name;
        self.set_terminal_style();
        self.logger.print("theme: {s}", .{self.theme.description});
        try self.save_config();
    }
    pub const set_theme_meta = .{ .interactive = false };

    pub fn theme_next(self: *Self, _: Ctx) Result {
        self.theme = get_next_theme_by_name(self.theme.name);
        self.config.theme = self.theme.name;
        self.set_terminal_style();
        self.logger.print("theme: {s}", .{self.theme.description});
        try self.save_config();
    }
    pub const theme_next_meta = .{ .description = "Switch to next color theme" };

    pub fn theme_prev(self: *Self, _: Ctx) Result {
        self.theme = get_prev_theme_by_name(self.theme.name);
        self.config.theme = self.theme.name;
        self.set_terminal_style();
        self.logger.print("theme: {s}", .{self.theme.description});
        try self.save_config();
    }
    pub const theme_prev_meta = .{ .description = "Switch to previous color theme" };

    pub fn toggle_whitespace_mode(self: *Self, _: Ctx) Result {
        self.config.whitespace_mode = if (std.mem.eql(u8, self.config.whitespace_mode, "none"))
            "indent"
        else if (std.mem.eql(u8, self.config.whitespace_mode, "indent"))
            "visible"
        else
            "none";
        try self.save_config();
        var buf: [32]u8 = undefined;
        const m = try tp.message.fmtbuf(&buf, .{ "whitespace_mode", self.config.whitespace_mode });
        _ = try self.send_widgets(tp.self_pid(), m);
        self.logger.print("whitespace rendering {s}", .{self.config.whitespace_mode});
    }
    pub const toggle_whitespace_mode_meta = .{ .description = "Switch to next whitespace rendering mode" };

    pub fn toggle_input_mode(self: *Self, _: Ctx) Result {
        self.config.input_mode = if (std.mem.eql(u8, self.config.input_mode, "flow"))
            "vim/normal"
        else if (std.mem.eql(u8, self.config.input_mode, "vim/normal"))
            "helix/normal"
        else
            "flow";
        try self.save_config();
        var it = std.mem.splitScalar(u8, self.config.input_mode, '/');
        self.logger.print("input mode {s}", .{it.first()});
        return enter_mode(self, Ctx.fmt(.{self.config.input_mode}));
    }
    pub const toggle_input_mode_meta = .{ .description = "Switch to next input mode" };

    pub fn enter_mode(self: *Self, ctx: Ctx) Result {
        var mode: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&mode)}))
            return tp.exit_error(error.InvalidArgument, null);
        if (self.mini_mode) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer) |_| try exit_overlay_mode(self, .{});
        if (self.input_mode) |*m| m.deinit();
        self.input_mode = if (std.mem.eql(u8, mode, "vim/normal"))
            try @import("mode/input/vim/normal.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "vim/insert"))
            try @import("mode/input/vim/insert.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "vim/visual"))
            try @import("mode/input/vim/visual.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "helix/normal"))
            try @import("mode/input/helix/normal.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "helix/insert"))
            try @import("mode/input/helix/insert.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "helix/select"))
            try @import("mode/input/helix/select.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "flow"))
            try @import("mode/input/flow.zig").create(self.allocator)
        else if (std.mem.eql(u8, mode, "home"))
            try @import("mode/input/home.zig").create(self.allocator)
        else ret: {
            self.logger.print("unknown mode {s}", .{mode});
            break :ret try @import("mode/input/flow.zig").create(self.allocator);
        };
        // self.logger.print("input mode: {s}", .{(self.input_mode orelse return).description});
    }
    pub const enter_mode_meta = .{ .interactive = false };

    pub fn enter_mode_default(self: *Self, _: Ctx) Result {
        return enter_mode(self, Ctx.fmt(.{self.config.input_mode}));
    }
    pub const enter_mode_default_meta = .{ .interactive = false };

    pub fn open_command_palette(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/command_palette.zig").Type);
    }
    pub const open_command_palette_meta = .{ .interactive = false };

    pub fn open_recent(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent.zig"));
    }
    pub const open_recent_meta = .{ .description = "Open recent file" };

    pub fn open_recent_project(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent_project.zig").Type);
    }
    pub const open_recent_project_meta = .{ .description = "Open recent project" };

    pub fn change_theme(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/theme_palette.zig").Type);
    }
    pub const change_theme_meta = .{ .description = "Select color theme" };

    pub fn exit_overlay_mode(self: *Self, _: Ctx) Result {
        if (self.input_mode_outer == null) return;
        defer {
            self.input_mode = self.input_mode_outer;
            self.input_mode_outer = null;
        }
        if (self.input_mode) |*mode| mode.deinit();
        self.refresh_hover();
    }
    pub const exit_overlay_mode_meta = .{ .interactive = false };

    pub fn find(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/find.zig"), ctx);
    }
    pub const find_meta = .{ .description = "Find in current file" };

    pub fn find_in_files(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/find_in_files.zig"), ctx);
    }
    pub const find_in_files_meta = .{ .description = "Find in all project files" };

    pub fn goto(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/goto.zig"), ctx);
    }
    pub const goto_meta = .{ .description = "Goto line" };

    pub fn move_to_char(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/move_to_char.zig"), ctx);
    }
    pub const move_to_char_meta = .{ .description = "Move cursor to matching character" };

    pub fn open_file(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/open_file.zig"), ctx);
    }
    pub const open_file_meta = .{ .description = "Open file" };

    pub fn save_as(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/save_as.zig"), ctx);
    }
    pub const save_as_meta = .{ .description = "Save as" };

    fn enter_mini_mode(self: *Self, comptime mode: anytype, ctx: Ctx) Result {
        if (self.mini_mode) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer) |_| try exit_overlay_mode(self, .{});
        self.input_mode_outer = self.input_mode;
        errdefer {
            self.input_mode = self.input_mode_outer;
            self.input_mode_outer = null;
            self.mini_mode = null;
        }
        const input_mode, const mini_mode = try mode.create(self.allocator, ctx);
        self.input_mode = input_mode;
        self.mini_mode = mini_mode;
    }

    pub fn exit_mini_mode(self: *Self, _: Ctx) Result {
        if (self.mini_mode) |_| {} else return;
        if (self.input_mode) |*mode| mode.deinit();
        self.input_mode = self.input_mode_outer;
        self.input_mode_outer = null;
        self.mini_mode = null;
    }
    pub const exit_mini_mode_meta = .{ .interactive = false };
};

pub const MiniMode = struct {
    name: []const u8,
    text: []const u8 = "",
    cursor: ?usize = null,
};

pub const Mode = keybind.Mode;
pub const KeybindHints = keybind.KeybindHints;

threadlocal var instance_: ?*Self = null;

pub fn current() *Self {
    return instance_ orelse @panic("tui call out of context");
}

fn context_check() void {
    if (instance_ == null) @panic("tui call out of context");
}

pub fn get_mode() []const u8 {
    return if (current().mini_mode) |m|
        m.name
    else if (current().input_mode) |m|
        m.name
    else
        "INI";
}

pub fn reset_drag_context() void {
    const self = current();
    self.drag_source = null;
}

pub fn need_render() void {
    const self = current();
    if (!(self.render_pending or self.frame_clock_running)) {
        self.render_pending = true;
        tp.self_pid().send(.{"render"}) catch {};
    }
}

pub fn resize(self: *Self) void {
    self.mainview.resize(self.screen());
    self.refresh_hover();
    need_render();
}

pub fn stdplane(self: *Self) renderer.Plane {
    return self.rdr.stdplane();
}

pub fn screen(self: *Self) Widget.Box {
    return Widget.Box.from(self.rdr.stdplane());
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

fn set_terminal_style(self: *Self) void {
    if (self.config.enable_terminal_color_scheme)
        self.rdr.set_terminal_style(self.theme.editor);
}
