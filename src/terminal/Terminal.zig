//! A virtual terminal widget
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
pub const Parser = @import("Parser.zig");
const vaxis = @import("vaxis");
const xterm = @import("xterm");

// Platform-specific pty/command implementations
const is_windows = builtin.os.tag == .windows;
pub const Command = if (is_windows) @import("CommandWindows.zig") else @import("Command.zig");
const Pty = if (is_windows) @import("ConPTY.zig") else @import("Pty.zig");
const Winsize = vaxis.Winsize;
pub const Screen = @import("Screen.zig");
const Key = vaxis.Key;
const key = @import("key.zig");
const mouse = @import("mouse.zig");

pub const Event = union(enum) {
    exited: u8,
    redraw,
    bell,
    title_change: []const u8,
    pwd_change: []const u8,
    /// OSC 52 copy: terminal app wrote to clipboard. Text is owned by the Terminal
    /// allocator; the event handler must NOT free it (Terminal manages the buffer).
    osc_copy: []const u8,
    /// OSC 52 paste request: terminal app wants the clipboard contents.
    /// The handler should call Terminal.respondOsc52Paste() with the text.
    osc_paste_request,
    /// OSC 10/11/12 set: app overrode fg, bg, or cursor colour.
    /// null means "reset to default" for that slot.
    color_change: struct {
        fg: ?[3]u8,
        bg: ?[3]u8,
        cursor: ?[3]u8,
    },
    /// OSC 133 prompt mark received. Carries the current shell state
    shell_state_change: Screen.ShellState,

    pub const Handler = *const fn (ctx: *HandlerContext, event: @This()) error{TerminalHandlerFailed}!void;
    pub const HandlerContext = anyopaque;
};

const log = std.log.scoped(.terminal);

pub const Options = struct {
    scrollback_size: u16 = 500,
    winsize: Winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    initial_working_directory: ?[]const u8 = null,
};

pub const Mode = struct {
    origin: bool = false,
    autowrap: bool = true,
    cursor: bool = true,
    sync: bool = false,
    keypad_application: bool = false,
    /// DECCKM: when true, arrow keys send ESC O A/B/C/D instead of ESC [ A/B/C/D
    cursor_keys_app: bool = false,
    /// Mouse reporting mode
    mouse: MouseMode = .none,
    /// SGR extended mouse coordinates (mode 1006); always enabled alongside any mouse mode
    mouse_sgr: bool = false,
    /// DECSET 2004: wrap pasted text in ESC[200~ / ESC[201~ markers
    bracketed_paste: bool = false,
};

pub const MouseMode = enum {
    /// No mouse reporting
    none,
    /// X10 compatibility: only button-press events, no release, no motion
    x10,
    /// Normal: press and release events
    normal,
    /// Button-event: press, release, and drag (motion while button held)
    button_event,
    /// Any-event: press, release, and all motion
    any_event,
};

pub const Charset = enum {
    /// US ASCII - pass characters through unchanged
    ascii,
    /// DEC Special Character and Line Drawing Set (ESC ( 0)
    dec_special,
};

pub const InputEvent = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
};

io: std.Io,
allocator: std.mem.Allocator,
scrollback_size: u16,

pty: Pty,
pty_writer: std.Io.File.Writer,
cmd: Command,

/// the screen we draw from
front_screen: Screen,
front_mutex: std.Io.Mutex = .init,

/// the back screens
back_screen: *Screen = undefined,
back_screen_pri: Screen,
back_screen_alt: Screen,
// only applies to primary screen
scroll_offset: usize = 0,
back_mutex: std.Io.Mutex = .init,
// dirty is protected by back_mutex. Only access this field when you hold that mutex
dirty: bool = false,

mode: Mode = .{},

/// Default colours reported in response to OSC 10/11 queries.
/// Set by the embedding widget after each render so apps get accurate colours.
/// Stored as 8-bit RGB; the OSC response scales to 16-bit (xx/xx pattern).
/// Colours set by the embedding widget. Used for OSC queries.
fg_color: [3]u8 = .{ 0xff, 0xff, 0xff },
bg_color: [3]u8 = .{ 0x00, 0x00, 0x00 },
/// 256-colour palette stored and fetched by OSC 4 queries.
palette: [256][3]u8 = xterm_palette_default,
/// The palette an OSC 104 / RIS reset restores.
palette_default: [256][3]u8 = xterm_palette_default,
/// Set once a client overrides any entry.
palette_modified: bool = false,
/// Colours overridden by the terminal application via OSC 10/11/12.
/// null = not overridden (fall back to fg_color/bg_color/default cursor).
app_fg_color: ?[3]u8 = null,
app_bg_color: ?[3]u8 = null,
app_cursor_color: ?[3]u8 = null,

/// G0 and G1 character set designations
/// ESC ( X designates G0, ESC ) X designates G1
charset_g0: Charset = .ascii,
charset_g1: Charset = .ascii,
/// When true, G1 is active (SO); when false, G0 is active (SI / default).
charset_shifted: bool = false,

tab_stops: std.ArrayList(u16),
title: std.ArrayList(u8) = .empty,
working_directory: std.ArrayList(u8) = .empty,

last_printed: []const u8 = "",
/// Scratch buffer for decoding OSC 52 base64 clipboard data.
osc52_buf: std.ArrayListUnmanaged(u8) = .empty,

/// initialize a Terminal. This sets the size of the underlying pty and allocates the sizes of the
/// screen
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
    opts: Options,
    write_buf: []u8,
) !Terminal {
    // Verify we have an absolute path
    if (opts.initial_working_directory) |pwd| {
        if (!std.fs.path.isAbsolute(pwd)) return error.InvalidWorkingDirectory;
    }
    // Dupe argv so Terminal owns the strings for its full lifetime.
    const argv_owned = try allocator.alloc([]const u8, argv.len);
    errdefer {
        for (argv_owned) |a| allocator.free(a);
        allocator.free(argv_owned);
    }
    for (argv, argv_owned) |src_arg, *dst| dst.* = try allocator.dupe(u8, src_arg);

    var pty = if (is_windows)
        try Pty.init(allocator, opts.winsize)
    else blk: {
        const p = try Pty.init();
        try p.setSize(opts.winsize);
        break :blk p;
    };
    errdefer pty.deinit(io);

    const cmd: Command = if (is_windows) .{
        .argv = argv_owned,
        .env_map = env,
        .working_directory = opts.initial_working_directory,
    } else .{
        .argv = argv_owned,
        .env_map = env,
        .pty = pty,
        .working_directory = opts.initial_working_directory,
    };
    var tabs: std.ArrayList(u16) = try .initCapacity(allocator, opts.winsize.cols / 8);
    var col: u16 = 0;
    while (col < opts.winsize.cols) : (col += 8) {
        try tabs.append(allocator, col);
    }
    return .{
        .io = io,
        .allocator = allocator,
        .pty = pty,
        .pty_writer = if (is_windows)
            pty.inputFile().writerStreaming(io, write_buf)
        else
            pty.pty.writerStreaming(io, write_buf),
        .cmd = cmd,
        .scrollback_size = opts.scrollback_size,
        .front_screen = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows),
        .back_screen_pri = try Screen.initScrollback(allocator, opts.winsize.cols, opts.winsize.rows, opts.scrollback_size),
        .back_screen_alt = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows),
        .tab_stops = tabs,
    };
}

