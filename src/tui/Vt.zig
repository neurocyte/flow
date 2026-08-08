const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const color = @import("color");
const shell = @import("shell");
const argv = @import("argv");
const bin_path = @import("bin_path");
const vaxis = @import("renderer").vaxis;
const root = @import("root");
const builtin = @import("builtin");

const tui = @import("tui.zig");
const Box = @import("Widget.zig").Box;
const Pty = if (builtin.os.tag == .windows) @import("PtyWindows.zig") else @import("PtyPosix.zig");

const Terminal = @import("Terminal");
const TerminalOnExit = @import("config").TerminalOnExit;

pub const Screen = Terminal.Screen;
pub const Event = Terminal.Event;
pub const Manager = @import("VtManager.zig");

const Vt = @This();

vt: Terminal,
env: std.process.Environ.Map,
write_buf: [4096]u8,
pty_pid: ?tp.pid = null,
cwd: std.ArrayListUnmanaged(u8) = .empty,
title: std.ArrayListUnmanaged(u8) = .empty,
last_cmd: ?cbor.Raw = null,
/// App-specified override colours (from OSC 10/11/12). null = use theme.
app_fg: ?[3]u8 = null,
app_bg: ?[3]u8 = null,
app_cursor: ?[3]u8 = null,
process_exited: bool = false,
on_exit: TerminalOnExit,
synthesize_marks: bool = false,
started_at: i64 = 0,
profile: ?Terminal.Profile = null,

fn init(io: std.Io, allocator: std.mem.Allocator, cmd_argv: []const []const u8, env: std.process.Environ.Map, rows: u16, cols: u16, on_exit: TerminalOnExit) !*@This() {
    const home = env.get("HOME") orelse "/tmp";

    const self = try Manager.create(env, on_exit);
    self.vt = try Terminal.init(
        io,
        allocator,
        cmd_argv,
        &env,
        .{
            .winsize = winsize_for(rows, cols),
            .scrollback_size = tui.config().terminal_scrollback_size,
            .initial_working_directory = blk: {
                const project = tp.env.get().str("project");
                break :blk if (project.len > 0) project else home;
            },
        },
        &self.write_buf,
    );

    const theme = tui.active_theme();
    if (theme.editor.fg) |fg| self.vt.fg_color = color.u24_to_u8s(fg.color);
    if (theme.editor.bg) |bg| self.vt.bg_color = color.u24_to_u8s(bg.color);
    @memcpy(self.vt.palette[0..16], &theme.ansi_palette);
    @memcpy(self.vt.palette_default[0..16], &theme.ansi_palette);
    self.vt.color_scheme = switch (theme.type) {
        .dark => .dark,
        .light => .light,
    };

    try self.vt.spawn();
    return self;
}

/// Start the pty read actor.
fn start_reader(self: *@This(), allocator: std.mem.Allocator) !void {
    self.started_at = std.Io.Clock.now(.awake, root.get_io()).toMilliseconds();
    self.pty_pid = try Pty.spawn(allocator, &self.vt);
}

/// Replace the exited command with a new one.
fn respawn(self: *@This(), cmd_argv: []const []const u8) !void {
    if (self.pty_pid) |pid| {
        pid.send(.{"quit"}) catch {};
        pid.deinit();
        self.pty_pid = null;
    }
    const home = self.env.get("HOME") orelse "/tmp";
    const project = tp.env.get().str("project");
    const wd = if (project.len > 0) project else home;
    try self.vt.respawn(cmd_argv, &self.env, wd, &self.write_buf);
    self.process_exited = false;
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.cwd.deinit(allocator);
    self.title.deinit(allocator);
    if (self.last_cmd) |cmd| allocator.free(cmd.bytes);
    if (self.pty_pid) |pid| {
        pid.send(.{"quit"}) catch {};
        pid.deinit();
        self.pty_pid = null;
    }
    self.vt.deinit();
    self.env.deinit();
    if (self.profile) |*p| p.deinit(allocator);
    std.log.debug("terminal: vt destroyed", .{});
    Manager.destroyed(self);
}

