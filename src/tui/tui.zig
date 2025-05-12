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
const syntax = @import("syntax");

const Widget = @import("Widget.zig");
const MessageFilter = @import("MessageFilter.zig");
const MainView = @import("mainview.zig");

const Allocator = std.mem.Allocator;

pub const GlobalMarkLocation = struct {
    row: usize,
    col: usize,
    filepath: [512]u8 = .{0} ** 512,
};

allocator: Allocator,
rdr_: renderer,
config_: @import("config"),
highlight_columns_: []u16,
highlight_columns_configured: []u16,
frame_time: usize, // in microseconds
frame_clock: tp.metronome,
frame_clock_running: bool = false,
frame_last_time: i64 = 0,
receiver: Receiver,
mainview_: ?Widget = null,
message_filters_: MessageFilter.List,
input_mode_: ?Mode = null,
delayed_init_done: bool = false,
delayed_init_input_mode: ?Mode = null,
input_mode_outer_: ?Mode = null,
input_listeners_: EventHandler.List,
keyboard_focus: ?Widget = null,
mini_mode_: ?MiniMode = null,
hover_focus: ?*Widget = null,
last_hover_x: c_int = -1,
last_hover_y: c_int = -1,
commands: Commands = undefined,
logger: log.Logger,
drag_source: ?*Widget = null,
theme_: Widget.Theme,
parsed_theme: ?std.json.Parsed(Widget.Theme),
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
fontface_: []const u8 = "",
fontfaces_: std.ArrayListUnmanaged([]const u8) = .{},
enable_mouse_idle_timer: bool = false,
query_cache_: *syntax.QueryCache,
frames_rendered_: usize = 0,
global_marks: [256]?GlobalMarkLocation = .{null} ** 256,

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

const InitError = error{
    OutOfMemory,
    UnknownTheme,
    ThespianMetronomeInitFailed,
    ThespianMetronomeStartFailed,
    ThespianTimeoutInitFailed,
    ThespianSignalInitFailed,
    ThespianSpawnFailed,
} || renderer.Error ||
    root.ConfigDirError ||
    root.ConfigWriteError ||
    keybind.LoadError;

fn init(allocator: Allocator) InitError!*Self {
    var conf, const conf_bufs = root.read_config(@import("config"), allocator);
    defer root.free_config(allocator, conf_bufs);

    if (conf.start_debugger_on_crash)
        tp.install_debugger();

    const theme_, const parsed_theme = get_theme_by_name(allocator, conf.theme) orelse get_theme_by_name(allocator, "dark_modern") orelse return error.UnknownTheme;
    conf.theme = theme_.name;
    conf.whitespace_mode = try allocator.dupe(u8, conf.whitespace_mode);
    conf.input_mode = try allocator.dupe(u8, conf.input_mode);
    conf.top_bar = try allocator.dupe(u8, conf.top_bar);
    conf.bottom_bar = try allocator.dupe(u8, conf.bottom_bar);
    conf.include_files = try allocator.dupe(u8, conf.include_files);
    conf.highlight_columns = try allocator.dupe(u8, conf.highlight_columns);
    if (build_options.gui) conf.enable_terminal_cursor = false;

    const frame_rate: usize = @intCast(tp.env.get().num("frame-rate"));
    if (frame_rate != 0)
        conf.frame_rate = frame_rate;
    tp.env.get().num_set("frame-rate", @intCast(conf.frame_rate));
    const frame_time = std.time.us_per_s / conf.frame_rate;
    const frame_clock = try tp.metronome.init(frame_time);

    const hl_cols: usize = blk: {
        var it = std.mem.splitScalar(u8, conf.highlight_columns, ' ');
        var idx: usize = 0;
        while (it.next()) |_|
            idx += 1;
        break :blk idx;
    };
    const highlight_columns__ = try allocator.alloc(u16, hl_cols);

    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .config_ = conf,
        .highlight_columns_ = highlight_columns__,
        .highlight_columns_configured = highlight_columns__,
        .rdr_ = try renderer.init(allocator, self, tp.env.get().is("no-alternate"), dispatch_initialized),
        .frame_time = frame_time,
        .frame_clock = frame_clock,
        .frame_clock_running = true,
        .receiver = Receiver.init(receive, self),
        .message_filters_ = MessageFilter.List.init(allocator),
        .input_listeners_ = EventHandler.List.init(allocator),
        .logger = log.logger("tui"),
        .init_timer = if (build_options.gui) null else try tp.timeout.init_ms(init_delay, tp.message.fmt(
            .{"init"},
        )),
        .theme_ = theme_,
        .no_sleep = tp.env.get().is("no-sleep"),
        .query_cache_ = try syntax.QueryCache.create(allocator, .{}),
        .parsed_theme = parsed_theme,
    };
    instance_ = self;
    defer instance_ = null;

    var it = std.mem.splitScalar(u8, conf.highlight_columns, ' ');
    var idx: usize = 0;
    while (it.next()) |arg| {
        self.highlight_columns_[idx] = std.fmt.parseInt(u16, arg, 10) catch 0;
        idx += 1;
    }

    self.default_cursor = std.meta.stringToEnum(keybind.CursorShape, conf.default_cursor) orelse .default;
    self.config_.default_cursor = @tagName(self.default_cursor);
    self.rdr_.handler_ctx = self;
    self.rdr_.dispatch_input = dispatch_input;
    self.rdr_.dispatch_mouse = dispatch_mouse;
    self.rdr_.dispatch_mouse_drag = dispatch_mouse_drag;
    self.rdr_.dispatch_event = dispatch_event;
    try self.rdr_.run();

    try project_manager.start();

    try frame_clock.start();
    try self.commands.init(self);
    try keybind.init();
    errdefer self.deinit();
    switch (builtin.os.tag) {
        .windows => {
            self.keepalive_timer = try tp.self_pid().delay_send_cancellable(allocator, "tui.keepalive", keepalive, .{"keepalive"});
        },
        else => {
            try self.listen_sigwinch();
        },
    }
    self.mainview_ = try MainView.create(allocator);
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