/// release all resources of the Terminal
pub fn deinit(self: *Terminal) void {
    self.cmd.kill();
    // cmd.wait() is called by the pty read loop after it sees EIO/EOF
    for (self.cmd.argv) |a| self.allocator.free(a);
    self.allocator.free(self.cmd.argv);
    self.pty.deinit(self.io);
    self.front_screen.deinit(self.allocator);
    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_alt.deinit(self.allocator);
    self.osc52_buf.deinit(self.allocator);
    self.tab_stops.deinit(self.allocator);
    self.title.deinit(self.allocator);
    self.working_directory.deinit(self.allocator);
}

pub fn spawn(self: *Terminal) !void {
    self.back_screen = &self.back_screen_pri;

    if (is_windows)
        try self.cmd.spawn(self.allocator, &self.pty)
    else
        try self.cmd.spawn(self.allocator);

    self.working_directory.clearRetainingCapacity();
    if (self.cmd.working_directory) |pwd| {
        try self.working_directory.appendSlice(self.allocator, pwd);
    } else {
        const pwd = std.Io.Dir.cwd();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try pwd.realPath(self.io, &buffer);
        try self.working_directory.appendSlice(self.allocator, buffer[0..len]);
    }

    if (!is_windows) {
        // Set the pty master fd to non-blocking so reads return EAGAIN
        // when no data is available rather than blocking.
        const posix = std.posix;
        const cur_flags = std.c.fcntl(self.pty.pty.handle, @as(c_int, posix.F.GETFL));
        if (cur_flags >= 0) {
            var flags: std.c.O = @bitCast(@as(u32, @intCast(cur_flags)));
            flags.NONBLOCK = true;
            _ = std.c.fcntl(self.pty.pty.handle, @as(c_int, posix.F.SETFL), @as(u32, @bitCast(flags)));
        }
    }
}

/// Replace the running command with a new one, keeping the existing screens.
pub fn respawn(
    self: *Terminal,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
    working_directory: ?[]const u8,
    write_buf: []u8,
) !void {
    // tear down the old command and pty, leaving the screens untouched
    self.cmd.kill();
    for (self.cmd.argv) |a| self.allocator.free(a);
    self.allocator.free(self.cmd.argv);
    self.pty.deinit(self.io);

    const argv_owned = try self.allocator.alloc([]const u8, argv.len);
    errdefer {
        for (argv_owned) |a| self.allocator.free(a);
        self.allocator.free(argv_owned);
    }
    for (argv, argv_owned) |src_arg, *dst| dst.* = try self.allocator.dupe(u8, src_arg);

    const ws: Winsize = .{ .rows = self.front_screen.height, .cols = self.front_screen.width, .x_pixel = 0, .y_pixel = 0 };
    var new_pty = if (is_windows)
        try Pty.init(self.allocator, ws)
    else blk: {
        const p = try Pty.init();
        try p.setSize(ws);
        break :blk p;
    };
    errdefer new_pty.deinit(self.io);

    self.pty = new_pty;
    self.pty_writer = if (is_windows)
        new_pty.inputFile().writerStreaming(self.io, write_buf)
    else
        new_pty.pty.writerStreaming(self.io, write_buf);
    self.cmd = if (is_windows) .{
        .argv = argv_owned,
        .env_map = env,
        .working_directory = working_directory,
    } else .{
        .argv = argv_owned,
        .env_map = env,
        .pty = new_pty,
        .working_directory = working_directory,
    };
    // A new command starts with default terminal modes, like a fresh shell.
    self.mode = .{};
    try self.spawn();
}

/// resize the screen. Locks access to the back screen. Should only be called from the main thread.
/// This is safe to call every render cycle: there is a guard to only perform a resize if the size
/// of the window has changed.
pub fn resize(self: *Terminal, ws: Winsize) !void {
    // don't deinit with no size change
    if (ws.cols == self.front_screen.width and
        ws.rows == self.front_screen.height)
        return;

    self.back_mutex.lockUncancelable(self.io);
    defer self.back_mutex.unlock(self.io);

    self.front_screen.deinit(self.allocator);
    self.front_screen = try Screen.init(self.allocator, ws.cols, ws.rows);

    var new_pri = try Screen.initScrollback(self.allocator, ws.cols, ws.rows, self.scrollback_size);
    try self.back_screen_pri.copyHistoryTo(self.allocator, &new_pri);
    try self.back_screen_pri.copyViewportTo(self.allocator, &new_pri);
    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_pri = new_pri;
    self.back_screen_alt.deinit(self.allocator);
    self.back_screen_alt = try Screen.init(self.allocator, ws.cols, ws.rows);
    self.scroll_offset = @min(self.scroll_offset, self.back_screen_pri.historySize());

    try self.pty.setSize(ws);
}

pub fn draw(
    self: *Terminal,
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    focused: bool,
) !void {
    // Use app-overridden colour if set, otherwise fall back to theme colour.
    const default_fg: vaxis.Cell.Color = .{ .rgb = self.app_fg_color orelse self.fg_color };
    const default_bg: vaxis.Cell.Color = .{ .rgb = self.app_bg_color orelse self.bg_color };
    if (self.back_mutex.tryLock()) {
        defer self.back_mutex.unlock(self.io);
        // We keep this as a separate condition so we don't deadlock by obtaining the lock but not
        // having sync
        if (!self.mode.sync) {
            try self.back_screen.copyTo(allocator, &self.front_screen, self.scroll_offset);
            self.dirty = false;
        }
    }

    var row: u16 = 0;
    while (row < self.front_screen.height) : (row += 1) {
        var col: u16 = 0;
        while (col < self.front_screen.width) {
            const cell = self.front_screen.readCell(col, row) orelse continue;
            var out = cell;
            if (out.style.fg == .default) out.style.fg = default_fg;
            if (out.style.bg == .default) out.style.bg = default_bg;
            win.writeCell(col, row, out);
            col += @max(cell.char.width, 1);
        }
    }

    if (self.mode.cursor) {
        const cur_col = self.front_screen.cursor.col;
        const live_row = self.front_screen.cursor.row;
        const visual_row = @as(usize, live_row) + self.scroll_offset;
        const visible: ?u16 = if (visual_row < self.front_screen.height)
            @intCast(visual_row)
        else
            null;
        if (visible) |cur_row| {
            const shape: vaxis.Cell.CursorShape = if (focused) self.front_screen.cursor.shape else .unfocused;
            win.setCursorShape(shape);
            win.showCursor(cur_col, cur_row);
        }
    }
}

/// adjust the scrollback view
/// returns true if the offset changed
pub fn scroll(self: *Terminal, delta: i32) bool {
    if (self.back_screen != &self.back_screen_pri) return false;
    const history = self.back_screen_pri.historySize();
    const new_offset: usize = if (delta > 0)
        @min(history, self.scroll_offset + @as(usize, @intCast(delta)))
    else
        self.scroll_offset -| @as(usize, @intCast(-delta));
    if (new_offset == self.scroll_offset) return false;
    self.scroll_offset = new_offset;
    self.back_mutex.lockUncancelable(self.io);
    defer self.back_mutex.unlock(self.io);
    for (self.back_screen_pri.buf) |*cell| cell.dirty = true;
    return true;
}