pub fn resize(self: *@This(), pos: Box) void {
    const rows: u16 = @intCast(@max(1, pos.h));
    const cols: u16 = @intCast(@max(1, pos.w));
    self.vt.resize(winsize_for(rows, cols)) catch |e| {
        std.log.err("terminal: resize failed: {}", .{e});
    };
}

pub fn paste(self: *@This(), text: []const u8) void {
    self.vt.scrollToBottom();
    self.vt.paste(text);
}

pub fn kill(self: *@This()) void {
    self.vt.killForeground();
}

fn inject(self: *@This(), bytes: []const u8) void {
    var parser: Pty.Parser = .{ .buf = .init(self.vt.allocator) };
    defer parser.buf.deinit();
    _ = self.vt.processOutput(&parser, bytes, self, process_terminal_event) catch {};
}

// Write a shell-style prompt with OSC 133 marks
fn inject_prompt(self: *@This(), display: []const u8) void {
    var msg: std.Io.Writer.Allocating = .init(self.vt.allocator);
    defer msg.deinit();
    const w = &msg.writer;
    w.writeAll("\x1b[0m\x1b]133;A\x1b\\") catch {}; // reset SGR, prompt_start
    w.print("\x1b[1;34m$\x1b[0m {s}\r\n", .{display}) catch {}; // visible command line
    w.writeAll("\x1b]133;C\x1b\\") catch {}; // output_start
    self.inject(msg.written());
}

// Close command output range
fn inject_output_end(self: *@This(), code: u8) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b]133;D;{d}\x1b\\", .{code}) catch return;
    self.inject(s);
}

pub fn get_title(self: *@This()) []const u8 {
    if (self.title.items.len > 0) return self.title.items;
    if (self.profile) |p| if (p.name.len > 0) return p.name;
    return self.title.items;
}

pub fn set_title(self: *@This(), title: []const u8) void {
    self.title.clearRetainingCapacity();
    self.title.appendSlice(self.vt.allocator, title) catch {};
}

fn process_terminal_event(ctx: *Terminal.Event.HandlerContext, event: Terminal.Event) error{TerminalHandlerFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    return self.process_event(event) catch error.TerminalHandlerFailed;
}

pub fn process_event(self: *@This(), event: Terminal.Event) !void {
    switch (event) {
        .exited => |code| {
            self.process_exited = true;
            if (self.pty_pid) |pid| {
                pid.deinit();
                self.pty_pid = null;
            }
            if (self.synthesize_marks) self.inject_output_end(code);
            self.handle_child_exit(code);
            tui.need_render(@src());
        },
        .redraw, .bell => {
            tui.need_render(@src());
        },
        .pwd_change => |path| {
            self.cwd.clearRetainingCapacity();
            self.cwd.appendSlice(self.vt.allocator, path) catch {};
        },
        .title_change => |t| {
            self.set_title(t);
        },
        .color_change => |cc| {
            self.app_fg = cc.fg;
            self.app_bg = cc.bg;
            self.app_cursor = cc.cursor;
        },
        .osc_copy => |text| {
            // Terminal app wrote to clipboard via OSC 52.
            // Add to flow clipboard history and forward to system clipboard.
            const owned = try tui.clipboard_allocator().dupe(u8, text);
            tui.clipboard_clear_all();
            tui.clipboard_start_group();
            tui.clipboard_add_chunk(owned);
            tui.clipboard_send_to_system() catch {};
        },
        .osc_paste_request => {
            // Terminal app requested clipboard contents via OSC 52.
            // Assemble from flow clipboard history and respond.
            if (tui.clipboard_get_history()) |history| {
                var buf: std.Io.Writer.Allocating = .init(self.vt.allocator);
                defer buf.deinit();
                var first = true;
                for (history) |chunk| {
                    if (first) first = false else buf.writer.writeByte('\n') catch break;
                    buf.writer.writeAll(chunk.text) catch break;
                }
                self.vt.respondOsc52Paste(buf.written());
            }
        },
        .shell_state_change => {},
    }
}