fn init_input_namespace(self: *Self) InitError!void {
    var mode_parts = std.mem.splitScalar(u8, self.config_.input_mode, '/');
    const namespace_name = mode_parts.first();
    keybind.set_namespace(namespace_name) catch {
        self.logger.print_err("keybind", "unknown mode {s}", .{namespace_name});
        try keybind.set_namespace("flow");
        self.config_.input_mode = "flow";
        try save_config();
    };
}

fn init_delayed(self: *Self) command.Result {
    self.delayed_init_done = true;
    if (self.input_mode_) |_| {} else {
        if (self.delayed_init_input_mode) |delayed_init_input_mode| {
            try enter_input_mode(self, delayed_init_input_mode);
            self.delayed_init_input_mode = null;
        } else {
            try cmds.enter_mode(self, command.Context.fmt(.{keybind.default_mode}));
        }
    }
}

fn deinit(self: *Self) void {
    self.allocator.free(self.highlight_columns_configured);
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
    if (self.input_mode_) |*m| {
        m.deinit();
        self.input_mode_ = null;
    }
    if (self.delayed_init_input_mode) |*m| {
        m.deinit();
        self.delayed_init_input_mode = null;
    }
    self.commands.deinit();
    if (self.mainview_) |*mv| mv.deinit(self.allocator);
    self.message_filters_.deinit();
    self.input_listeners_.deinit();
    if (self.frame_clock_running)
        self.frame_clock.stop() catch {};
    if (self.sigwinch_signal) |sig| sig.deinit();
    self.frame_clock.deinit();
    self.rdr_.stop();
    self.rdr_.deinit();
    self.logger.deinit();
    self.query_cache_.deinit();
    self.allocator.destroy(self);
}

