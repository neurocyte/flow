const std = @import("std");
const build_options = @import("build_options");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
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
const MainView = @import("mainview.zig");

const Allocator = std.mem.Allocator;

allocator: Allocator,
rdr: renderer,
config: @import("config"),
frame_time: usize, // in microseconds
frame_clock: tp.metronome,
frame_clock_running: bool = false,
frame_last_time: i64 = 0,
receiver: Receiver,
mainview: ?Widget = null,
message_filters: MessageFilter.List,
input_mode: ?Mode = null,
delayed_init_done: bool = false,
delayed_init_input_mode: ?Mode = null,
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
default_cursor: keybind.CursorShape = .default,
fontface: []const u8 = "",
fontfaces: std.ArrayListUnmanaged([]const u8) = .{},
enable_mouse_idle_timer: bool = false,

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
    var conf, const conf_bufs = root.read_config(@import("config"), allocator);
    defer root.free_config(allocator, conf_bufs);

    const theme_ = get_theme_by_name(conf.theme) orelse get_theme_by_name("dark_modern") orelse return tp.exit("unknown theme");
    conf.theme = theme_.name;
    conf.whitespace_mode = try allocator.dupe(u8, conf.whitespace_mode);
    conf.input_mode = try allocator.dupe(u8, conf.input_mode);
    conf.top_bar = try allocator.dupe(u8, conf.top_bar);
    conf.bottom_bar = try allocator.dupe(u8, conf.bottom_bar);
    conf.include_files = try allocator.dupe(u8, conf.include_files);
    if (build_options.gui) conf.enable_terminal_cursor = false;

    const frame_rate: usize = @intCast(tp.env.get().num("frame-rate"));
    if (frame_rate != 0)
        conf.frame_rate = frame_rate;
    tp.env.get().num_set("frame-rate", @intCast(conf.frame_rate));
    tp.env.get().num_set("lsp-request-timeout", @intCast(conf.lsp_request_timeout));
    const frame_time = std.time.us_per_s / conf.frame_rate;
    const frame_clock = try tp.metronome.init(frame_time);

    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .config = conf,
        .rdr = try renderer.init(allocator, self, tp.env.get().is("no-alternate"), dispatch_initialized),
        .frame_time = frame_time,
        .frame_clock = frame_clock,
        .frame_clock_running = true,
        .receiver = Receiver.init(receive, self),
        .message_filters = MessageFilter.List.init(allocator),
        .input_listeners = EventHandler.List.init(allocator),
        .logger = log.logger("tui"),
        .init_timer = if (build_options.gui) null else try tp.timeout.init_ms(init_delay, tp.message.fmt(
            .{"init"},
        )),
        .theme = theme_,
        .no_sleep = tp.env.get().is("no-sleep"),
    };
    instance_ = self;
    defer instance_ = null;

    self.default_cursor = std.meta.stringToEnum(keybind.CursorShape, conf.default_cursor) orelse .default;
    self.config.default_cursor = @tagName(self.default_cursor);
    self.rdr.handler_ctx = self;
    self.rdr.dispatch_input = dispatch_input;
    self.rdr.dispatch_mouse = dispatch_mouse;
    self.rdr.dispatch_mouse_drag = dispatch_mouse_drag;
    self.rdr.dispatch_event = dispatch_event;
    try self.rdr.run();

    try project_manager.start();

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
    self.mainview = try MainView.create(allocator);
    resize();
    self.set_terminal_style();
    try save_config();
    try self.init_input_namespace();
    if (tp.env.get().is("restore-session")) {
        command.executeName("restore_session", .{}) catch |e| self.logger.err("restore_session", e);
        self.logger.print("session restored", .{});
    }
    return self;
}

fn init_input_namespace(self: *Self) !void {
    var mode_parts = std.mem.splitScalar(u8, self.config.input_mode, '/');
    const namespace_name = mode_parts.first();
    keybind.set_namespace(namespace_name) catch {
        self.logger.print_err("keybind", "unknown mode {s}", .{namespace_name});
        try keybind.set_namespace("flow");
        self.config.input_mode = "flow";
        try save_config();
    };
}