/// return to the live view
pub fn scrollToBottom(self: *Terminal) void {
    if (self.scroll_offset == 0) return;
    self.scroll_offset = 0;
    self.back_mutex.lockUncancelable(self.io);
    defer self.back_mutex.unlock(self.io);
    for (self.back_screen_pri.buf) |*cell| cell.dirty = true;
}

pub fn shellState(self: *Terminal) Screen.ShellState {
    if (self.back_screen != &self.back_screen_pri)
        return .running;
    return self.back_screen_pri.shellState();
}

pub fn update(self: *Terminal, event: InputEvent) !void {
    switch (event) {
        .key_press => |k| {
            const pty_writer = self.get_pty_writer();
            defer pty_writer.flush() catch {};
            try key.encode(pty_writer, k, true, self.back_screen.csi_u_flags, self.mode.cursor_keys_app);
        },
        .mouse => |m| {
            if (self.mode.mouse == .none) return;
            // Ignore motion events unless the mode tracks them
            switch (m.type) {
                .motion => if (self.mode.mouse != .any_event) return,
                .drag => if (self.mode.mouse == .x10 or self.mode.mouse == .normal) return,
                .release => if (self.mode.mouse == .x10) return,
                .press => {},
            }
            const pty_writer = self.get_pty_writer();
            defer pty_writer.flush() catch {};
            try mouse.encode(pty_writer, m, self.mode.mouse_sgr);
        },
    }
}

/// POSIX only: returns the pty master fd for use by the pty actor read loop.
pub fn ptyFd(self: *const Terminal) std.posix.fd_t {
    if (is_windows) @compileError("ptyFd() is not available on Windows; use ptyOutputHandle()");
    return self.pty.pty.handle;
}

/// Windows only: returns the output pipe read HANDLE - transfers handle ownership
pub fn ptyOutputHandle(self: *Terminal) *anyopaque {
    if (!is_windows) @compileError("ptyOutputHandle() is not available on POSIX; use ptyFd()");
    return self.pty.outputHandle();
}

pub fn get_pty_writer(self: *Terminal) *std.Io.Writer {
    return &self.pty_writer.interface;
}