fn listen_sigwinch(self: *Self) error{ThespianSignalInitFailed}!void {
    if (self.sigwinch_signal) |old| old.deinit();
    self.sigwinch_signal = try tp.signal.init(std.posix.SIG.WINCH, tp.message.fmt(.{"sigwinch"}));
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
        self.rdr_.process_renderer_event(m.buf) catch |e| switch (e) {
            error.UnexpectedRendererEvent => return tp.unexpected(m),
            else => return e,
        };
        try self.dispatch_flush_input_event();
        if (self.unrendered_input_events_count > 0 and !self.frame_clock_running)
            need_render();
        return;
    }

    if (self.message_filters_.filter(from, m) catch |e| return self.logger.err("filter", e))
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
            self.rdr_.sigwinch() catch |e| return self.logger.err("query_resize", e);
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
        if (self.fontface_.len > 0) self.allocator.free(self.fontface_);
        self.fontface_ = "";
        self.fontface_ = try self.allocator.dupe(u8, fontface_);
        return;
    }

    if (try m.match(.{ "fontface", tp.extract(&fontface_) })) {
        try self.fontfaces_.append(self.allocator, try self.allocator.dupe(u8, fontface_));
        return;
    }

    return tp.unexpected(m);
}

fn render(self: *Self) void {
    defer self.frames_rendered_ += 1;
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
        if (self.mainview_) |mv| mv.update();
    }

    const more = ret: {
        const frame = tracy.initZone(@src(), .{ .name = "tui render" });
        defer frame.deinit();
        self.rdr_.stdplane().erase();
        break :ret if (self.mainview_) |mv| mv.render(&self.theme_) else false;
    };

    {
        const frame = tracy.initZone(@src(), .{ .name = renderer.log_name ++ " render" });
        defer frame.deinit();
        self.rdr_.render() catch |e| self.logger.err("render", e);
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
    const mode = self.input_mode_ orelse return null;
    return mode.event_handler orelse mode.input_handler;
}

fn dispatch_flush_input_event(self: *Self) error{ Exit, NoSpaceLeft }!void {
    var buf: [32]u8 = undefined;
    const mode = self.input_mode_ orelse return;
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
    self.input_listeners_.send(from, m) catch {};
    if (self.keyboard_focus) |w|
        if (w.send(from, m) catch |e| ret: {
            self.logger.err("focus", e);
            break :ret false;
        })
            return;
    if (self.input_mode_) |mode|
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
    if (self.mainview_) |*mv| _ = mv.walk(&ctx, Ctx.find);
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
    return if (self.mainview_) |*mv| mv.walk(&ctx, Ctx.find) else false;
}

fn send_widgets(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    const frame = tracy.initZone(@src(), .{ .name = "tui widgets" });
    defer frame.deinit();
    tp.trace(tp.channel.widget, m);
    return if (self.keyboard_focus) |w|
        w.send(from, m)
    else if (self.mainview_) |mv|
        mv.send(from, m)
    else
        false;
}

fn send_mouse(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) tp.result {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners_.send(from, m) catch {};
    if (self.keyboard_focus) |w| {
        _ = try w.send(from, m);
        return;
    }
    if (try self.update_hover(y, x)) |w|
        _ = try w.send(from, m);
}