fn init_delayed(self: *Self) !void {
    self.delayed_init_done = true;
    if (self.input_mode) |_| {} else {
        if (self.delayed_init_input_mode) |delayed_init_input_mode| {
            try enter_input_mode(self, delayed_init_input_mode);
            self.delayed_init_input_mode = null;
        } else {
            try cmds.enter_mode(self, command.Context.fmt(.{keybind.default_mode}));
        }
    }
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
    if (self.input_mode) |*m| {
        m.deinit();
        self.input_mode = null;
    }
    if (self.delayed_init_input_mode) |*m| {
        m.deinit();
        self.delayed_init_input_mode = null;
    }
    self.commands.deinit();
    if (self.mainview) |*mv| mv.deinit(self.allocator);
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
    if (!self.enable_mouse_idle_timer) return;
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
    if (try m.match(.{ "RDR", tp.more })) {
        self.rdr.process_renderer_event(m.buf) catch |e| switch (e) {
            error.UnexpectedRendererEvent => return tp.unexpected(m),
            else => return e,
        };
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
        if (mainview()) |mv| mv.write_restore_info();
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
        resize();
        const box = screen();
        message("{d}x{d}", .{ box.w, box.h });
        return;
    }

    var text: []const u8 = undefined;
    if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        try self.dispatch_flush_input_event();
        return if (command.get_id("mini_mode_paste")) |id|
            command.execute(id, command.fmt(.{text}))
        else
            command.executeName("paste", command.fmt(.{text}));
    }

    if (try m.match(.{ "system_clipboard", tp.null_ }))
        return self.logger.err_msg("clipboard", "clipboard request denied or empty");

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
        } else if (!build_options.gui) {
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

    if (try m.match(.{ "fontface", "done" })) {
        return self.enter_overlay_mode(@import("mode/overlay/fontface_palette.zig").Type);
    }

    var fontface_: []const u8 = undefined;
    if (try m.match(.{ "fontface", "current", tp.extract(&fontface_) })) {
        if (self.fontface.len > 0) self.allocator.free(self.fontface);
        self.fontface = "";
        self.fontface = try self.allocator.dupe(u8, fontface_);
        return;
    }

    if (try m.match(.{ "fontface", tp.extract(&fontface_) })) {
        try self.fontfaces.append(self.allocator, try self.allocator.dupe(u8, fontface_));
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
        if (self.mainview) |mv| mv.update();
    }

    const more = ret: {
        const frame = tracy.initZone(@src(), .{ .name = "tui render" });
        defer frame.deinit();
        self.rdr.stdplane().erase();
        break :ret if (self.mainview) |mv| mv.render(&self.theme) else false;
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
    const mode = self.input_mode orelse return;
    try mode.input_handler.send(tp.self_pid(), try tp.message.fmtbuf(&buf, .{"F"}));
    if (mode.event_handler) |eh| try eh.send(tp.self_pid(), try tp.message.fmtbuf(&buf, .{"F"}));
}

fn dispatch_initialized(ctx: *anyopaque) void {
    _ = ctx;
    tp.self_pid().send(.{"init"}) catch |e| switch (e) {
        error.Exit => {}, // safe to ignore
    };
}

fn dispatch_input(ctx: *anyopaque, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const m: tp.message = .{ .buf = cbor_msg };
    const from = tp.self_pid();
    self.unrendered_input_events_count += 1;
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
    if (self.mainview) |*mv| _ = mv.walk(&ctx, Ctx.find);
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
    return if (self.mainview) |*mv| mv.walk(&ctx, Ctx.find) else false;
}

fn send_widgets(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    const frame = tracy.initZone(@src(), .{ .name = "tui widgets" });
    defer frame.deinit();
    tp.trace(tp.channel.widget, m);
    return if (self.keyboard_focus) |w|
        w.send(from, m)
    else if (self.mainview) |mv|
        mv.send(from, m)
    else
        false;
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
    if (y >= 0 and x >= 0) if (self.find_coord_widget(@intCast(y), @intCast(x))) |w| {
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

pub fn refresh_hover() void {
    const self = current();
    self.clear_hover_focus() catch return;
    _ = self.update_hover(self.last_hover_y, self.last_hover_x) catch {};
}

pub fn save_config() !void {
    const self = current();
    try root.write_config(self.config, self.allocator);
}

pub fn is_mainview_focused() bool {
    const self = current();
    return self.mini_mode == null and self.input_mode_outer == null;
}

fn enter_overlay_mode(self: *Self, mode: type) command.Result {
    command.executeName("disable_fast_scroll", .{}) catch {};
    command.executeName("disable_jump_mode", .{}) catch {};
    if (self.mini_mode) |_| try cmds.exit_mini_mode(self, .{});
    if (self.input_mode_outer) |_| try cmds.exit_overlay_mode(self, .{});
    self.input_mode_outer = self.input_mode;
    self.input_mode = try mode.create(self.allocator);
    refresh_hover();
}

fn get_input_mode(self: *Self, mode_name: []const u8) !Mode {
    return keybind.mode(mode_name, self.allocator, .{});
}

fn enter_input_mode(self: *Self, new_mode: Mode) command.Result {
    if (self.mini_mode) |_| try cmds.exit_mini_mode(self, .{});
    if (self.input_mode_outer) |_| try cmds.exit_overlay_mode(self, .{});
    if (self.input_mode) |*m| {
        m.deinit();
        self.input_mode = null;
    }
    self.input_mode = new_mode;
}

fn refresh_input_mode(self: *Self) command.Result {
    const mode = (self.input_mode orelse return).mode;
    var new_mode = self.get_input_mode(mode) catch ret: {
        self.logger.print("unknown mode {s}", .{mode});
        break :ret try self.get_input_mode(keybind.default_mode);
    };
    errdefer new_mode.deinit();
    if (self.input_mode) |*m| {
        m.deinit();
        self.input_mode = null;
    }
    self.input_mode = new_mode;
}
pub const enter_mode_meta = .{ .arguments = &.{.string} };

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
            return tp.exit_error(error.InvalidSetThemeArgument, null);
        self.theme = get_theme_by_name(name) orelse {
            self.logger.print("theme not found: {s}", .{name});
            return;
        };
        self.config.theme = self.theme.name;
        self.set_terminal_style();
        self.logger.print("theme: {s}", .{self.theme.description});
        try save_config();
    }
    pub const set_theme_meta = .{ .arguments = &.{.string} };

    pub fn theme_next(self: *Self, _: Ctx) Result {
        self.theme = get_next_theme_by_name(self.theme.name);
        self.config.theme = self.theme.name;
        self.set_terminal_style();
        self.logger.print("theme: {s}", .{self.theme.description});
        try save_config();
    }
    pub const theme_next_meta = .{ .description = "Switch to next color theme" };

    pub fn theme_prev(self: *Self, _: Ctx) Result {
        self.theme = get_prev_theme_by_name(self.theme.name);
        self.config.theme = self.theme.name;
        self.set_terminal_style();
        self.logger.print("theme: {s}", .{self.theme.description});
        try save_config();
    }
    pub const theme_prev_meta = .{ .description = "Switch to previous color theme" };

    pub fn toggle_whitespace_mode(self: *Self, _: Ctx) Result {
        self.config.whitespace_mode = if (std.mem.eql(u8, self.config.whitespace_mode, "none"))
            "indent"
        else if (std.mem.eql(u8, self.config.whitespace_mode, "indent"))
            "leading"
        else if (std.mem.eql(u8, self.config.whitespace_mode, "leading"))
            "eol"
        else if (std.mem.eql(u8, self.config.whitespace_mode, "eol"))
            "tabs"
        else if (std.mem.eql(u8, self.config.whitespace_mode, "tabs"))
            "visible"
        else if (std.mem.eql(u8, self.config.whitespace_mode, "visible"))
            "full"
        else
            "none";
        try save_config();
        var buf: [32]u8 = undefined;
        const m = try tp.message.fmtbuf(&buf, .{ "whitespace_mode", self.config.whitespace_mode });
        _ = try self.send_widgets(tp.self_pid(), m);
        self.logger.print("whitespace rendering {s}", .{self.config.whitespace_mode});
    }
    pub const toggle_whitespace_mode_meta = .{ .description = "Switch to next whitespace rendering mode" };

    pub fn toggle_input_mode(self: *Self, _: Ctx) Result {
        var it = std.mem.splitScalar(u8, self.config.input_mode, '/');
        self.config.input_mode = it.first();

        const namespaces = keybind.get_namespaces(self.allocator) catch |e| return tp.exit_error(e, @errorReturnTrace());
        defer {
            for (namespaces) |namespace| self.allocator.free(namespace);
            self.allocator.free(namespaces);
        }
        var found = false;
        self.config.input_mode = blk: for (namespaces) |namespace| {
            if (found) break :blk try self.allocator.dupe(u8, namespace);
            if (std.mem.eql(u8, namespace, self.config.input_mode))
                found = true;
        } else try self.allocator.dupe(u8, namespaces[0]);

        try save_config();
        self.logger.print("input mode {s}", .{self.config.input_mode});
        try keybind.set_namespace(self.config.input_mode);
        return self.refresh_input_mode();
    }
    pub const toggle_input_mode_meta = .{ .description = "Switch to next input mode" };

    pub fn enter_mode(self: *Self, ctx: Ctx) Result {
        var mode: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&mode)}))
            return tp.exit_error(error.InvalidEnterModeArgument, null);

        var new_mode = self.get_input_mode(mode) catch ret: {
            self.logger.print("unknown mode {s}", .{mode});
            break :ret try self.get_input_mode(keybind.default_mode);
        };
        errdefer new_mode.deinit();

        if (!self.delayed_init_done) {
            self.delayed_init_input_mode = new_mode;
            return;
        }
        return self.enter_input_mode(new_mode);
    }
    pub const enter_mode_meta = .{ .arguments = &.{.string} };

    pub fn enter_mode_default(self: *Self, _: Ctx) Result {
        return enter_mode(self, Ctx.fmt(.{keybind.default_mode}));
    }
    pub const enter_mode_default_meta = .{};

    pub fn open_command_palette(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/command_palette.zig").Type);
    }
    pub const open_command_palette_meta = .{ .description = "Show/Run commands" };

    pub fn insert_command_name(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/list_all_commands_palette.zig").Type);
    }
    pub const insert_command_name_meta = .{ .description = "Insert command name" };

    pub fn open_recent(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent.zig"));
    }
    pub const open_recent_meta = .{ .description = "Open recent file" };

    pub fn open_recent_project(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent_project.zig").Type);
    }
    pub const open_recent_project_meta = .{ .description = "Open recent project" };

    pub fn switch_buffers(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/buffer_palette.zig").Type);
    }
    pub const switch_buffers_meta = .{ .description = "Switch buffers" };

    pub fn select_task(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/task_palette.zig").Type);
    }
    pub const select_task_meta = .{ .description = "Select a task to run" };

    pub fn add_task(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, struct {
            pub const Type = @import("mode/mini/buffer.zig").Create(@This());
            pub const create = Type.create;
            pub fn name(_: *Type) []const u8 {
                return @import("mode/overlay/task_palette.zig").name;
            }
            pub fn select(self_: *Type) void {
                project_manager.add_task(self_.input.items) catch |e| {
                    const logger = log.logger("tui");
                    logger.err("add_task", e);
                    logger.deinit();
                };
                command.executeName("exit_mini_mode", .{}) catch {};
                command.executeName("select_task", .{}) catch {};
            }
        }, ctx);
    }
    pub const add_task_meta = .{ .description = "Add a task to run" };

    pub fn delete_task(_: *Self, ctx: Ctx) Result {
        var task: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&task)}))
            return error.InvalidDeleteTaskArgument;
        project_manager.delete_task(task) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const delete_task_meta = .{};

    pub fn change_theme(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/theme_palette.zig").Type);
    }
    pub const change_theme_meta = .{ .description = "Select color theme" };

    pub fn change_file_type(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/file_type_palette.zig").Type);
    }
    pub const change_file_type_meta = .{ .description = "Change file type" };

    pub fn change_fontface(self: *Self, _: Ctx) Result {
        if (build_options.gui)
            self.rdr.get_fontfaces();
    }
    pub const change_fontface_meta = .{ .description = "Select font face" };

    pub fn exit_overlay_mode(self: *Self, _: Ctx) Result {
        self.rdr.cursor_disable();
        if (self.input_mode_outer == null) return enter_mode_default(self, .{});
        if (self.input_mode) |*mode| mode.deinit();
        self.input_mode = self.input_mode_outer;
        self.input_mode_outer = null;
        refresh_hover();
    }
    pub const exit_overlay_mode_meta = .{};

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
        if (get_active_selection(self.allocator)) |text| {
            defer self.allocator.free(text);
            const link = try root.file_link.parse(text);
            switch (link) {
                .file => |file| if (file.exists)
                    return root.file_link.navigate(tp.self_pid(), &link),
                else => {},
            }
        }
        return enter_mini_mode(self, @import("mode/mini/open_file.zig"), ctx);
    }
    pub const open_file_meta = .{ .description = "Open file" };

    pub fn save_as(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/save_as.zig"), ctx);
    }
    pub const save_as_meta = .{ .description = "Save as" };

    fn enter_mini_mode(self: *Self, comptime mode: anytype, ctx: Ctx) !void {
        command.executeName("disable_fast_scroll", .{}) catch {};
        command.executeName("disable_jump_mode", .{}) catch {};
        const input_mode_, const mini_mode_ = try mode.create(self.allocator, ctx);
        if (self.mini_mode) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer) |_| try exit_overlay_mode(self, .{});
        if (self.input_mode_outer != null) @panic("exit_overlay_mode failed");
        self.input_mode_outer = self.input_mode;
        self.input_mode = input_mode_;
        self.mini_mode = mini_mode_;
    }

    pub fn exit_mini_mode(self: *Self, _: Ctx) Result {
        self.rdr.cursor_disable();
        if (self.mini_mode) |_| {} else return;
        if (self.input_mode) |*mode| mode.deinit();
        self.input_mode = self.input_mode_outer;
        self.input_mode_outer = null;
        self.mini_mode = null;
    }
    pub const exit_mini_mode_meta = .{};

    pub fn open_keybind_config(self: *Self, _: Ctx) Result {
        var mode_parts = std.mem.splitScalar(u8, self.config.input_mode, '/');
        const namespace_name = mode_parts.first();
        const file_name = try keybind.get_or_create_namespace_config_file(self.allocator, namespace_name);
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
        self.logger.print("restart flow to use changed key bindings", .{});
    }
    pub const open_keybind_config_meta = .{ .description = "Edit key bindings" };

    pub fn run_async(self: *Self, ctx: Ctx) Result {
        var iter = ctx.args.buf;
        var len = try cbor.decodeArrayHeader(&iter);
        if (len < 1)
            return tp.exit_error(error.InvalidRunAsyncArgument, null);

        var cmd: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, cbor.extract(&cmd)))
            return tp.exit_error(error.InvalidRunAsyncArgument, null);
        len -= 1;

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        while (len > 0) : (len -= 1) {
            var arg: []const u8 = undefined;
            if (try cbor.matchValue(&iter, cbor.extract_cbor(&arg))) {
                try args.append(arg);
            } else return tp.exit_error(error.InvalidRunAsyncArgument, null);
        }

        var args_cb = std.ArrayList(u8).init(self.allocator);
        defer args_cb.deinit();
        {
            const writer = args_cb.writer();
            try cbor.writeArrayHeader(writer, args.items.len);
            for (args.items) |arg| try writer.writeAll(arg);
        }

        var msg_cb = std.ArrayList(u8).init(self.allocator);
        defer msg_cb.deinit();
        {
            const writer = msg_cb.writer();
            try cbor.writeArrayHeader(writer, 3);
            try cbor.writeValue(writer, "cmd");
            try cbor.writeValue(writer, cmd);
            try writer.writeAll(args_cb.items);
        }
        try tp.self_pid().send_raw(.{ .buf = msg_cb.items });
    }
    pub const run_async_meta = .{};

    pub fn enter_vim_mode(_: *Self, _: Ctx) Result {
        try @import("mode/vim.zig").init();
    }
    pub const enter_vim_mode_meta = .{};

    pub fn exit_vim_mode(_: *Self, _: Ctx) Result {
        @import("mode/vim.zig").deinit();
    }
    pub const exit_vim_mode_meta = .{};

    pub fn enter_helix_mode(_: *Self, _: Ctx) Result {
        try @import("mode/helix.zig").init();
    }
    pub const enter_helix_mode_meta = .{};

    pub fn exit_helix_mode(_: *Self, _: Ctx) Result {
        @import("mode/helix.zig").deinit();
    }
    pub const exit_helix_mode_meta = .{};
};