fn handle_child_exit(self: *@This(), code: u8) void {
    switch (self.on_exit) {
        .hold => self.show_exit_message(code),
        .hold_on_error => if (code == 0)
            tp.self_pid().send(.{ "cmd", "close_terminal_on_exit", .{} }) catch {}
        else
            self.show_exit_message(code),
        .close => tp.self_pid().send(.{ "cmd", "close_terminal_on_exit", .{} }) catch {},
    }
}

fn show_exit_message(self: *@This(), code: u8) void {
    var msg: std.Io.Writer.Allocating = .init(self.vt.allocator);
    defer msg.deinit();
    const w = &msg.writer;
    w.writeAll("\r\n") catch {};
    w.writeAll("\x1b[0m\x1b[2m") catch {};
    w.writeAll("[process exited") catch {};
    if (code != 0)
        w.print(" with code {d}", .{code}) catch {};
    const runtime_ms = std.Io.Clock.now(.awake, root.get_io()).toMilliseconds() - self.started_at;
    if (runtime_ms >= 2 * std.time.ms_per_s) {
        const secs = @divFloor(runtime_ms, std.time.ms_per_s);
        if (secs >= std.time.s_per_min)
            w.print(" in {d}m{d}s", .{ @divFloor(secs, std.time.s_per_min), @mod(secs, std.time.s_per_min) }) catch {}
        else
            w.print(" in {d}s", .{secs}) catch {};
    }
    w.writeAll("]") catch {};
    // Re-run prompt
    const cmd_argv = self.vt.cmd.argv;
    if (cmd_argv.len > 0) {
        w.writeAll(" Press enter to re-run '") catch {};
        _ = argv.write(w, cmd_argv) catch {};
        w.writeAll("', shift+enter for a shell, or escape/ctrl+d to close") catch {};
    } else {
        w.writeAll(" Press shift+enter for a shell, or escape/ctrl+d to close") catch {};
    }
    w.writeAll("\x1b[0m\r\n") catch {};
    var parser: Pty.Parser = .{ .buf = .init(self.vt.allocator) };
    defer parser.buf.deinit();
    _ = self.vt.processOutput(&parser, msg.written(), self, process_terminal_event) catch {};
}