fn send_mouse_drag(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) tp.result {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners_.send(from, m) catch {};
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

pub fn save_config() (root.ConfigDirError || root.ConfigWriteError)!void {
    const self = current();
    try root.write_config(self.config_, self.allocator);
}

pub fn is_mainview_focused() bool {
    const self = current();
    return self.mini_mode_ == null and self.input_mode_outer_ == null;
}

fn enter_overlay_mode(self: *Self, mode: type) command.Result {
    command.executeName("disable_fast_scroll", .{}) catch {};
    command.executeName("disable_jump_mode", .{}) catch {};
    if (self.mini_mode_) |_| try cmds.exit_mini_mode(self, .{});
    if (self.input_mode_outer_) |_| try cmds.exit_overlay_mode(self, .{});
    self.input_mode_outer_ = self.input_mode_;
    self.input_mode_ = try mode.create(self.allocator);
    if (self.input_mode_) |*m| m.run_init();
    refresh_hover();
}

fn get_input_mode(self: *Self, mode_name: []const u8) !Mode {
    return keybind.mode(mode_name, self.allocator, .{});
}

fn enter_input_mode(self: *Self, new_mode: Mode) command.Result {
    if (self.mini_mode_) |_| try cmds.exit_mini_mode(self, .{});
    if (self.input_mode_outer_) |_| try cmds.exit_overlay_mode(self, .{});
    if (self.input_mode_) |*m| {
        m.deinit();
        self.input_mode_ = null;
    }
    self.input_mode_ = new_mode;
    if (self.input_mode_) |*m| m.run_init();
}

fn refresh_input_mode(self: *Self) command.Result {
    const mode = (self.input_mode_ orelse return).mode;
    var new_mode = self.get_input_mode(mode) catch ret: {
        self.logger.print("unknown mode {s}", .{mode});
        break :ret try self.get_input_mode(keybind.default_mode);
    };
    errdefer new_mode.deinit();
    if (self.input_mode_) |*m| {
        m.deinit();
        self.input_mode_ = null;
    }
    self.input_mode_ = new_mode;
    if (self.input_mode_) |*m| m.run_init();
}

fn set_theme_by_name(self: *Self, name: []const u8) !void {
    const old = self.parsed_theme;
    defer if (old) |p| p.deinit();
    self.theme_, self.parsed_theme = get_theme_by_name(self.allocator, name) orelse {
        self.logger.print("theme not found: {s}", .{name});
        return;
    };
    self.config_.theme = self.theme_.name;
    self.set_terminal_style();
    self.logger.print("theme: {s}", .{self.theme_.description});
    try save_config();
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn restart(_: *Self, _: Ctx) Result {
        try tp.self_pid().send("restart");
    }
    pub const restart_meta: Meta = .{ .description = "Restart (without saving)" };

    pub fn force_terminate(self: *Self, _: Ctx) Result {
        self.deinit();
        root.print_exit_status({}, "FORCE TERMINATE");
        root.exit(99);
    }
    pub const force_terminate_meta: Meta = .{ .description = "Force quit without saving" };

    pub fn set_theme(self: *Self, ctx: Ctx) Result {
        var name: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&name)}))
            return tp.exit_error(error.InvalidSetThemeArgument, null);
        return self.set_theme_by_name(name);
    }
    pub const set_theme_meta: Meta = .{ .arguments = &.{.string} };

    pub fn theme_next(self: *Self, _: Ctx) Result {
        const name = get_next_theme_by_name(self.theme_.name);
        return self.set_theme_by_name(name);
    }
    pub const theme_next_meta: Meta = .{ .description = "Next color theme" };

    pub fn theme_prev(self: *Self, _: Ctx) Result {
        const name = get_prev_theme_by_name(self.theme_.name);
        return self.set_theme_by_name(name);
    }
    pub const theme_prev_meta: Meta = .{ .description = "Previous color theme" };

    pub fn toggle_whitespace_mode(self: *Self, _: Ctx) Result {
        self.config_.whitespace_mode = if (std.mem.eql(u8, self.config_.whitespace_mode, "none"))
            "indent"
        else if (std.mem.eql(u8, self.config_.whitespace_mode, "indent"))
            "leading"
        else if (std.mem.eql(u8, self.config_.whitespace_mode, "leading"))
            "eol"
        else if (std.mem.eql(u8, self.config_.whitespace_mode, "eol"))
            "tabs"
        else if (std.mem.eql(u8, self.config_.whitespace_mode, "tabs"))
            "visible"
        else if (std.mem.eql(u8, self.config_.whitespace_mode, "visible"))
            "full"
        else
            "none";
        try save_config();
        var buf: [32]u8 = undefined;
        const m = try tp.message.fmtbuf(&buf, .{ "whitespace_mode", self.config_.whitespace_mode });
        _ = try self.send_widgets(tp.self_pid(), m);
        self.logger.print("whitespace rendering {s}", .{self.config_.whitespace_mode});
    }
    pub const toggle_whitespace_mode_meta: Meta = .{ .description = "Next whitespace mode" };

    pub fn toggle_highlight_columns(self: *Self, _: Ctx) Result {
        defer self.logger.print("highlight columns {s}", .{if (self.highlight_columns_.len > 0) "enabled" else "disabled"});
        self.highlight_columns_ = if (self.highlight_columns_.len > 0) &.{} else self.highlight_columns_configured;
    }
    pub const toggle_highlight_columns_meta: Meta = .{ .description = "Toggle highlight columns" };

    pub fn toggle_input_mode(self: *Self, _: Ctx) Result {
        var it = std.mem.splitScalar(u8, self.config_.input_mode, '/');
        self.config_.input_mode = it.first();

        const namespaces = keybind.get_namespaces(self.allocator) catch |e| return tp.exit_error(e, @errorReturnTrace());
        defer {
            for (namespaces) |namespace| self.allocator.free(namespace);
            self.allocator.free(namespaces);
        }
        var found = false;
        self.config_.input_mode = blk: for (namespaces) |namespace| {
            if (found) break :blk try self.allocator.dupe(u8, namespace);
            if (std.mem.eql(u8, namespace, self.config_.input_mode))
                found = true;
        } else try self.allocator.dupe(u8, namespaces[0]);

        try save_config();
        self.logger.print("input mode {s}", .{self.config_.input_mode});
        try keybind.set_namespace(self.config_.input_mode);
        return self.refresh_input_mode();
    }
    pub const toggle_input_mode_meta: Meta = .{ .description = "Switch input mode" };

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
    pub const enter_mode_meta: Meta = .{ .arguments = &.{.string} };

    pub fn enter_mode_default(self: *Self, _: Ctx) Result {
        return enter_mode(self, Ctx.fmt(.{keybind.default_mode}));
    }
    pub const enter_mode_default_meta: Meta = .{};

    pub fn open_command_palette(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/command_palette.zig").Type);
    }
    pub const open_command_palette_meta: Meta = .{ .description = "Command palette" };

    pub fn insert_command_name(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/list_all_commands_palette.zig").Type);
    }
    pub const insert_command_name_meta: Meta = .{ .description = "Show active keybindings" };

    pub fn find_file(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent.zig"));
    }
    pub const find_file_meta: Meta = .{ .description = "Find file" };

    pub fn open_recent(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent.zig"));
    }
    pub const open_recent_meta: Meta = .{ .description = "Open recent" };

    pub fn open_recent_project(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/open_recent_project.zig").Type);
    }
    pub const open_recent_project_meta: Meta = .{ .description = "Open project" };

    pub fn switch_buffers(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/buffer_palette.zig").Type);
    }
    pub const switch_buffers_meta: Meta = .{ .description = "Switch buffers" };

    pub fn select_task(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/task_palette.zig").Type);
    }
    pub const select_task_meta: Meta = .{ .description = "Run task" };

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
    pub const add_task_meta: Meta = .{ .description = "Add task" };

    pub fn delete_task(_: *Self, ctx: Ctx) Result {
        var task: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&task)}))
            return error.InvalidDeleteTaskArgument;
        project_manager.delete_task(task) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const delete_task_meta: Meta = .{};

    pub fn change_theme(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/theme_palette.zig").Type);
    }
    pub const change_theme_meta: Meta = .{ .description = "Change color theme" };

    pub fn change_file_type(self: *Self, _: Ctx) Result {
        return self.enter_overlay_mode(@import("mode/overlay/file_type_palette.zig").Type);
    }
    pub const change_file_type_meta: Meta = .{ .description = "Change file type" };

    pub fn change_fontface(self: *Self, _: Ctx) Result {
        if (build_options.gui)
            self.rdr_.get_fontfaces();
    }
    pub const change_fontface_meta: Meta = .{ .description = "Change font" };

    pub fn exit_overlay_mode(self: *Self, _: Ctx) Result {
        self.rdr_.cursor_disable();
        if (self.input_mode_outer_ == null) return enter_mode_default(self, .{});
        if (self.input_mode_) |*mode| mode.deinit();
        self.input_mode_ = self.input_mode_outer_;
        self.input_mode_outer_ = null;
        refresh_hover();
    }
    pub const exit_overlay_mode_meta: Meta = .{};

    pub fn find(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/find.zig"), ctx);
    }
    pub const find_meta: Meta = .{ .description = "Find" };

    pub fn find_in_files(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/find_in_files.zig"), ctx);
    }
    pub const find_in_files_meta: Meta = .{ .description = "Find in files" };

    pub fn goto(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/goto.zig"), ctx);
    }
    pub const goto_meta: Meta = .{ .description = "Goto line" };

    pub fn move_to_char(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/move_to_char.zig"), ctx);
    }
    pub const move_to_char_meta: Meta = .{ .description = "Move to character" };

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
    pub const open_file_meta: Meta = .{ .description = "Open file" };

    pub fn save_as(self: *Self, ctx: Ctx) Result {
        return enter_mini_mode(self, @import("mode/mini/save_as.zig"), ctx);
    }
    pub const save_as_meta: Meta = .{ .description = "Save as" };

    fn enter_mini_mode(self: *Self, comptime mode: anytype, ctx: Ctx) !void {
        command.executeName("disable_fast_scroll", .{}) catch {};
        command.executeName("disable_jump_mode", .{}) catch {};
        const input_mode_, const mini_mode_ = try mode.create(self.allocator, ctx);
        if (self.mini_mode_) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer_) |_| try exit_overlay_mode(self, .{});
        if (self.input_mode_outer_ != null) @panic("exit_overlay_mode failed");
        self.input_mode_outer_ = self.input_mode_;
        self.input_mode_ = input_mode_;
        self.mini_mode_ = mini_mode_;
        if (self.input_mode_) |*m| m.run_init();
    }

    pub fn exit_mini_mode(self: *Self, _: Ctx) Result {
        self.rdr_.cursor_disable();
        if (self.mini_mode_) |_| {} else return;
        if (self.input_mode_) |*mode| mode.deinit();
        self.input_mode_ = self.input_mode_outer_;
        self.input_mode_outer_ = null;
        self.mini_mode_ = null;
    }
    pub const exit_mini_mode_meta: Meta = .{};

    pub fn open_keybind_config(self: *Self, _: Ctx) Result {
        var mode_parts = std.mem.splitScalar(u8, self.config_.input_mode, '/');
        const namespace_name = mode_parts.first();
        const file_name = try keybind.get_or_create_namespace_config_file(self.allocator, namespace_name);
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
        self.logger.print("restart flow to use changed key bindings", .{});
    }
    pub const open_keybind_config_meta: Meta = .{ .description = "Edit key bindings" };

    pub fn open_custom_theme(self: *Self, _: Ctx) Result {
        const file_name = try self.get_or_create_theme_file(self.allocator);
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
        self.logger.print("restart flow to use changed theme", .{});
    }
    pub const open_custom_theme_meta: Meta = .{ .description = "Customize theme" };

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
    pub const run_async_meta: Meta = .{};

    pub fn enter_vim_mode(_: *Self, _: Ctx) Result {
        try @import("mode/vim.zig").init();
    }
    pub const enter_vim_mode_meta: Meta = .{};

    pub fn exit_vim_mode(_: *Self, _: Ctx) Result {
        @import("mode/vim.zig").deinit();
    }
    pub const exit_vim_mode_meta: Meta = .{};

    pub fn enter_helix_mode(_: *Self, _: Ctx) Result {
        try @import("mode/helix.zig").init();
    }
    pub const enter_helix_mode_meta: Meta = .{};

    pub fn exit_helix_mode(_: *Self, _: Ctx) Result {
        @import("mode/helix.zig").deinit();
    }
    pub const exit_helix_mode_meta: Meta = .{};
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