/// Process all output bytes from the pty that were just read by read loop
/// The read loop calls this after each non-blocking read. Returns true if
/// the shell has exited.
/// `parser` is owned by the read loop and persists across calls so that
/// partial escape sequences spanning multiple reads are handled correctly.
pub fn processOutput(self: *Terminal, parser: *Parser, data: []const u8, context: *Event.HandlerContext, handle_event: Event.Handler) error{
    ReadFailed,
    WriteFailed,
    OutOfMemory,
    Canceled,
    TerminalHandlerFailed,
}!enum { exited, running } {
    var fixed_reader: std.Io.Reader = .fixed(data);
    const reader: *std.Io.Reader = &fixed_reader;

    while (true) {
        const event = parser.parseReader(reader) catch |e| switch (e) {
            error.EndOfStream => return .running, // partial sequence, wait for more data
            error.ReadFailed,
            error.OutOfMemory,
            => |e_| return e_,
        };
        try self.back_mutex.lock(self.io);
        defer self.back_mutex.unlock(self.io);

        if (!self.dirty) {
            try handle_event(context, .redraw);
            self.dirty = true;
        }

        switch (event) {
            .print => |str| {
                const active_charset: Charset = if (self.charset_shifted) self.charset_g1 else self.charset_g0;
                var rest = str;
                while (rest.len > 0) {
                    if (active_charset == .ascii and rest[0] >= 0x20 and rest[0] < 0x7f) {
                        var n: usize = 1;
                        while (n < rest.len and rest[n] >= 0x20 and rest[n] < 0x7f) : (n += 1) {}
                        for (rest[0..n]) |*b| try self.back_screen.print(b[0..1], 1, self.mode.autowrap);
                        rest = rest[n..];
                        continue;
                    }
                    var iter = vaxis.unicode.graphemeIterator(rest);
                    const grapheme = iter.next() orelse break;
                    const gr = grapheme.bytes(rest);
                    // TODO: use actual instead of .unicode
                    const w = vaxis.gwidth.gwidth(gr, .unicode);
                    if (active_charset == .dec_special and gr.len == 1) {
                        const mapped = decSpecialChar(gr[0]);
                        try self.back_screen.print(mapped, @truncate(w), self.mode.autowrap);
                    } else {
                        try self.back_screen.print(gr, @truncate(w), self.mode.autowrap);
                    }
                    rest = rest[gr.len..];
                }
            },
            .c0 => |b| try self.handleC0(b, context, handle_event),
            .escape => |esc| {
                const final = esc[esc.len - 1];
                switch (final) {
                    'B', 'A' => {
                        // ESC ( B / ESC ) B  - designate US ASCII
                        // ESC ( A / ESC ) A  - designate UK ASCII (treat as ASCII)
                        if (esc.len >= 2) {
                            const slot = esc[esc.len - 2];
                            if (slot == '(')
                                self.charset_g0 = .ascii
                            else if (slot == ')')
                                self.charset_g1 = .ascii;
                        }
                    },
                    '0' => {
                        // ESC ( 0 / ESC ) 0  - designate DEC Special Character set
                        if (esc.len >= 2) {
                            const slot = esc[esc.len - 2];
                            if (slot == '(')
                                self.charset_g0 = .dec_special
                            else if (slot == ')')
                                self.charset_g1 = .dec_special;
                        }
                    },
                    // Index
                    'D' => try self.back_screen.index(),
                    // Next Line
                    'E' => {
                        try self.back_screen.index();
                        self.carriageReturn();
                    },
                    // Horizontal Tab Set
                    'H' => {
                        const already_set: bool = for (self.tab_stops.items) |ts| {
                            if (ts == self.back_screen.cursor.col) break true;
                        } else false;
                        if (already_set) continue;
                        try self.tab_stops.append(self.allocator, @truncate(self.back_screen.cursor.col));
                        std.mem.sort(u16, self.tab_stops.items, {}, std.sort.asc(u16));
                    },
                    // Reverse Index
                    'M' => try self.back_screen.reverseIndex(),
                    // DECKPAM - keypad application mode
                    '=' => self.mode.keypad_application = true,
                    // DECKPNM - keypad numeric mode
                    '>' => self.mode.keypad_application = false,
                    // ESC \ is ST (String Terminator) - a no-op at top level.
                    // Appears when ST is split from its OSC/APC across a read boundary.
                    '\\' => {},
                    // RIS - Reset to Initial State.
                    'c' => if (esc.len == 1) {
                        self.hardReset() catch |e| log.err("RIS reset failed: {}", .{e});
                        // Tell the widget the app colour overrides are gone.
                        try handle_event(context, .{ .color_change = .{ .fg = null, .bg = null, .cursor = null } });
                    } else log.debug("unhandled escape: {s}", .{esc}),
                    else => log.debug("unhandled escape: {s}", .{esc}),
                }
            },
            .ss2 => |ss2| log.debug("unhandled ss2: {c}", .{ss2}),
            .ss3 => |ss3| log.debug("unhandled ss3: {c}", .{ss3}),
            .csi => |seq| {
                switch (seq.final) {
                    // Cursor up
                    'A', 'k' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorUp(delta);
                    },
                    // Cursor Down
                    'B' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorDown(delta);
                    },
                    // Cursor Right
                    'C' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorRight(delta);
                    },
                    // Cursor Left
                    'D', 'j' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorLeft(delta);
                    },
                    // Cursor Next Line
                    'E' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorDown(delta);
                        self.carriageReturn();
                    },
                    // Cursor Previous Line
                    'F' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorUp(delta);
                        self.carriageReturn();
                    },
                    // Horizontal Position Absolute
                    'G', '`' => {
                        var iter = seq.iterator(u16);
                        const col = iter.next() orelse 1;
                        self.back_screen.cursor.col = col -| 1;
                        if (self.back_screen.cursor.col < self.back_screen.scrolling_region.left)
                            self.back_screen.cursor.col = self.back_screen.scrolling_region.left;
                        if (self.back_screen.cursor.col > self.back_screen.scrolling_region.right)
                            self.back_screen.cursor.col = self.back_screen.scrolling_region.right;
                        self.back_screen.cursor.pending_wrap = false;
                    },
                    // Cursor Absolute Position
                    // Depends on origin mode (DECOM).
                    'H', 'f' => {
                        var iter = seq.iterator(u16);
                        const row = iter.next() orelse 1;
                        const col = iter.next() orelse 1;
                        const sr = self.back_screen.scrolling_region;
                        if (self.mode.origin) {
                            self.back_screen.cursor.row = @min(sr.top +| (row -| 1), sr.bottom);
                            self.back_screen.cursor.col = @min(sr.left +| (col -| 1), sr.right);
                        } else {
                            self.back_screen.cursor.row = @min(row -| 1, self.back_screen.height -| 1);
                            self.back_screen.cursor.col = @min(col -| 1, self.back_screen.width -| 1);
                        }
                        self.back_screen.cursor.pending_wrap = false;
                    },
                    // Cursor Horizontal Tab
                    'I' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        self.horizontalTab(n);
                    },
                    // Erase In Display
                    'J' => {
                        // TODO: selective erase (private_marker == '?')
                        var iter = seq.iterator(u16);
                        const kind = iter.next() orelse 0;
                        switch (kind) {
                            0 => self.back_screen.eraseBelow(),
                            1 => self.back_screen.eraseAbove(),
                            2 => self.back_screen.eraseAll(),
                            3 => {},
                            else => {},
                        }
                    },
                    // Erase in Line
                    'K' => {
                        // TODO: selective erase (private_marker == '?')
                        var iter = seq.iterator(u8);
                        const ps = iter.next() orelse 0;
                        switch (ps) {
                            0 => self.back_screen.eraseRight(),
                            1 => self.back_screen.eraseLeft(),
                            2 => self.back_screen.eraseLine(),
                            else => continue,
                        }
                    },
                    // Insert Lines
                    'L' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.insertLine(n);
                    },
                    // Delete Lines
                    'M' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.deleteLine(n);
                    },
                    // Delete Character
                    'P' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.deleteCharacters(n);
                    },
                    // Scroll Up
                    'S' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const cur_row = self.back_screen.cursor.row;
                        const cur_col = self.back_screen.cursor.col;
                        const wrap = self.back_screen.cursor.pending_wrap;
                        defer {
                            self.back_screen.cursor.row = cur_row;
                            self.back_screen.cursor.col = cur_col;
                            self.back_screen.cursor.pending_wrap = wrap;
                        }
                        self.back_screen.cursor.col = self.back_screen.scrolling_region.left;
                        self.back_screen.cursor.row = self.back_screen.scrolling_region.top;
                        try self.back_screen.deleteLine(n);
                    },
                    // Scroll Down
                    'T' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.scrollDown(n);
                    },
                    // Tab Control
                    'W' => {
                        if (seq.private_marker) |pm| {
                            if (pm != '?') continue;
                            var iter = seq.iterator(u16);
                            const n = iter.next() orelse continue;
                            if (n != 5) continue;
                            try self.resetTabStops();
                        }
                    },
                    'X' => {
                        self.back_screen.cursor.pending_wrap = false;
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const start = self.back_screen.cursor.row * self.back_screen.width + self.back_screen.cursor.col;
                        const end = @max(
                            self.back_screen.cursor.row * self.back_screen.width + self.back_screen.width,
                            n,
                            1, // In case n == 0
                        );
                        var i: usize = start;
                        while (i < end) : (i += 1) {
                            self.back_screen.buf[i].erase(self.allocator, self.back_screen.cursor.style.bg);
                        }
                    },
                    'Z' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        self.horizontalBackTab(n);
                    },
                    // Cursor Horizontal Position Relative
                    'a' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        self.back_screen.cursor.pending_wrap = false;
                        const max_end = if (self.mode.origin)
                            self.back_screen.scrolling_region.right
                        else
                            self.back_screen.width - 1;
                        self.back_screen.cursor.col = @min(
                            self.back_screen.cursor.col + max_end,
                            self.back_screen.cursor.col + n,
                        );
                    },
                    // Repeat Previous Character
                    'b' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        // TODO: maybe not .unicode
                        const w = vaxis.gwidth.gwidth(self.last_printed, .unicode);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            try self.back_screen.print(self.last_printed, @truncate(w), self.mode.autowrap);
                        }
                    },
                    // Device Attributes
                    'c' => {
                        const pty_writer = self.get_pty_writer();
                        defer pty_writer.flush() catch {};
                        if (seq.private_marker) |pm| {
                            switch (pm) {
                                // Secondary
                                '>' => try pty_writer.writeAll("\x1B[>1;69;0c"),
                                '=' => try pty_writer.writeAll("\x1B[=0000c"),
                                else => log.debug("unhandled CSI: {f}", .{seq}),
                            }
                        } else {
                            // Primary
                            try pty_writer.writeAll("\x1B[?62;22c");
                        }
                    },
                    // Cursor Vertical Position Absolute
                    'd' => {
                        self.back_screen.cursor.pending_wrap = false;
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const max = if (self.mode.origin)
                            self.back_screen.scrolling_region.bottom
                        else
                            self.back_screen.height -| 1;
                        self.back_screen.cursor.pending_wrap = false;
                        self.back_screen.cursor.row = @min(
                            max,
                            n -| 1,
                        );
                    },
                    // Cursor Vertical Position Absolute
                    'e' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        self.back_screen.cursor.pending_wrap = false;
                        self.back_screen.cursor.row = @min(
                            self.back_screen.width -| 1,
                            n -| 1,
                        );
                    },
                    // Tab Clear
                    'g' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 0;
                        switch (n) {
                            0 => {
                                const current = try self.tab_stops.toOwnedSlice(self.allocator);
                                defer self.allocator.free(current);
                                self.tab_stops.clearRetainingCapacity();
                                for (current) |stop| {
                                    if (stop == self.back_screen.cursor.col) continue;
                                    try self.tab_stops.append(self.allocator, stop);
                                }
                            },
                            3 => self.tab_stops.clearAndFree(self.allocator),
                            else => log.debug("unhandled CSI: {f}", .{seq}),
                        }
                    },
                    'h', 'l' => {
                        var iter = seq.iterator(u16);
                        const mode = iter.next() orelse continue;
                        // There is only one collision (mode = 4), and we don't support the private
                        // version of it
                        if (seq.private_marker != null and mode == 4) continue;
                        self.setMode(mode, seq.final == 'h');
                    },
                    'm' => {
                        if (seq.intermediate == null and seq.private_marker == null) {
                            self.back_screen.sgr(seq);
                        }
                        // TODO: private marker and intermediates
                    },
                    'n' => {
                        var iter = seq.iterator(u16);
                        const ps = iter.next() orelse 0;
                        if (seq.intermediate == null and seq.private_marker == null) {
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            switch (ps) {
                                5 => try pty_writer.writeAll("\x1b[0n"),
                                // CPR - Cursor Position Report
                                // Respects origin mode (DECOM)
                                6 => {
                                    const cur = self.back_screen.cursor;
                                    const sr = self.back_screen.scrolling_region;
                                    const row = if (self.mode.origin) cur.row -| sr.top else cur.row;
                                    const col = if (self.mode.origin) cur.col -| sr.left else cur.col;
                                    try pty_writer.print("\x1b[{d};{d}R", .{ row + 1, col + 1 });
                                },
                                else => log.debug("unhandled CSI: {f}", .{seq}),
                            }
                        }
                    },
                    'p' => {
                        if (seq.intermediate) |int| {
                            switch (int) {
                                // DECRQM - Request Mode.
                                // `CSI Ps $ p` is ANSI. `CSI ? Ps $ p` is DEC private.
                                '$' => {
                                    const private = switch (seq.private_marker orelse 0) {
                                        0 => false,
                                        '?' => true,
                                        else => {
                                            log.debug("unhandled CSI: {f}", .{seq});
                                            continue;
                                        },
                                    };
                                    var iter = seq.iterator(u16);
                                    const ps = iter.next() orelse 0;
                                    const state = self.queryMode(ps, private);
                                    if (state == .not_recognized)
                                        log.debug("DECRQM for unimplemented mode: {s}{d}", .{
                                            if (private) "?" else "",
                                            ps,
                                        });
                                    const pty_writer = self.get_pty_writer();
                                    defer pty_writer.flush() catch {};
                                    try pty_writer.print("\x1b[{s}{d};{d}$y", .{
                                        if (private) "?" else "",
                                        ps,
                                        @intFromEnum(state),
                                    });
                                },
                                // DECSTR - Soft Terminal Reset (CSI ! p)
                                '!' => self.softReset(),
                                else => log.debug("unhandled CSI: {f}", .{seq}),
                            }
                        }
                    },
                    'q' => {
                        if (seq.intermediate) |int| {
                            switch (int) {
                                ' ' => {
                                    var iter = seq.iterator(u8);
                                    const shape = iter.next() orelse 0;
                                    self.back_screen.cursor.shape = @enumFromInt(shape);
                                },
                                else => {},
                            }
                        }
                        if (seq.private_marker) |pm| {
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            switch (pm) {
                                // XTVERSION
                                '>' => try pty_writer.print(
                                    "\x1bP>|libvaxis {s}\x1B\\",
                                    .{"dev"},
                                ),
                                else => log.debug("unhandled CSI: {f}", .{seq}),
                            }
                        }
                    },
                    'r' => {
                        if (seq.intermediate) |_| {
                            // TODO: XTRESTORE
                            continue;
                        }
                        if (seq.private_marker) |_| {
                            // TODO: DECCARA
                            continue;
                        }
                        // DECSTBM
                        var iter = seq.iterator(u16);
                        const top = iter.next() orelse 1;
                        const bottom = iter.next() orelse self.back_screen.height;
                        self.back_screen.scrolling_region.top = top -| 1;
                        self.back_screen.scrolling_region.bottom = bottom -| 1;
                        self.homeCursor();
                    },
                    // CSI ? u - query Kitty keyboard protocol flags; respond with 0 (not enabled)
                    // Kitty keyboard protocol
                    'u' => switch (seq.private_marker orelse 0) {
                        // CSI ? u - query flags; respond with 0 (not enabled)
                        '?' => {
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            try pty_writer.writeAll("\x1B[?0u");
                        },
                        // CSI > Flags u - push flags onto stack; silently accept
                        '>' => {},
                        // CSI = Flags u - set flags with mode; silently accept
                        '=' => {},
                        // CSI < u - pop flags from stack; silently accept
                        '<' => {},
                        else => log.debug("unhandled CSI: {f}", .{seq}),
                    },
                    // CSI Ps t - XTWINOPS window operations; silently ignore
                    't' => {},
                    else => log.debug("unhandled CSI: {f}", .{seq}),
                }
            },
            .osc => |osc| {
                const sep = std.mem.indexOfScalar(u8, osc, ';');
                const ps = std.fmt.parseUnsigned(u8, osc[0 .. sep orelse osc.len], 10) catch {
                    log.debug("unhandled osc: {s}", .{osc});
                    continue;
                };
                const rest = if (sep) |s| osc[s + 1 ..] else "";
                switch (ps) {
                    // OSC 0 - set icon name and window title
                    // OSC 2 - set window title
                    // We have no separate icon name, so both just set the title.
                    0, 2 => {
                        self.title.clearRetainingCapacity();
                        try self.title.appendSlice(self.allocator, rest);
                        try handle_event(context, .{ .title_change = self.title.items });
                    },
                    7 => {
                        // OSC 7 ; <scheme> <hostname> <path>
                        // Supported schemes:
                        //   file://hostname/path  (IETF RFC 8089, used by most shells)
                        //   kitty-shell-cwd://hostname/path  (Kitty terminal extension)
                        // In both cases we want everything from the first '/' that
                        // begins the absolute path, percent-decoding as we go.
                        const after_semi = rest;
                        const schemes = [_][]const u8{ "file://", "kitty-shell-cwd://" };
                        const after_scheme = for (schemes) |scheme| {
                            if (std.mem.startsWith(u8, after_semi, scheme))
                                break after_semi[scheme.len..];
                        } else {
                            log.debug("unknown OSC 7 format: {s}", .{osc});
                            continue;
                        };
                        // Skip the hostname (everything up to the next '/').
                        const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse {
                            log.debug("unknown OSC 7 format: {s}", .{osc});
                            continue;
                        };
                        const enc = after_scheme[path_start..];
                        self.working_directory.clearRetainingCapacity();
                        var i: usize = 0;
                        while (i < enc.len) : (i += 1) {
                            const b = if (enc[i] == '%') blk: {
                                defer i += 2;
                                break :blk std.fmt.parseUnsigned(u8, enc[i + 1 .. i + 3], 16) catch |e| switch (e) {
                                    error.Overflow, error.InvalidCharacter => {
                                        log.debug("unknown OSC 7 format: {s}", .{osc});
                                        continue;
                                    },
                                };
                            } else enc[i];
                            try self.working_directory.append(self.allocator, b);
                        }
                        try handle_event(context, .{ .pwd_change = self.working_directory.items });
                    },
                    // OSC 8 ; <params> ; <uri>
                    // Hyperlink. Stores the URI on the back-screen cursor so
                    // subsequently written cells inherit it. An empty URI
                    // closes the active hyperlink. The optional `id=...`
                    // param (in colon-separated `key=value` pairs) groups
                    // disjoint runs into one logical hyperlink.
                    8 => {
                        const after_semi = rest;
                        const second_semi = std.mem.indexOfScalar(u8, after_semi, ';') orelse {
                            log.debug("unhandled osc: {s}", .{osc});
                            continue;
                        };
                        const params = after_semi[0..second_semi];
                        const uri = after_semi[second_semi + 1 ..];
                        self.back_screen.cursor.uri.clearRetainingCapacity();
                        self.back_screen.cursor.uri_id.clearRetainingCapacity();
                        if (uri.len > 0) {
                            try self.back_screen.cursor.uri.appendSlice(self.allocator, uri);
                            var it = std.mem.tokenizeScalar(u8, params, ':');
                            while (it.next()) |kv| {
                                if (std.mem.startsWith(u8, kv, "id=")) {
                                    try self.back_screen.cursor.uri_id.appendSlice(self.allocator, kv[3..]);
                                    break;
                                }
                            }
                        }
                    },
                    // OSC 9 ; 4 ; <state> ; <progress>
                    // Progress notification. Silently ignored; we have no progress UI.
                    9 => {},
                    // OSC 4 - set or query a palette colour.
                    // Payload is one or more `<index> ; <spec|?>` pairs. A "?"
                    // spec is a query, answered with the current entry; any
                    // other spec sets the entry.
                    4 => {
                        var it = std.mem.splitScalar(u8, rest, ';');
                        while (it.next()) |idx_str| {
                            const spec = it.next() orelse break;
                            const idx = std.fmt.parseUnsigned(u8, idx_str, 10) catch continue;
                            if (std.mem.eql(u8, spec, "?")) {
                                const c = self.palette[idx];
                                const pty_writer = self.get_pty_writer();
                                defer pty_writer.flush() catch {};
                                try pty_writer.print(
                                    "\x1B]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1B\\",
                                    .{ idx, c[0], c[0], c[1], c[1], c[2], c[2] },
                                );
                            } else if (parseOscRgb(spec)) |rgb| {
                                self.palette[idx] = rgb;
                                self.palette_modified = true;
                            }
                        }
                    },
                    // OSC 104 - reset entire palette, or individual colours.
                    104 => {
                        if (rest.len == 0) {
                            self.palette = self.palette_default;
                            self.palette_modified = false;
                        } else {
                            var it = std.mem.splitScalar(u8, rest, ';');
                            while (it.next()) |idx_str| {
                                const idx = std.fmt.parseUnsigned(u8, idx_str, 10) catch continue;
                                self.palette[idx] = self.palette_default[idx];
                            }
                        }
                    },
                    // OSC 10 - foreground colour set or query
                    10 => {
                        const val = rest;
                        if (std.mem.eql(u8, val, "?")) {
                            const c = self.app_fg_color orelse self.fg_color;
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            try pty_writer.print(
                                "\x1B]10;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1B\\",
                                .{ c[0], c[0], c[1], c[1], c[2], c[2] },
                            );
                        } else {
                            self.app_fg_color = parseOscRgb(val);
                            try handle_event(context, .{ .color_change = .{
                                .fg = self.app_fg_color,
                                .bg = self.app_bg_color,
                                .cursor = self.app_cursor_color,
                            } });
                        }
                    },
                    // OSC 11 - background colour set or query
                    11 => {
                        const val = rest;
                        if (std.mem.eql(u8, val, "?")) {
                            const c = self.app_bg_color orelse self.bg_color;
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            try pty_writer.print(
                                "\x1B]11;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1B\\",
                                .{ c[0], c[0], c[1], c[1], c[2], c[2] },
                            );
                        } else {
                            self.app_bg_color = parseOscRgb(val);
                            try handle_event(context, .{ .color_change = .{
                                .fg = self.app_fg_color,
                                .bg = self.app_bg_color,
                                .cursor = self.app_cursor_color,
                            } });
                        }
                    },
                    // OSC 12 - cursor colour set or query
                    12 => {
                        const val = rest;
                        if (std.mem.eql(u8, val, "?")) {
                            if (self.app_cursor_color) |c| {
                                const pty_writer = self.get_pty_writer();
                                defer pty_writer.flush() catch {};
                                try pty_writer.print(
                                    "\x1B]12;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1B\\",
                                    .{ c[0], c[0], c[1], c[1], c[2], c[2] },
                                );
                            }
                        } else {
                            self.app_cursor_color = parseOscRgb(val);
                            try handle_event(context, .{ .color_change = .{
                                .fg = self.app_fg_color,
                                .bg = self.app_bg_color,
                                .cursor = self.app_cursor_color,
                            } });
                        }
                    },
                    // OSC 52 - clipboard access
                    // Format: 52;<targets>;<base64data|?>
                    52 => try self.handleOsc52(rest, context, handle_event),
                    // OSC 110/111/112 - reset fg/bg/cursor colour to default
                    110 => {
                        self.app_fg_color = null;
                        try handle_event(context, .{ .color_change = .{
                            .fg = null,
                            .bg = self.app_bg_color,
                            .cursor = self.app_cursor_color,
                        } });
                    },
                    111 => {
                        self.app_bg_color = null;
                        try handle_event(context, .{ .color_change = .{
                            .fg = self.app_fg_color,
                            .bg = null,
                            .cursor = self.app_cursor_color,
                        } });
                    },
                    112 => {
                        self.app_cursor_color = null;
                        try handle_event(context, .{ .color_change = .{
                            .fg = self.app_fg_color,
                            .bg = self.app_bg_color,
                            .cursor = null,
                        } });
                    },
                    // OSC 133 ; <kind> [; <param> ...]
                    // Semantic prompt marks (FinalTerm/iTerm2 conventions).
                    // Only tracked on the primary back screen — alt-screen
                    // apps don't emit shell prompt structure.
                    133 => if (self.back_screen == &self.back_screen_pri) {
                        const after_semi = rest;
                        if (after_semi.len > 0) {
                            const kind: ?Screen.PromptMarkKind = switch (after_semi[0]) {
                                'A' => .prompt_start,
                                'B' => .input_start,
                                'C' => .output_start,
                                'D' => .output_end,
                                else => null,
                            };
                            if (kind) |k| {
                                var exit_code: ?i32 = null;
                                var click_events: bool = false;
                                var secondary: bool = false;
                                if (after_semi.len > 1 and after_semi[1] == ';') {
                                    var it = std.mem.tokenizeScalar(u8, after_semi[2..], ';');
                                    while (it.next()) |tok| {
                                        if (k == .output_end and exit_code == null) {
                                            if (std.fmt.parseInt(i32, tok, 10)) |v| {
                                                exit_code = v;
                                                continue;
                                            } else |_| {}
                                        }
                                        // k=s marks a secondary (PS2 continuation) prompt
                                        if (std.mem.eql(u8, tok, "k=s"))
                                            secondary = true;
                                        if (std.mem.startsWith(u8, tok, "click_events=") and
                                            std.mem.eql(u8, tok["click_events=".len..], "1"))
                                            click_events = true;
                                    }
                                }
                                if (k == .prompt_start and secondary) continue;
                                if (self.back_screen_pri.addPromptMark(self.allocator, k, exit_code, click_events)) {
                                    try handle_event(context, .{
                                        .shell_state_change = self.back_screen_pri.shellState(),
                                    });
                                } else |e| log.warn("addPromptMark failed: {s}", .{@errorName(e)});
                            } else switch (after_semi[0]) {
                                // OSC 133 ; k ; ... - kitty shell-integration prompt-kind markers
                                'k' => {},
                                else => log.debug("unhandled osc: {s}", .{osc}),
                            }
                        }
                    },
                    else => log.debug("unhandled osc: {s}", .{osc}),
                }
            },
            .apc => |apc| log.debug("unhandled apc: {s}", .{apc}),
        }
    }
    return false;
}