pub const MiniMode = struct {
    name: []const u8,
    text: []const u8 = "",
    cursor: ?usize = null,
};

pub const Mode = keybind.Mode;
pub const KeybindHints = keybind.KeybindHints;

threadlocal var instance_: ?*Self = null;

fn current() *Self {
    return instance_ orelse @panic("tui call out of context");
}

pub fn rdr() *renderer {
    return &current().rdr;
}

pub fn message_filters() *MessageFilter.List {
    return &current().message_filters;
}

pub fn input_listeners() *EventHandler.List {
    return &current().input_listeners;
}

pub fn input_mode() ?*Mode {
    return if (current().input_mode) |*p| p else null;
}

pub fn input_mode_outer() ?*Mode {
    return if (current().input_mode_outer) |*p| p else null;
}

pub fn mini_mode() ?*MiniMode {
    return if (current().mini_mode) |*p| p else null;
}

pub fn config() *const @import("config") {
    return &current().config;
}

pub fn config_mut() *@import("config") {
    return &current().config;
}

pub fn mainview() ?*MainView {
    return if (current().mainview) |*mv| mv.dynamic_cast(MainView) else null;
}

pub fn mainview_widget() Widget {
    return current().mainview orelse @panic("tui main view not found");
}

pub fn get_active_editor() ?*@import("editor.zig").Editor {
    if (mainview()) |mv_| if (mv_.get_active_editor()) |editor|
        return editor;
    return null;
}