pub fn get_global_marks() *[256]?GlobalMarkLocation {
    return &current().global_marks;
}

pub fn rdr() *renderer {
    return &current().rdr_;
}

pub fn message_filters() *MessageFilter.List {
    return &current().message_filters_;
}

pub fn input_listeners() *EventHandler.List {
    return &current().input_listeners_;
}

pub fn input_mode() ?*Mode {
    return if (current().input_mode_) |*p| p else null;
}

pub fn input_mode_outer() ?*Mode {
    return if (current().input_mode_outer_) |*p| p else null;
}

pub fn mini_mode() ?*MiniMode {
    return if (current().mini_mode_) |*p| p else null;
}

pub fn query_cache() *syntax.QueryCache {
    return current().query_cache_;
}

pub fn config() *const @import("config") {
    return &current().config_;
}

pub fn highlight_columns() []const u16 {
    return current().highlight_columns_;
}

pub fn config_mut() *@import("config") {
    return &current().config_;
}

pub fn mainview() ?*MainView {
    return if (current().mainview_) |*mv| mv.dynamic_cast(MainView) else null;
}

pub fn mainview_widget() Widget {
    return current().mainview_ orelse @panic("tui main view not found");
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
    return if (current().mini_mode_) |m|
        m.name
    else if (current().input_mode_) |m|
        m.name
    else
        "INI";
}