inline fn handleC0(self: *Terminal, b: ansi.C0, context: anytype, handle_event: anytype) !void {
    switch (b) {
        .NUL, .SOH, .STX => {},
        .EOT => {},
        .ENQ => {},
        .BEL => try handle_event(context, .bell),
        .BS => self.back_screen.cursorLeft(1),
        .HT => self.horizontalTab(1),
        .LF, .VT, .FF => try self.back_screen.index(),
        .CR => self.carriageReturn(),
        .SO => self.charset_shifted = true, // Shift Out: activate G1
        .SI => self.charset_shifted = false, // Shift In: activate G0 (default)
        else => log.warn("unhandled C0: 0x{x}", .{@intFromEnum(b)}),
    }
}

fn resetTabStops(self: *Terminal) !void {
    self.tab_stops.clearRetainingCapacity();
    var col: u16 = 0;
    while (col < self.back_screen.width) : (col += 8) {
        try self.tab_stops.append(self.allocator, col);
    }
}

/// RIS (ESC c) - Reset to Initial State.
fn hardReset(self: *Terminal) !void {
    const w = self.front_screen.width;
    const h = self.front_screen.height;

    var new_pri = try Screen.initScrollback(self.allocator, w, h, self.scrollback_size);
    errdefer new_pri.deinit(self.allocator);
    const new_alt = try Screen.init(self.allocator, w, h);
    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_pri = new_pri;
    self.back_screen_alt.deinit(self.allocator);
    self.back_screen_alt = new_alt;
    self.back_screen = &self.back_screen_pri;
    self.scroll_offset = 0;

    self.mode = .{};
    self.charset_g0 = .ascii;
    self.charset_g1 = .ascii;
    self.charset_shifted = false;
    try self.resetTabStops();

    self.palette = self.palette_default;
    self.palette_modified = false;
    self.app_fg_color = null;
    self.app_bg_color = null;
    self.app_cursor_color = null;
    self.last_printed = "";

    self.dirty = true;
}

