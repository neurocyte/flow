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
const keybind = @import("keybind");
pub const Mode = keybind.Mode;

pub const name = @typeName(Self);

const Self = @This();
const widget_type: Widget.Type = .panel;

const Terminal = vaxis.widgets.Terminal;

allocator: Allocator,
plane: Plane,
focused: bool = false,
input_mode: Mode,
hover: bool = false,
vt: *Vt,
commands: Commands = undefined,

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    return create_with_args(allocator, parent, .{});
}

pub fn create_with_args(allocator: Allocator, parent: Plane, ctx: command.Context) !Widget {
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

    // Use the current plane dimensions for the initial pty size. The plane
    // starts at 0×0 before the first resize, so use a sensible fallback
    // so the pty isn't created with a zero-cell screen.
    const cols: u16 = @intCast(@max(80, plane.dim_x()));
    const rows: u16 = @intCast(@max(24, plane.dim_y()));

    if (global_vt == null) try Vt.init(allocator, argv_list.items, env, rows, cols);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .input_mode = try keybind.mode("terminal", allocator, .{ .insert_command = "do_nothing" }),
        .vt = &global_vt.?,
    };

    try self.commands.init(self);
    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));

    container.ctx = self;
    try container.add(Widget.to(self));

    return container.widget();
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "terminal_view", "output" })) {
        tui.need_render(@src());
        return true;
    } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
        tui.rdr().request_mouse_cursor_default(self.hover);
        tui.need_render(@src());
        return true;
    }
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.more }) or
        try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON2), tp.more }) or
        try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON3), tp.more }))
        switch (tui.set_focus_by_mouse_event()) {
            .changed => return true,
            .same, .notfound => {},
        };

    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON4), tp.more })) {
        if (self.vt.vt.scroll(3)) tui.need_render(@src());
        return true;
    }
    if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON5), tp.more })) {
        if (self.vt.vt.scroll(-3)) tui.need_render(@src());
        return true;
    }

    if (!(try m.match(.{ "I", tp.more })
        // or
        //     try m.match(.{ "B", tp.more }) or
        //     try m.match(.{ "D", tp.more }) or
        //     try m.match(.{ "M", tp.more })
    ))
        return false;

    if (!self.focused) return false;

    if (try self.input_mode.bindings.receive(from, m))
        return true;

    var event: input.Event = 0;
    var keypress: input.Key = 0;
    var keypress_shifted: input.Key = 0;
    var text: []const u8 = "";
    var modifiers: u8 = 0;

    if (!try m.match(.{ "I", tp.extract(&event), tp.extract(&keypress), tp.extract(&keypress_shifted), tp.extract(&text), tp.extract(&modifiers) }))
        return false;

    // Only forward press and repeat events; ignore releases.
    if (event != input.event.press and event != input.event.repeat) return true;
    const key: vaxis.Key = .{
        .codepoint = keypress,
        .shifted_codepoint = if (keypress_shifted != keypress) keypress_shifted else null,
        .mods = @bitCast(modifiers),
        .text = if (text.len > 0) text else null,
    };
    self.vt.vt.scrollToBottom();
    self.vt.vt.update(.{ .key_press = key }) catch |e|
        std.log.err("terminal_view: input failed: {}", .{e});
    tui.need_render(@src());
    return true;
}