pub fn get_keybind_mode() ?Mode {
    const self = current();
    return self.input_mode_ orelse self.delayed_init_input_mode;
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

pub fn frames_rendered() usize {
    const self = current();
    return self.frames_rendered_;
}

pub fn resize() void {
    mainview_widget().resize(screen());
    refresh_hover();
    need_render();
}

pub fn plane() renderer.Plane {
    return current().rdr_.stdplane();
}

fn stdplane(self: *Self) renderer.Plane {
    return self.rdr_.stdplane();
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
    return current().fontface_;
}

pub fn fontfaces(allocator: std.mem.Allocator) error{OutOfMemory}![][]const u8 {
    return current().fontfaces_.toOwnedSlice(allocator);
}

pub fn theme() *const Widget.Theme {
    return &current().theme_;
}

pub fn get_theme_by_name(allocator: std.mem.Allocator, name: []const u8) ?struct { Widget.Theme, ?std.json.Parsed(Widget.Theme) } {
    if (load_theme_file(allocator, name) catch null) |parsed_theme| {
        std.log.info("loaded theme from file: {s}", .{name});
        return .{ parsed_theme.value, parsed_theme };
    }

    for (Widget.themes) |theme_| {
        if (std.mem.eql(u8, theme_.name, name))
            return .{ theme_, null };
    }
    return null;
}

fn get_next_theme_by_name(name: []const u8) []const u8 {
    var next = false;
    for (Widget.themes) |theme_| {
        if (next)
            return theme_.name;
        if (std.mem.eql(u8, theme_.name, name))
            next = true;
    }
    return Widget.themes[0].name;
}

fn get_prev_theme_by_name(name: []const u8) []const u8 {
    var prev: ?Widget.Theme = null;
    for (Widget.themes) |theme_| {
        if (std.mem.eql(u8, theme_.name, name))
            return (prev orelse Widget.themes[Widget.themes.len - 1]).name;
        prev = theme_;
    }
    return Widget.themes[Widget.themes.len - 1].name;
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
    if (build_options.gui or self.config_.enable_terminal_color_scheme) {
        self.rdr_.set_terminal_style(self.theme_.editor);
        self.rdr_.set_terminal_cursor_color(self.theme_.editor_cursor.bg.?);
    }
}

pub fn get_cursor_shape() renderer.CursorShape {
    const self = current();
    const shape = if (self.input_mode_) |mode| mode.cursor_shape orelse self.default_cursor else self.default_cursor;
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
    return if (current().input_mode_) |mode| mode.selection_style else .normal;
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

fn get_or_create_theme_file(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
    const theme_name = self.theme_.name;
    if (root.read_theme(allocator, theme_name)) |content| {
        allocator.free(content);
    } else {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try std.json.stringify(self.theme_, .{ .whitespace = .indent_2 }, buf.writer());
        try root.write_theme(
            theme_name,
            buf.items,
        );
    }
    return try root.get_theme_file_name(theme_name);
}

fn load_theme_file(allocator: std.mem.Allocator, theme_name: []const u8) !?std.json.Parsed(Widget.Theme) {
    return load_theme_file_internal(allocator, theme_name) catch |e| {
        std.log.err("loaded theme from file failed: {}", .{e});
        return e;
    };
}
fn load_theme_file_internal(allocator: std.mem.Allocator, theme_name: []const u8) !?std.json.Parsed(Widget.Theme) {
    _ = std.json.Scanner;
    const json_str = root.read_theme(allocator, theme_name) orelse return null;
    defer allocator.free(json_str);
    return try std.json.parseFromSlice(Widget.Theme, allocator, json_str, .{ .allocate = .alloc_always });
}