/// DECSTR (CSI ! p) - Soft Terminal Reset.
fn softReset(self: *Terminal) void {
    self.mode.cursor_keys_app = false; // DECCKM -> normal
    self.mode.origin = false; // DECOM -> absolute
    self.mode.autowrap = true; // DECAWM -> flow power-on default
    self.mode.cursor = true; // DECTCEM -> visible
    self.mode.keypad_application = false; // DECNKM -> numeric
    self.charset_g0 = .ascii;
    self.charset_g1 = .ascii;
    self.charset_shifted = false;
    self.back_screen.cursor.visible = true;
    self.back_screen.cursor.style = .{}; // SGR -> default
    self.back_screen.cursor.pending_wrap = false;
    self.back_screen.scrolling_region = .{
        .top = 0,
        .bottom = self.back_screen.height -| 1,
        .left = 0,
        .right = self.back_screen.width -| 1,
    };
}

/// The state of a mode as reported by DECRPM in response to DECRQM.
pub const ModeState = enum(u8) {
    not_recognized = 0,
    set = 1,
    reset = 2,
    permanently_set = 3,
    permanently_reset = 4,
};

fn modeState(val: bool) ModeState {
    return if (val) .set else .reset;
}

/// DECRQM - report the current state of `mode`.
pub fn queryMode(self: *Terminal, mode: u16, private: bool) ModeState {
    // We implement no ANSI modes yet (IRM, LNM, ...).
    if (!private) return .not_recognized;
    return switch (mode) {
        1 => modeState(self.mode.cursor_keys_app), // DECCKM
        6 => modeState(self.mode.origin), // DECOM
        7 => modeState(self.mode.autowrap), // DECAWM
        9 => modeState(self.mode.mouse == .x10), // X10 mouse
        25 => modeState(self.mode.cursor), // DECTCEM
        1000 => modeState(self.mode.mouse == .normal),
        1002 => modeState(self.mode.mouse == .button_event),
        1003 => modeState(self.mode.mouse == .any_event),
        1006 => modeState(self.mode.mouse_sgr),
        1049 => modeState(self.back_screen == &self.back_screen_alt),
        2004 => modeState(self.mode.bracketed_paste),
        2026 => modeState(self.mode.sync),
        1005, 1015 => .permanently_reset,
        else => .not_recognized,
    };
}