pub fn prepare_cmd(allocator: std.mem.Allocator, ctx: command.Context, profile_override: ?Terminal.Profile) (error{
    OutOfMemory,
    Stop,
    WriteFailed,
} || cbor.Error)!struct {
    env: std.process.Environ.Map,
    display_cmd: []const u8,
    have_cmd: bool,
    have_arg: bool,
    argv_list: std.ArrayListUnmanaged([]const u8),
    on_exit: TerminalOnExit,

    env_owned: bool = true,
    expanded_cmd_arg: []const u8,
    profile: ?Terminal.Profile = null,

    fn deinit(self: *@This(), a: std.mem.Allocator) void {
        if (self.env_owned) self.env.deinit();
        a.free(self.expanded_cmd_arg);
        for (self.argv_list.items) |arg| a.free(arg);
        self.argv_list.deinit(a);
        if (self.profile) |*p| p.deinit(a);
    }
} {
    var env = try root.get_init().environ_map.clone(allocator);
    errdefer env.deinit();
    try env.put("TERM", tui.config().terminal_TERM);
    try env.put("COLORTERM", "truecolor");
    // COLORFGBG tells apps whether the terminal background is dark or light
    try env.put("COLORFGBG", switch (tui.active_color_scheme()) {
        .dark => "15;0",
        .light => "0;15",
    });

    var cmd_arg: []const u8 = "";
    var on_exit: TerminalOnExit = tui.config().terminal_on_exit;
    const have_arg = (cbor.match(ctx.args.buf, .{tp.extract(&cmd_arg)}) catch false and cmd_arg.len > 0) or
        (cbor.match(ctx.args.buf, .{ tp.extract(&cmd_arg), tp.extract(&on_exit) }) catch false and cmd_arg.len > 0);

    const expanded_cmd_arg = @import("expansion.zig").expand(allocator, cmd_arg) catch |e| switch (e) {
        error.Unavailable, error.NotFound => return error.Stop,
        else => |e_| return e_,
    };
    errdefer allocator.free(expanded_cmd_arg);
    cmd_arg = expanded_cmd_arg;

    const display_cmd = cmd_arg;
    const argv_msg: ?tp.message = if (have_arg)
        try shell.parse_arg0_to_argv(allocator, &cmd_arg)
    else
        null;
    defer if (argv_msg) |msg| allocator.free(msg.buf);

    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (argv_list.items) |arg| allocator.free(arg);
        argv_list.deinit(allocator);
    }
    var profile: ?Terminal.Profile = null;
    errdefer if (profile) |*p| p.deinit(allocator);
    var have_cmd = false;
    if (profile_override) |po| {
        // Launch a specific profile's shell (not a command).
        const shell_argv = profileArgv(allocator, po) catch |e| switch (e) {
            error.Unavailable, error.NotFound => return error.Stop,
            else => |e_| return e_,
        };
        defer allocator.free(shell_argv); // elements are moved into argv_list
        for (shell_argv) |arg| try argv_list.append(allocator, arg);
        profile = try Terminal.Profile.dupe(allocator, po);
    } else if (argv_msg) |msg| {
        var iter = msg.buf;
        var len = try cbor.decodeArrayHeader(&iter);
        while (len > 0) : (len -= 1) {
            var arg: []const u8 = undefined;
            if (try cbor.matchValue(&iter, cbor.extract(&arg)))
                try argv_list.append(allocator, try allocator.dupe(u8, arg));
            have_cmd = true;
        }
    } else {
        const shell_argv = try defaultShellArgv(allocator, env, &profile);
        defer allocator.free(shell_argv); // elements are moved into argv_list
        for (shell_argv) |arg| try argv_list.append(allocator, arg);
    }

    // Resolve command with no path
    if (argv_list.items.len > 0) {
        const arg0 = argv_list.items[0];
        const is_path = for (arg0) |c| {
            if (std.fs.path.isSep(c)) break true;
        } else false;
        if (!is_path) if (bin_path.find_binary_in_path(allocator, arg0) catch null) |found| {
            defer allocator.free(found);
            const owned = try allocator.dupe(u8, found);
            allocator.free(argv_list.items[0]);
            argv_list.items[0] = owned;
        };
    }

    return .{
        .env = env,
        .display_cmd = display_cmd,
        .expanded_cmd_arg = expanded_cmd_arg,
        .have_cmd = have_cmd,
        .have_arg = have_arg,
        .argv_list = argv_list,
        .on_exit = on_exit,
        .profile = profile,
    };
}

pub fn run_new_cmd(io: std.Io, allocator: std.mem.Allocator, ctx: command.Context, rows: u16, cols: u16) !*@This() {
    return run_new_cmd_impl(io, allocator, ctx, rows, cols, null);
}

pub fn run_new_profile(io: std.Io, allocator: std.mem.Allocator, profile: Terminal.Profile, rows: u16, cols: u16) !*@This() {
    return run_new_cmd_impl(io, allocator, .empty(), rows, cols, profile);
}

fn run_new_cmd_impl(io: std.Io, allocator: std.mem.Allocator, ctx: command.Context, rows: u16, cols: u16, profile_override: ?Terminal.Profile) !*@This() {
    var cmd = try prepare_cmd(allocator, ctx, profile_override);
    defer cmd.deinit(allocator);
    cmd.env_owned = false;
    const self = try Vt.init(io, allocator, cmd.argv_list.items, cmd.env, rows, cols, cmd.on_exit);
    self.profile = cmd.profile; // move ownership out of cmd
    cmd.profile = null;
    self.synthesize_marks = cmd.have_cmd;
    if (cmd.have_cmd) self.inject_prompt(cmd.display_cmd);
    try self.start_reader(allocator);

    const new_last_cmd = try allocator.dupe(u8, ctx.args.buf);
    if (self.last_cmd) |last_cmd| allocator.free(last_cmd.bytes);
    self.last_cmd = .{ .bytes = new_last_cmd };
    self.set_title(cmd.display_cmd);
    return self;
}

