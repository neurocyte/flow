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
vt: Terminal,
env: std.process.EnvMap,
write_buf: [4096]u8,
pty_pid: ?tp.pid = null,
focused: bool = false,
cwd: std.ArrayListUnmanaged(u8) = .empty,
title: std.ArrayListUnmanaged(u8) = .empty,
input_mode: Mode,
hover: bool = false,

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
        .pty_pid = null,
        .input_mode = try keybind.mode("terminal", allocator, .{ .insert_command = "do_nothing" }),
    };

    try self.vt.spawn();

    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));

    container.ctx = self;
    try container.add(Widget.to(self));

    self.pty_pid = try pty.spawn(allocator, &self.vt);

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
    self.vt.update(.{ .key_press = key }) catch |e|
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
    self.cwd.deinit(self.allocator);
    self.title.deinit(self.allocator);
    if (self.pty_pid) |pid| {
        pid.send(.{ "pty_actor", "quit" }) catch {};
        pid.deinit();
        self.pty_pid = null;
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
            .exited => |code| {
                self.show_exit_message(code);
                tui.need_render(@src());
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
    self.vt.draw(self.allocator, self.plane.window, self.focused) catch |e| {
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
    _ = self.vt.processOutput(&parser, msg.written()) catch {};
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

fn receive_filter(_: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (m.match(.{ "terminal_view", "output" }) catch false) {
        tui.need_render(@src());
        return true;
    }
    return false;
}

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
        self.fd.deinit();
        self.parser.buf.deinit();
        self.parent.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *@This()) tp.result {
        errdefer self.deinit();
        self.fd = tp.file_descriptor.init("pty", self.pty_fd) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.fd.wait_read() catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn pty_receive(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        if (try m.match(.{ "fd", "pty", "read_ready" })) {
            try self.read_and_process();
            return;
        }

        if (try m.match(.{ "pty_actor", "quit" })) {
            return tp.exit_normal();
        }
    }

    fn read_and_process(self: *@This()) tp.result {
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = std.posix.read(self.vt.ptyFd(), &buf) catch |e| switch (e) {
                error.WouldBlock => break,
                error.InputOutput => {
                    const code = self.vt.cmd.wait();
                    self.vt.event_queue.push(.{ .exited = code });
                    self.parent.send(.{ "terminal_view", "output" }) catch {};
                    return tp.exit_normal();
                },
                else => return tp.exit_error(e, @errorReturnTrace()),
            };
            if (n == 0) {
                const code = self.vt.cmd.wait();
                self.vt.event_queue.push(.{ .exited = code });
                self.parent.send(.{ "terminal_view", "output" }) catch {};
                return tp.exit_normal();
            }

            const exited = self.vt.processOutput(&self.parser, buf[0..n]) catch |e|
                return tp.exit_error(e, @errorReturnTrace());
            if (exited) {
                self.parent.send(.{ "terminal_view", "output" }) catch {};
                return tp.exit_normal();
            }
            // Notify parent that new output is available.
            self.parent.send(.{ "terminal_view", "output" }) catch {};
        }

        self.fd.wait_read() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
};