pub fn toggle_focus(self: *Self) void {
    if (self.focused) self.unfocus() else self.focus();
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
    self.commands.unregister();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn shutdown(allocator: Allocator) void {
    if (global_vt) |*vt| {
        vt.deinit(allocator);
        global_vt = null;
    }
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    // Drain the vt event queue.
    while (self.vt.vt.tryEvent()) |event| {
        switch (event) {
            .exited => |code| {
                self.show_exit_message(code);
                tui.need_render(@src());
            },
            .redraw, .bell => {},
            .pwd_change => |path| {
                self.vt.cwd.clearRetainingCapacity();
                self.vt.cwd.appendSlice(self.allocator, path) catch {};
            },
            .title_change => |t| {
                self.vt.title.clearRetainingCapacity();
                self.vt.title.appendSlice(self.allocator, t) catch {};
            },
            .color_change => |cc| {
                self.vt.app_fg = cc.fg;
                self.vt.app_bg = cc.bg;
                self.vt.app_cursor = cc.cursor;
            },
            .osc_copy => |text| {
                // Terminal app wrote to clipboard via OSC 52.
                // Add to flow clipboard history and forward to system clipboard.
                const owned = tui.clipboard_allocator().dupe(u8, text) catch break;
                tui.clipboard_clear_all();
                tui.clipboard_start_group();
                tui.clipboard_add_chunk(owned);
                tui.clipboard_send_to_system() catch {};
            },
            .osc_paste_request => {
                // Terminal app requested clipboard contents via OSC 52.
                // Assemble from flow clipboard history and respond.
                if (tui.clipboard_get_history()) |history| {
                    var buf: std.Io.Writer.Allocating = .init(self.allocator);
                    defer buf.deinit();
                    var first = true;
                    for (history) |chunk| {
                        if (first) first = false else buf.writer.writeByte('\n') catch break;
                        buf.writer.writeAll(chunk.text) catch break;
                    }
                    self.vt.vt.respondOsc52Paste(buf.written());
                }
            },
        }
    }

    // Update the terminal's fg/bg color cache from the current theme so that
    // OSC 10/11 colour queries return accurate values.
    if (theme.editor.fg) |fg| {
        const c = fg.color;
        self.vt.vt.fg_color = .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) };
    }
    if (theme.editor.bg) |bg| {
        const c = bg.color;
        self.vt.vt.bg_color = .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) };
    }

    // Blit the terminal's front screen into our vaxis.Window.
    self.vt.vt.draw(self.allocator, self.plane.window, self.focused) catch |e| {
        std.log.err("terminal_view: draw failed: {}", .{e});
    };

    return false;
}

fn show_exit_message(self: *Self, code: u8) void {
    var msg: std.Io.Writer.Allocating = .init(self.allocator);
    defer msg.deinit();
    const w = &msg.writer;
    w.writeAll("\r\n") catch {};
    w.writeAll("\x1b[0m\x1b[2m") catch {};
    w.writeAll("[process exited") catch {};
    if (code != 0)
        w.print(" with code {d}", .{code}) catch {};
    w.writeAll("]\x1b[0m\r\n") catch {};
    var parser: pty.Parser = .{ .buf = .init(self.allocator) };
    defer parser.buf.deinit();
    _ = self.vt.vt.processOutput(&parser, msg.written()) catch {};
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.vt.resize(pos);
}

fn receive_filter(_: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (m.match(.{ "terminal_view", "output" }) catch false) {
        tui.need_render(@src());
        return true;
    }
    return false;
}

const Commands = command.Collection(cmds);

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn terminal_scroll_up(self: *Self, _: Ctx) Result {
        const half_page = @max(1, self.vt.vt.front_screen.height / 2);
        if (self.vt.vt.scroll(@intCast(half_page)))
            tui.need_render(@src());
    }
    pub const terminal_scroll_up_meta: Meta = .{ .description = "Terminal: Scroll up" };

    pub fn terminal_scroll_down(self: *Self, _: Ctx) Result {
        const half_page = @max(1, self.vt.vt.front_screen.height / 2);
        if (self.vt.vt.scroll(-@as(i32, @intCast(half_page))))
            tui.need_render(@src());
    }
    pub const terminal_scroll_down_meta: Meta = .{ .description = "Terminal: Scroll down" };
};