pub fn get_active_selection(allocator: std.mem.Allocator) ?[]u8 {
    const editor = get_active_editor() orelse return null;
    const sel = editor.get_primary().selection orelse return null;
    return editor.get_selection(sel, allocator) catch null;
}

pub fn get_buffer_manager() ?*@import("Buffer").Manager {
    return if (mainview()) |mv| &mv.buffer_manager else null;
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

pub fn get_keybind_mode() ?Mode {
    const self = current();
    return self.input_mode orelse self.delayed_init_input_mode;
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

pub fn resize() void {
    mainview_widget().resize(screen());
    refresh_hover();
    need_render();
}

pub fn plane() renderer.Plane {
    return current().rdr.stdplane();
}

fn stdplane(self: *Self) renderer.Plane {
    return self.rdr.stdplane();
}

pub fn egc_chunk_width(chunk: []const u8, abs_col: usize, tab_width: usize) usize {
    return plane().egc_chunk_width(chunk, abs_col, tab_width);
}

pub fn egc_last(egcs: []const u8) []const u8 {
    return plane().egc_last(egcs);
}

pub fn screen() Widget.Box {
    return Widget.Box.from(plane());
}

pub fn fontface() []const u8 {
    return current().fontface;
}

pub fn fontfaces(allocator: std.mem.Allocator) error{OutOfMemory}![][]const u8 {
    return current().fontfaces.toOwnedSlice(allocator);
}

pub fn theme() *const Widget.Theme {
    return &current().theme;
}

pub fn get_theme_by_name(name: []const u8) ?Widget.Theme {
    for (Widget.themes) |theme_| {
        if (std.mem.eql(u8, theme_.name, name))
            return theme_;
    }
    return null;
}

pub fn get_next_theme_by_name(name: []const u8) Widget.Theme {
    var next = false;
    for (Widget.themes) |theme_| {
        if (next)
            return theme_;
        if (std.mem.eql(u8, theme_.name, name))
            next = true;
    }
    return Widget.themes[0];
}

pub fn get_prev_theme_by_name(name: []const u8) Widget.Theme {
    var prev: ?Widget.Theme = null;
    for (Widget.themes) |theme_| {
        if (std.mem.eql(u8, theme_.name, name))
            return prev orelse Widget.themes[Widget.themes.len - 1];
        prev = theme_;
    }
    return Widget.themes[Widget.themes.len - 1];
}

pub fn find_scope_style(theme_: *const Widget.Theme, scope: []const u8) ?Widget.Theme.Token {
    return if (find_scope_fallback(scope)) |tm_scope|
        scope_to_theme_token(theme_, tm_scope) orelse
            scope_to_theme_token(theme_, scope)
    else
        scope_to_theme_token(theme_, scope);
}

fn scope_to_theme_token(theme_: *const Widget.Theme, document_scope: []const u8) ?Widget.Theme.Token {
    var idx = theme_.tokens.len - 1;
    var matched: ?Widget.Theme.Token = null;
    var done = false;
    while (!done) : (if (idx == 0) {
        done = true;
    } else {
        idx -= 1;
    }) {
        const token = theme_.tokens[idx];
        const theme_scope = Widget.scopes[token.id];
        const last_matched_scope = if (matched) |tok| Widget.scopes[tok.id] else "";
        if (theme_scope.len < last_matched_scope.len) continue;
        if (theme_scope.len < document_scope.len and document_scope[theme_scope.len] != '.') continue;
        if (theme_scope.len > document_scope.len) continue;
        const prefix = @min(theme_scope.len, document_scope.len);
        if (std.mem.eql(u8, theme_scope[0..prefix], document_scope[0..prefix]))
            matched = token;
    }
    return matched;
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
    .{ .ts = "type.builtin", .tm = "keyword.type" },
    .{ .ts = "type.defaultLibrary", .tm = "support.type" },
    .{ .ts = "type", .tm = "entity.name.type" },
    .{ .ts = "struct", .tm = "storage.type.struct" },
    .{ .ts = "class.defaultLibrary", .tm = "support.class" },
    .{ .ts = "class", .tm = "entity.name.type.class" },
    .{ .ts = "interface", .tm = "entity.name.type.interface" },
    .{ .ts = "enum", .tm = "entity.name.type.enum" },
    .{ .ts = "enumMember", .tm = "variable.other.enummember" },
    .{ .ts = "constant", .tm = "entity.name.constant" },
    .{ .ts = "function.defaultLibrary", .tm = "support.function" },
    .{ .ts = "function.builtin", .tm = "entity.name.function" },
    .{ .ts = "function.call", .tm = "entity.name.function.function-call" },
    .{ .ts = "function", .tm = "entity.name.function" },
    .{ .ts = "method", .tm = "entity.name.function.member" },
    .{ .ts = "macro", .tm = "entity.name.function.macro" },
    .{ .ts = "variable.readonly.defaultLibrary", .tm = "support.constant" },
    .{ .ts = "variable.readonly", .tm = "variable.other.constant" },
    .{ .ts = "variable.member", .tm = "property" },
    // .{ .ts = "variable.parameter", .tm = "variable" },
    // .{ .ts = "variable", .tm = "entity.name.variable" },
    .{ .ts = "label", .tm = "entity.name.label" },
    .{ .ts = "parameter", .tm = "variable.parameter" },
    .{ .ts = "property.readonly", .tm = "variable.other.constant.property" },
    .{ .ts = "property", .tm = "variable.other.property" },
    .{ .ts = "event", .tm = "variable.other.event" },
    .{ .ts = "attribute", .tm = "keyword" },
    .{ .ts = "number", .tm = "constant.numeric" },
    .{ .ts = "operator", .tm = "keyword.operator" },
    .{ .ts = "boolean", .tm = "keyword.constant.bool" },
    .{ .ts = "string", .tm = "string.quoted.double" },
    .{ .ts = "character", .tm = "string.quoted.single" },
    .{ .ts = "field", .tm = "variable" },
    .{ .ts = "repeat", .tm = "keyword.control.repeat" },
    .{ .ts = "keyword.conditional", .tm = "keyword.control.conditional" },
    .{ .ts = "keyword.repeat", .tm = "keyword.control.repeat" },
    .{ .ts = "keyword.modifier", .tm = "keyword.storage" },
    .{ .ts = "keyword.type", .tm = "keyword.structure" },
    .{ .ts = "keyword.function", .tm = "storage.type.function" },
    .{ .ts = "constant.builtin", .tm = "keyword.constant" },
};

fn set_terminal_style(self: *Self) void {
    if (build_options.gui or self.config.enable_terminal_color_scheme) {
        self.rdr.set_terminal_style(self.theme.editor);
        self.rdr.set_terminal_cursor_color(self.theme.editor_cursor.bg.?);
    }
}

pub fn get_cursor_shape() renderer.CursorShape {
    const self = current();
    const shape = if (self.input_mode) |mode| mode.cursor_shape orelse self.default_cursor else self.default_cursor;
    return switch (shape) {
        .default => .default,
        .block_blink => .block_blink,
        .block => .block,
        .underline_blink => .underline_blink,
        .underline => .underline,
        .beam_blink => .beam_blink,
        .beam => .beam,
    };
}

pub fn is_cursor_beam() bool {
    return switch (get_cursor_shape()) {
        .beam, .beam_blink => true,
        else => false,
    };
}

pub fn get_selection_style() @import("Buffer").Selection.Style {
    return if (current().input_mode) |mode| mode.selection_style else .normal;
}

pub fn message(comptime fmt: anytype, args: anytype) void {
    var buf: [256]u8 = undefined;
    tp.self_pid().send(.{ "message", std.fmt.bufPrint(&buf, fmt, args) catch @panic("too large") }) catch {};
}

pub fn render_file_icon(self: *renderer.Plane, icon: []const u8, color: u24) void {
    var cell = self.cell_init();
    _ = self.at_cursor_cell(&cell) catch return;
    if (!(color == 0xFFFFFF or color == 0x000000 or color == 0x000001)) {
        cell.set_fg_rgb(@intCast(color)) catch {};
    }
    _ = self.cell_load(&cell, icon) catch {};
    _ = self.putc(&cell) catch {};
    self.cursor_move_rel(0, 1) catch {};
}

pub fn render_match_cell(self: *renderer.Plane, y: usize, x: usize, theme_: *const Widget.Theme) !void {
    self.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
    var cell = self.cell_init();
    _ = self.at_cursor_cell(&cell) catch return;
    cell.set_style(theme_.editor_match);
    _ = self.putc(&cell) catch {};
}