pub fn run_cmd(self: *@This(), ctx: command.Context) !enum { ok, busy } {
    var cmd = try prepare_cmd(self.vt.allocator, ctx, null);
    defer cmd.deinit(self.vt.allocator);
    const vt = self.vt;
    const allocator = vt.allocator;

    const can_take_over = self.process_exited or switch (self.vt.shellState()) {
        .at_prompt, .at_prompt_with_input => true,
        .running => false,
    };
    if (cmd.have_cmd and !can_take_over) return .busy;

    if (cmd.have_cmd) {
        try self.respawn(cmd.argv_list.items);
        self.on_exit = cmd.on_exit;
        self.synthesize_marks = true;
        self.inject_prompt(cmd.display_cmd);
        try self.start_reader(allocator);
    }

    if (cmd.have_arg or self.last_cmd == null) {
        const new_last_cmd = try allocator.dupe(u8, ctx.args.buf);
        if (self.last_cmd) |last_cmd| allocator.free(last_cmd.bytes);
        self.last_cmd = .{ .bytes = new_last_cmd };
        self.set_title(cmd.display_cmd);
    }
    return .ok;
}

pub fn re_run_cmd(self: *@This()) !void {
    return if (self.last_cmd) |cmd|
        switch (try self.run_cmd(.init(.{ .buf = cmd.bytes }))) {
            .busy => self.running_error(),
            else => {},
        }
    else
        tp.exit("no command to re-run");
}

fn running_error(self: *const @This()) error{Exit} {
    var msg: std.Io.Writer.Allocating = .init(self.vt.allocator);
    defer msg.deinit();
    msg.writer.writeAll("terminal is already running '") catch {};
    self.get_running_cmd(&msg.writer) catch {};
    msg.writer.writeAll("'") catch {};
    return tp.exit(msg.written());
}

pub fn is_vt_running(self: *const Vt) bool {
    return !self.process_exited;
}

pub fn get_profile(self: *const Vt) ?*const Terminal.Profile {
    return if (self.profile) |*p| p else null;
}

/// All terminal profiles available to launch.
pub fn available_profiles(allocator: std.mem.Allocator) ![]Terminal.Profile {
    var list: std.ArrayListUnmanaged(Terminal.Profile) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(allocator);
        list.deinit(allocator);
    }

    var wt: ?[]Terminal.Profile = null;
    defer if (wt) |w| allocator.free(w); // elements are moved into list
    if (builtin.os.tag == .windows and tui.config().terminal_read_wt_profiles)
        if (Terminal.WtProfiles.read(allocator)) |w| {
            wt = w;
        } else |_| {};
    const have_wt = if (wt) |w| w.len > 0 else false;

    const user = try Terminal.Profile.list(allocator);
    defer allocator.free(user); // elements are moved into list
    const replace_builtin = have_wt and !Terminal.Profile.has_configured_default(allocator);

    if (replace_builtin) {
        if (wt) |w| for (w) |p| try list.append(allocator, p);
        user[0].deinit(allocator); // drop the built-in default
        for (user[1..]) |p| try list.append(allocator, p);
    } else {
        for (user) |p| try list.append(allocator, p);
        if (wt) |w| for (w) |p| try list.append(allocator, p);
    }

    return list.toOwnedSlice(allocator);
}

pub fn free_profiles(allocator: std.mem.Allocator, profiles: []Terminal.Profile) void {
    Terminal.Profile.free(allocator, profiles);
}