const Vt = struct {
    vt: Terminal,
    env: std.process.EnvMap,
    write_buf: [4096]u8,
    pty_pid: ?tp.pid = null,
    cwd: std.ArrayListUnmanaged(u8) = .empty,
    title: std.ArrayListUnmanaged(u8) = .empty,
    /// App-specified override colours (from OSC 10/11/12). null = use theme.
    app_fg: ?[3]u8 = null,
    app_bg: ?[3]u8 = null,
    app_cursor: ?[3]u8 = null,

    fn init(allocator: std.mem.Allocator, argv: []const []const u8, env: std.process.EnvMap, rows: u16, cols: u16) !void {
        const home = env.get("HOME") orelse "/tmp";

        global_vt = .{
            .vt = undefined,
            .env = env,
            .write_buf = undefined, // managed via self.vt's pty_writer pointer
            .pty_pid = null,
        };
        const self = &global_vt.?;
        self.vt = try Terminal.init(
            allocator,
            argv,
            &env,
            .{
                .winsize = .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 },
                .scrollback_size = tui.config().terminal_scrollback_size,
                .initial_working_directory = blk: {
                    const project = tp.env.get().str("project");
                    break :blk if (project.len > 0) project else home;
                },
            },
            &self.write_buf,
        );

        try self.vt.spawn();
        self.pty_pid = try pty.spawn(allocator, &self.vt);
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.cwd.deinit(allocator);
        self.title.deinit(allocator);
        if (self.pty_pid) |pid| {
            pid.send(.{"quit"}) catch {};
            pid.deinit();
            self.pty_pid = null;
        }
        self.vt.deinit();
        self.env.deinit();
        std.log.debug("terminal: vt destroyed", .{});
    }

    pub fn resize(self: *@This(), pos: Widget.Box) void {
        const cols: u16 = @intCast(@max(1, pos.w));
        const rows: u16 = @intCast(@max(1, pos.h));
        self.vt.resize(.{
            .rows = rows,
            .cols = cols,
            .x_pixel = 0,
            .y_pixel = 0,
        }) catch |e| {
            std.log.err("terminal: resize failed: {}", .{e});
        };
    }
};
var global_vt: ?Vt = null;