pub fn setMode(self: *Terminal, mode: u16, val: bool) void {
    switch (mode) {
        1 => self.mode.cursor_keys_app = val,
        6 => { // Setting or resetting origin mode also homes the cursor
            self.mode.origin = val;
            self.homeCursor();
        },
        7 => self.mode.autowrap = val,
        9 => self.mode.mouse = if (val) .x10 else .none,
        1000 => self.mode.mouse = if (val) .normal else .none,
        1002 => self.mode.mouse = if (val) .button_event else .none,
        1003 => self.mode.mouse = if (val) .any_event else .none,
        1005 => {}, // UTF-8 mouse encoding - we use SGR instead, ignore
        1006 => self.mode.mouse_sgr = val,
        1015 => {}, // URXVT mouse encoding - we use SGR instead, ignore
        25 => self.mode.cursor = val,
        1049 => {
            if (val)
                self.back_screen = &self.back_screen_alt
            else
                self.back_screen = &self.back_screen_pri;
            var i: usize = 0;
            while (i < self.back_screen.buf.len) : (i += 1) {
                self.back_screen.buf[i].dirty = true;
            }
        },
        2004 => self.mode.bracketed_paste = val,
        2026 => self.mode.sync = val,
        else => return,
    }
}

pub fn paste(self: *Terminal, text: []const u8) void {
    const pty_writer = self.get_pty_writer();
    defer pty_writer.flush() catch {};
    if (self.mode.bracketed_paste) pty_writer.writeAll("\x1b[200~") catch {};
    pty_writer.writeAll(text) catch {};
    if (self.mode.bracketed_paste) pty_writer.writeAll("\x1b[201~") catch {};
}

