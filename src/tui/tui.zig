const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const config = @import("config");
const project_manager = @import("project_manager");
const build_options = @import("build_options");
const root = @import("root");
const tracy = @import("tracy");
const builtin = @import("builtin");

pub const renderer = @import("renderer");

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
mini_mode: ?MiniModeState = null,
hover_focus: ?*Widget = null,
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

const idle_frames = 0;

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
    tp.receive(&self.receiver);
}

fn init(a: Allocator) !*Self {
    var self = try a.create(Self);
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

    self.* = .{
        .a = a,
        .config = conf,
        .rdr = try renderer.init(a, self, tp.env.get().is("no-alternate")),
        .frame_time = frame_time,
        .frame_clock = frame_clock,
        .frame_clock_running = true,
        .receiver = Receiver.init(receive, self),
        .mainview = undefined,
        .message_filters = MessageFilter.List.init(a),
        .input_mode = null,
        .input_listeners = EventHandler.List.init(a),
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
    const n = self.rdr.stdplane();

    try frame_clock.start();
    try self.commands.init(self);
    errdefer self.deinit();
    if (builtin.os.tag != .windows)
        try self.listen_sigwinch();
    self.mainview = try mainview.create(a, n);
    self.resize();
    try self.rdr.render();
    try self.save_config();
    if (tp.env.get().is("restore-session")) {
        command.executeName("restore_session", .{}) catch |e| self.logger.err("restore_session", e);
        self.logger.print("session restored", .{});
    }
    need_render();
    return self;
}

fn init_delayed(self: *Self) tp.result {
    if (self.input_mode) |_| {} else return cmds.enter_mode(self, command.Context.fmt(.{self.config.input_mode}));
}

fn deinit(self: *Self) void {
    if (self.input_mode) |*m| m.deinit();
    self.commands.deinit();
    self.mainview.deinit(self.a);
    self.message_filters.deinit();
    self.input_listeners.deinit();
    if (self.frame_clock_running)
        self.frame_clock.stop() catch {};
    if (self.sigwinch_signal) |sig| sig.deinit();
    self.frame_clock.deinit();
    self.rdr.stop();
    self.rdr.deinit();
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

    self.receive_safe(from, m) catch |e| {
        if (std.mem.eql(u8, "normal", tp.error_text()))
            return e;
        if (std.mem.eql(u8, "restart", tp.error_text()))
            return e;
        self.logger.err("UI", e);
    };
}

fn receive_safe(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
    var input: []const u8 = undefined;
    var text: []const u8 = undefined;
    if (try m.match(.{ "VXS", tp.extract(&input), tp.extract(&text) })) {
        self.rdr.process_input_event(input, if (text.len > 0) text else null) catch |e| return tp.exit_error(e);
        try self.dispatch_flush_input_event();
        if (self.unrendered_input_events_count > 0 and !self.frame_clock_running)
            need_render();
        return;
    }

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
            self.rdr.query_resize() catch |e| return self.logger.err("query_resize", e);
            return;
        };

    if (try m.match(.{"resize"})) {
        self.resize();
        return;
    }

    if (try m.match(.{ "system_clipboard", tp.string })) {
        if (self.input_mode) |mode|
            mode.handler.send(tp.self_pid(), m) catch |e| self.logger.err("clipboard handler", e);
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

    if (try m.match(.{ "exit", "normal" }))
        return;

    if (try m.match(.{ "exit", "timeout_error", 125, "Operation aborted." }))
        return;

    if (try m.match(.{ "exit", "DEADSEND", tp.more }))
        return;

    var msg: []const u8 = undefined;
    if (try m.match(.{ "exit", tp.extract(&msg) }) or try m.match(.{ "exit", tp.extract(&msg), tp.more })) {
        self.logger.err_msg("tui", msg);
        return;
    }

    if (try m.match(.{ "PRJ", tp.more })) // drop late project manager query responses
        return;

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

fn dispatch_flush_input_event(self: *Self) tp.result {
    var buf: [32]u8 = undefined;
    if (self.input_mode) |mode|
        try mode.handler.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{"F"}) catch |e| return tp.exit_error(e));
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
        mode.handler.send(from, m) catch |e| self.logger.err("input handler", e);
}

fn dispatch_mouse(ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const m: tp.message = .{ .buf = cbor_msg };
    const from = tp.self_pid();
    self.unrendered_input_events_count += 1;
    if (self.drag_source) |_|
        self.send_mouse_drag(y, x, from, m) catch |e| self.logger.err("dispatch mouse", e)
    else
        self.send_mouse(y, x, from, m) catch |e| self.logger.err("dispatch mouse", e);
    self.drag_source = null;
}

fn dispatch_mouse_drag(ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
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

fn send_mouse_drag(self: *Self, y: c_int, x: c_int, from: tp.pid_ref, m: tp.message) tp.result {
    tp.trace(tp.channel.input, m);
    _ = self.input_listeners.send(from, m) catch {};
    if (self.keyboard_focus) |w| {
        _ = try w.send(from, m);
        return;
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
    } else {
        if (self.hover_focus) |h| {
            var buf: [256]u8 = undefined;
            _ = try h.send(tp.self_pid(), tp.message.fmtbuf(&buf, .{ "H", false }) catch |e| return tp.exit_error(e));
        }
        self.hover_focus = null;
    }
    if (self.drag_source) |w| _ = try w.send(from, m);
}

pub fn save_config(self: *const Self) !void {
    try root.write_config(self.config, self.a);
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;

    pub fn restart(_: *Self, _: Ctx) tp.result {
        try tp.self_pid().send("restart");
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
        if (self.mini_mode) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer) |_| try exit_overlay_mode(self, .{});
        if (self.input_mode) |*m| m.deinit();
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
        if (self.mini_mode) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer) |_| try exit_overlay_mode(self, .{});
        self.input_mode = if (std.mem.eql(u8, mode, "command_palette")) ret: {
            self.input_mode_outer = self.input_mode;
            break :ret @import("mode/overlay/command_palette.zig").create(self.a) catch |e| return tp.exit_error(e);
        } else if (std.mem.eql(u8, mode, "open_recent")) ret: {
            self.input_mode_outer = self.input_mode;
            break :ret @import("mode/overlay/open_recent.zig").create(self.a) catch |e| return tp.exit_error(e);
        } else {
            self.logger.print("unknown mode {s}", .{mode});
            return;
        };
        // self.logger.print("input mode: {s}", .{(self.input_mode orelse return).description});
    }

    pub fn exit_overlay_mode(self: *Self, _: Ctx) tp.result {
        if (self.input_mode_outer == null) return;
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
        if (self.mini_mode) |_| try exit_mini_mode(self, .{});
        if (self.input_mode_outer) |_| try exit_overlay_mode(self, .{});
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

pub fn get_mode() []const u8 {
    return if (current().input_mode) |m| m.name else "INI";
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
    self.mainview.resize(Widget.Box.from(self.rdr.stdplane()));
    need_render();
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