const pty = struct {
    const Parser = Terminal.Parser;

    const Receiver = tp.Receiver(*@This());

    allocator: std.mem.Allocator,
    vt: *Terminal,
    fd: tp.file_descriptor,
    pty_fd: std.posix.fd_t,
    parser: Parser,
    receiver: Receiver,
    parent: tp.pid,
    err_code: i64 = 0,
    sigchld: ?tp.signal = null,

    pub fn spawn(allocator: std.mem.Allocator, vt: *Terminal) !tp.pid {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .vt = vt,
            .fd = undefined,
            .pty_fd = vt.ptyFd(),
            .parser = .{ .buf = try .initCapacity(allocator, 128) },
            .receiver = Receiver.init(pty_receive, self),
            .parent = tp.self_pid().clone(),
        };
        return tp.spawn_link(allocator, self, start, "pty_actor");
    }

    fn deinit(self: *@This()) void {
        std.log.debug("terminal: pty actor deinit (pid={?})", .{self.vt.cmd.pid});
        if (self.sigchld) |s| s.deinit();
        self.fd.deinit();
        self.parser.buf.deinit();
        self.parent.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *@This()) tp.result {
        errdefer self.deinit();
        self.fd = tp.file_descriptor.init("pty", self.pty_fd) catch |e| {
            std.log.debug("terminal: pty fd init failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        self.fd.wait_read() catch |e| {
            std.log.debug("terminal: pty initial wait_read failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        self.sigchld = tp.signal.init(std.posix.SIG.CHLD, tp.message.fmt(.{"sigchld"})) catch |e| {
            std.log.debug("terminal: SIGCHLD signal init failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        tp.receive(&self.receiver);
    }

    fn pty_receive(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        if (try m.match(.{ "fd", "pty", "read_ready" })) {
            self.read_and_process() catch |e| return switch (e) {
                error.Terminated => {
                    std.log.debug("terminal: pty exiting: read loop terminated (process exited)", .{});
                    return tp.exit_normal();
                },
                error.InputOutput => {
                    std.log.debug("terminal: pty exiting: EIO on read (process exited)", .{});
                    return tp.exit_normal();
                },
                error.SendFailed => {
                    std.log.debug("terminal: pty exiting: send to parent failed", .{});
                    return tp.exit_normal();
                },
                error.Unexpected => {
                    std.log.debug("terminal: pty exiting: unexpected error (see preceding log)", .{});
                    return tp.exit_normal();
                },
            };
        } else if (try m.match(.{ "fd", "pty", "read_error", tp.extract(&self.err_code), tp.more })) {
            // thespian fires read_error with EPOLLHUP when the child exits cleanly.
            // Treat it the same as EIO: reap the child and signal exit.
            const code = self.vt.cmd.wait();
            std.log.debug("terminal: read_error from fd (err={d}), process exited with code={d}", .{ self.err_code, code });
            self.vt.event_queue.push(.{ .exited = code });
            self.parent.send(.{ "terminal_view", "output" }) catch {};
            return tp.exit_normal();
        } else if (try m.match(.{"sigchld"})) {
            // SIGCHLD fires when any child exits. Check if it's our child.
            if (self.vt.cmd.try_wait()) |code| {
                std.log.debug("terminal: child exited (SIGCHLD) with code={d}", .{code});
                self.vt.event_queue.push(.{ .exited = code });
                self.parent.send(.{ "terminal_view", "output" }) catch {};
                return tp.exit_normal();
            }
            // Not our child (or already reaped) - re-arm the signal and continue.
            if (self.sigchld) |s| s.deinit();
            self.sigchld = tp.signal.init(std.posix.SIG.CHLD, tp.message.fmt(.{"sigchld"})) catch null;
        } else if (try m.match(.{"quit"})) {
            std.log.debug("terminal: pty exiting: received quit", .{});
            return tp.exit_normal();
        } else {
            std.log.debug("terminal: pty exiting: unexpected message", .{});
            return tp.unexpected(m);
        }
    }

    fn read_and_process(self: *@This()) error{ Terminated, InputOutput, SendFailed, Unexpected }!void {
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = std.posix.read(self.vt.ptyFd(), &buf) catch |e| switch (e) {
                error.WouldBlock => {
                    // No more data right now. Check if the child already exited -
                    // on Linux a clean exit may not make the pty fd readable again
                    // (no EPOLLIN), it just starts returning EIO on the next read.
                    // Polling here catches that case before we arm wait_read again.
                    if (self.vt.cmd.try_wait()) |code| {
                        std.log.debug("terminal: child exited (detected via try_wait) with code={d}", .{code});
                        self.vt.event_queue.push(.{ .exited = code });
                        self.parent.send(.{ "terminal_view", "output" }) catch {};
                        return error.InputOutput;
                    }
                    break;
                },
                error.InputOutput => {
                    const code = self.vt.cmd.wait();
                    std.log.debug("terminal: read EIO, process exited with code={d}", .{code});
                    self.vt.event_queue.push(.{ .exited = code });
                    self.parent.send(.{ "terminal_view", "output" }) catch {};
                    return error.InputOutput;
                },
                error.SystemResources,
                error.IsDir,
                error.OperationAborted,
                error.BrokenPipe,
                error.ConnectionResetByPeer,
                error.ConnectionTimedOut,
                error.NotOpenForReading,
                error.SocketNotConnected,
                error.Canceled,
                error.AccessDenied,
                error.ProcessNotFound,
                error.LockViolation,
                error.Unexpected,
                => {
                    std.log.debug("terminal: read unexpected error: {} (pid={?})", .{ e, self.vt.cmd.pid });
                    return error.Unexpected;
                },
            };
            if (n == 0) {
                const code = self.vt.cmd.wait();
                std.log.debug("terminal: read returned 0 bytes (EOF), process exited with code={d}", .{code});
                self.vt.event_queue.push(.{ .exited = code });
                self.parent.send(.{ "terminal_view", "output" }) catch {};
                return error.Terminated;
            }

            defer self.parent.send(.{ "terminal_view", "output" }) catch {};

            switch (self.vt.processOutput(&self.parser, buf[0..n]) catch |e| switch (e) {
                error.WriteFailed,
                error.ReadFailed,
                error.OutOfMemory,
                => {
                    std.log.debug("terminal: processOutput error: {} (pid={?})", .{ e, self.vt.cmd.pid });
                    return error.Unexpected;
                },
            }) {
                .exited => {
                    std.log.debug("terminal: processOutput returned .exited (process EOF)", .{});
                    return error.Terminated;
                },
                .running => {},
            }
        }

        // Check for child exit once more before sleeping in wait_read.
        // A clean exit with no final output will never make the pty fd readable,
        // so we must detect it here rather than waiting forever.
        if (self.vt.cmd.try_wait()) |code| {
            std.log.debug("terminal: child exited (pre-wait_read check) with code={d}", .{code});
            self.vt.event_queue.push(.{ .exited = code });
            self.parent.send(.{ "terminal_view", "output" }) catch {};
            return error.InputOutput;
        }

        self.fd.wait_read() catch |e| switch (e) {
            error.ThespianFileDescriptorWaitReadFailed => {
                std.log.debug("terminal: wait_read failed: {} (pid={?})", .{ e, self.vt.cmd.pid });
                return error.Unexpected;
            },
        };
    }
};