pub fn homeCursor(self: *Terminal) void {
    self.back_screen.cursor.pending_wrap = false;
    if (self.mode.origin) {
        self.back_screen.cursor.col = self.back_screen.scrolling_region.left;
        self.back_screen.cursor.row = self.back_screen.scrolling_region.top;
    } else {
        self.back_screen.cursor.col = 0;
        self.back_screen.cursor.row = 0;
    }
}

pub fn carriageReturn(self: *Terminal) void {
    self.back_screen.cursor.pending_wrap = false;
    self.back_screen.cursor.col = if (self.mode.origin)
        self.back_screen.scrolling_region.left
    else if (self.back_screen.cursor.col >= self.back_screen.scrolling_region.left)
        self.back_screen.scrolling_region.left
    else
        0;
}

pub fn horizontalTab(self: *Terminal, n: usize) void {
    // Get the current cursor position
    const col = self.back_screen.cursor.col;

    // Find desired final position
    var i: usize = 0;
    const final = for (self.tab_stops.items) |ts| {
        if (ts <= col) continue;
        i += 1;
        if (i == n) break ts;
    } else self.back_screen.width - 1;

    // Move right the delta
    self.back_screen.cursorRight(final -| col);
}

pub fn horizontalBackTab(self: *Terminal, n: usize) void {
    // Get the current cursor position
    const col = self.back_screen.cursor.col;

    // Find the index of the next backtab
    const idx = for (self.tab_stops.items, 0..) |ts, i| {
        if (ts <= col) continue;
        break i;
    } else self.tab_stops.items.len - 1;

    const final = if (self.mode.origin)
        @max(self.tab_stops.items[idx -| (n -| 1)], self.back_screen.scrolling_region.left)
    else
        self.tab_stops.items[idx -| (n -| 1)];

    // Move left the delta
    self.back_screen.cursorLeft(final - col);
}

const xterm_palette_default: [256][3]u8 = blk: {
    var p: [256][3]u8 = undefined;
    for (xterm.colors, 0..) |c, i| {
        p[i] = .{ @intCast(c >> 16), @intCast((c >> 8) & 0xff), @intCast(c & 0xff) };
    }
    break :blk p;
};

/// Parse an X11 rgb: colour spec of the form "rgb:RRRR/GGGG/BBBB".
/// Returns the high byte of each 16-bit channel as [3]u8, or null on failure.
fn parseOscRgb(spec: []const u8) ?[3]u8 {
    // Accept both "rgb:RRRR/GGGG/BBBB" (16-bit) and "#RRGGBB" (8-bit) formats.
    if (std.mem.startsWith(u8, spec, "rgb:")) {
        const rest = spec[4..];
        var it = std.mem.splitScalar(u8, rest, '/');
        const rs = it.next() orelse return null;
        const gs = it.next() orelse return null;
        const bs = it.next() orelse return null;
        // Take the high byte only (first two hex digits).
        const r = std.fmt.parseUnsigned(u8, rs[0..@min(2, rs.len)], 16) catch return null;
        const g = std.fmt.parseUnsigned(u8, gs[0..@min(2, gs.len)], 16) catch return null;
        const b = std.fmt.parseUnsigned(u8, bs[0..@min(2, bs.len)], 16) catch return null;
        return .{ r, g, b };
    } else if (spec.len == 7 and spec[0] == '#') {
        const r = std.fmt.parseUnsigned(u8, spec[1..3], 16) catch return null;
        const g = std.fmt.parseUnsigned(u8, spec[3..5], 16) catch return null;
        const b = std.fmt.parseUnsigned(u8, spec[5..7], 16) catch return null;
        return .{ r, g, b };
    }
    return null;
}

/// Handle OSC 52 clipboard read/write from the terminal application.
fn handleOsc52(self: *Terminal, rest: []const u8, context: anytype, handle_event: anytype) !void {
    // rest is "<targets>;<base64data|?>"
    const second_semi = std.mem.indexOfScalar(u8, rest, ';') orelse return;
    const data = rest[second_semi + 1 ..];
    if (std.mem.eql(u8, data, "?")) {
        try handle_event(context, .osc_paste_request);
    } else {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data) catch return;
        self.osc52_buf.clearRetainingCapacity();
        self.osc52_buf.ensureTotalCapacity(self.allocator, decoded_len) catch return;
        self.osc52_buf.items.len = decoded_len;
        std.base64.standard.Decoder.decode(self.osc52_buf.items, data) catch return;
        try handle_event(context, .{ .osc_copy = self.osc52_buf.items });
    }
}

/// Send clipboard text back to the terminal application in response to OSC 52 paste request.
pub fn respondOsc52Paste(self: *Terminal, text: []const u8) void {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(text.len);
    const encoded_buf = self.allocator.alloc(u8, encoded_len) catch return;
    defer self.allocator.free(encoded_buf);
    const encoded = encoder.encode(encoded_buf, text);
    const pty_writer = self.get_pty_writer();
    defer pty_writer.flush() catch {};
    pty_writer.print("\x1B]52;c;{s}\x1B\\", .{encoded}) catch {};
}

/// Translate a DEC Special Character and Line Drawing Set codepoint (0x60–0x7E)
/// to its UTF-8 Unicode equivalent. Characters outside that range are returned
/// as a single-byte ASCII string unchanged.
fn decSpecialChar(c: u8) []const u8 {
    return switch (c) {
        '`' => "◆", // 0x60 diamond
        'a' => "▒", // 0x61 checker board
        'b' => "\t", // 0x62 HT (pass through)
        'c' => "\x0c", // 0x63 FF (pass through)
        'd' => "\r", // 0x64 CR (pass through)
        'e' => "\x0a", // 0x65 LF (pass through)
        'f' => "°", // 0x66 degree symbol
        'g' => "±", // 0x67 plus/minus
        'h' => "\n", // 0x68 NL (pass through)
        'i' => "\x0b", // 0x69 VT (pass through)
        'j' => "┘", // 0x6a lower-right corner
        'k' => "┐", // 0x6b upper-right corner
        'l' => "┌", // 0x6c upper-left corner
        'm' => "└", // 0x6d lower-left corner
        'n' => "┼", // 0x6e crossing lines
        'o' => "⎺", // 0x6f upper horizontal line
        'p' => "⎻", // 0x70 middle horizontal line (upper)
        'q' => "─", // 0x71 horizontal line (middle)
        'r' => "⎼", // 0x72 middle horizontal line (lower)
        's' => "⎽", // 0x73 lower horizontal line
        't' => "├", // 0x74 left tee
        'u' => "┤", // 0x75 right tee
        'v' => "┴", // 0x76 bottom tee
        'w' => "┬", // 0x77 top tee
        'x' => "│", // 0x78 vertical line
        'y' => "≤", // 0x79 less than or equal
        'z' => "≥", // 0x7a greater than or equal
        '{' => "π", // 0x7b pi
        '|' => "≠", // 0x7c not equal
        '}' => "£", // 0x7d pound sterling
        '~' => "·", // 0x7e middle dot
        else => &[_]u8{c},
    };
}