pub fn find_profile(allocator: std.mem.Allocator, name: []const u8) !?Terminal.Profile {
    const profiles = try available_profiles(allocator);
    defer free_profiles(allocator, profiles);
    for (profiles) |p| if (std.mem.eql(u8, p.name, name))
        return try Terminal.Profile.dupe(allocator, p);
    return null;
}

/// True when this vt is running an application rather than sitting idle at
/// a shell prompt (or having exited).
pub fn has_active_application(self: *Vt) bool {
    if (self.process_exited) return false;
    return switch (self.vt.shellState()) {
        .at_prompt, .at_prompt_with_input => false,
        .running => true,
    };
}

/// Argv of the shell to spawn when no command was given..
fn defaultShellArgv(allocator: std.mem.Allocator, env: std.process.Environ.Map, profile_out: *?Terminal.Profile) ![][]const u8 {
    profile_out.* = null;
    if (builtin.os.tag == .windows and tui.config().terminal_read_wt_profiles)
        if (Terminal.WtProfiles.read(allocator)) |profiles| {
            defer Terminal.Profile.free(allocator, profiles);
            if (profiles.len > 0) { // the default profile sorts first
                if (profileArgv(allocator, profiles[0])) |args| {
                    if (args.len > 0) {
                        profile_out.* = Terminal.Profile.dupe(allocator, profiles[0]) catch null;
                        return args;
                    }
                    Terminal.command_line.free(allocator, args);
                } else |e| std.log.warn("terminal: cannot use Windows Terminal default profile: {t}", .{e});
            }
        } else |_| {};

    var profile = try Terminal.Profile.get_default(allocator);
    if (profileArgv(allocator, profile)) |args| {
        if (args.len > 0) {
            profile_out.* = profile; // transfer ownership to the caller
            return args;
        }
        Terminal.command_line.free(allocator, args);
    } else |e| std.log.warn("terminal: cannot expand default profile command: {t}", .{e});
    profile.deinit(allocator);

    // Last resort if the profile command expands to nothing.
    const shell_path = if (builtin.os.tag == .windows)
        env.get("COMSPEC") orelse "cmd.exe"
    else
        env.get("SHELL") orelse "/bin/sh";
    return singleArgv(allocator, shell_path);
}

/// Expand a profile's command line and split it into an owned argv. Free with
/// `Terminal.command_line.free`.
fn profileArgv(allocator: std.mem.Allocator, profile: Terminal.Profile) ![][]const u8 {
    const expanded = try @import("expansion.zig").expand(allocator, profile.command);
    defer allocator.free(expanded);
    return Terminal.command_line.split(allocator, expanded);
}

fn singleArgv(allocator: std.mem.Allocator, arg0: []const u8) ![][]const u8 {
    const args = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(args);
    args[0] = try allocator.dupe(u8, arg0);
    return args;
}

pub fn get_running_cmd(self: *const Vt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const cmd_argv = self.vt.cmd.argv;
    if (cmd_argv.len > 0) _ = argv.write(writer, cmd_argv) catch {};
}

pub fn restart_shell(self: *Vt) !void {
    var profile: ?Terminal.Profile = null;
    errdefer if (profile) |*p| p.deinit(self.vt.allocator);
    const shell_argv = try defaultShellArgv(self.vt.allocator, self.env, &profile);
    defer Terminal.command_line.free(self.vt.allocator, shell_argv);
    try self.respawn(shell_argv);
    if (self.profile) |*p| p.deinit(self.vt.allocator);
    self.profile = profile;
    self.synthesize_marks = false;
    self.on_exit = tui.config().terminal_on_exit;
    try self.start_reader(self.vt.allocator);
}

fn winsize_for(rows: u16, cols: u16) vaxis.Winsize {
    const cell = tui.rdr().cell_size() orelse return .{
        .rows = rows,
        .cols = cols,
        .x_pixel = 0,
        .y_pixel = 0,
    };
    return .{
        .rows = rows,
        .cols = cols,
        .x_pixel = cell.w *| cols,
        .y_pixel = cell.h *| rows,
    };
}
