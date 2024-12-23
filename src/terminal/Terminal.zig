//! A virtual terminal widget
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
pub const Command = @import("Command.zig");
const Parser = @import("Parser.zig");
const Pty = @import("Pty.zig");
const vaxis = @import("../../main.zig");
const Winsize = vaxis.Winsize;
const Screen = @import("Screen.zig");
const DisplayWidth = @import("DisplayWidth");
const Key = vaxis.Key;
const Queue = vaxis.Queue(Event, 16);
const code_point = @import("code_point");
const key = @import("key.zig");

pub const Event = union(enum) {
    exited,
    redraw,
    bell,
    title_change: []const u8,
    pwd_change: []const u8,
};

const grapheme = @import("grapheme");

const posix = std.posix;

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
};

pub const InputEvent = union(enum) {
    key_press: vaxis.Key,
};

pub var global_vt_mutex: std.Thread.Mutex = .{};
pub var global_vts: ?std.AutoHashMap(i32, *Terminal) = null;
pub var global_sigchild_installed: bool = false;

allocator: std.mem.Allocator,
scrollback_size: u16,

pty: Pty,
cmd: Command,
thread: ?std.Thread = null,

/// the screen we draw from
front_screen: Screen,
front_mutex: std.Thread.Mutex = .{},

/// the back screens
back_screen: *Screen = undefined,
back_screen_pri: Screen,
back_screen_alt: Screen,
// only applies to primary screen
scroll_offset: usize = 0,
back_mutex: std.Thread.Mutex = .{},
// dirty is protected by back_mutex. Only access this field when you hold that mutex
dirty: bool = false,

unicode: *const vaxis.Unicode,
should_quit: bool = false,

mode: Mode = .{},

tab_stops: std.ArrayList(u16),
title: std.ArrayList(u8),
working_directory: std.ArrayList(u8),

last_printed: []const u8 = "",

event_queue: Queue = .{},

/// initialize a Terminal. This sets the size of the underlying pty and allocates the sizes of the
/// screen
pub fn init(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env: *const std.process.EnvMap,
    unicode: *const vaxis.Unicode,
    opts: Options,
) !Terminal {
    // Verify we have an absolute path
    if (opts.initial_working_directory) |pwd| {
        if (!std.fs.path.isAbsolute(pwd)) return error.InvalidWorkingDirectory;
    }
    const pty = try Pty.init();
    try pty.setSize(opts.winsize);
    const cmd: Command = .{
        .argv = argv,
        .env_map = env,
        .pty = pty,
        .working_directory = opts.initial_working_directory,
    };
    var tabs = try std.ArrayList(u16).initCapacity(allocator, opts.winsize.cols / 8);
    var col: u16 = 0;
    while (col < opts.winsize.cols) : (col += 8) {
        try tabs.append(col);
    }
    return .{
        .allocator = allocator,
        .pty = pty,
        .cmd = cmd,
        .scrollback_size = opts.scrollback_size,
        .front_screen = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows),
        .back_screen_pri = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows + opts.scrollback_size),
        .back_screen_alt = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows),
        .unicode = unicode,
        .tab_stops = tabs,
        .title = std.ArrayList(u8).init(allocator),
        .working_directory = std.ArrayList(u8).init(allocator),
    };
}

/// release all resources of the Terminal
pub fn deinit(self: *Terminal) void {
    self.should_quit = true;

    pid: {
        global_vt_mutex.lock();
        defer global_vt_mutex.unlock();
        var vts = global_vts orelse break :pid;
        if (self.cmd.pid) |pid|
            _ = vts.remove(pid);
        if (vts.count() == 0) {
            vts.deinit();
            global_vts = null;
        }
    }
    self.cmd.kill();
    if (self.thread) |thread| {
        // write an EOT into the tty to trigger a read on our thread
        const EOT = "\x04";
        _ = std.posix.write(self.pty.tty, EOT) catch {};
        thread.join();
        self.thread = null;
    }
    self.pty.deinit();
    self.front_screen.deinit(self.allocator);
    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_alt.deinit(self.allocator);
    self.tab_stops.deinit();
    self.title.deinit();
    self.working_directory.deinit();
}

pub fn spawn(self: *Terminal) !void {
    if (self.thread != null) return;
    self.back_screen = &self.back_screen_pri;

    try self.cmd.spawn(self.allocator);

    self.working_directory.clearRetainingCapacity();
    if (self.cmd.working_directory) |pwd| {
        try self.working_directory.appendSlice(pwd);
    } else {
        const pwd = std.fs.cwd();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const out_path = try std.os.getFdPath(pwd.fd, &buffer);
        try self.working_directory.appendSlice(out_path);
    }

    {
        // add to our global list
        global_vt_mutex.lock();
        defer global_vt_mutex.unlock();
        if (global_vts == null)
            global_vts = std.AutoHashMap(i32, *Terminal).init(self.allocator);
        if (self.cmd.pid) |pid|
            try global_vts.?.put(pid, self);
    }

    self.thread = try std.Thread.spawn(.{}, Terminal.run, .{self});
}

/// resize the screen. Locks access to the back screen. Should only be called from the main thread.
/// This is safe to call every render cycle: there is a guard to only perform a resize if the size
/// of the window has changed.
pub fn resize(self: *Terminal, ws: Winsize) !void {
    // don't deinit with no size change
    if (ws.cols == self.front_screen.width and
        ws.rows == self.front_screen.height)
        return;

    self.back_mutex.lock();
    defer self.back_mutex.unlock();

    self.front_screen.deinit(self.allocator);
    self.front_screen = try Screen.init(self.allocator, ws.cols, ws.rows);

    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_alt.deinit(self.allocator);
    self.back_screen_pri = try Screen.init(self.allocator, ws.cols, ws.rows + self.scrollback_size);
    self.back_screen_alt = try Screen.init(self.allocator, ws.cols, ws.rows);

    try self.pty.setSize(ws);
}

pub fn draw(self: *Terminal, win: vaxis.Window) !void {
    if (self.back_mutex.tryLock()) {
        defer self.back_mutex.unlock();
        // We keep this as a separate condition so we don't deadlock by obtaining the lock but not
        // having sync
        if (!self.mode.sync) {
            try self.back_screen.copyTo(&self.front_screen);
            self.dirty = false;
        }
    }

    var row: u16 = 0;
    while (row < self.front_screen.height) : (row += 1) {
        var col: u16 = 0;
        while (col < self.front_screen.width) {
            const cell = self.front_screen.readCell(col, row) orelse continue;
            win.writeCell(col, row, cell);
            col += @max(cell.char.width, 1);
        }
    }

    if (self.mode.cursor) {
        win.setCursorShape(self.front_screen.cursor.shape);
        win.showCursor(self.front_screen.cursor.col, self.front_screen.cursor.row);
    }
}

pub fn tryEvent(self: *Terminal) ?Event {
    return self.event_queue.tryPop();
}

pub fn update(self: *Terminal, event: InputEvent) !void {
    switch (event) {
        .key_press => |k| try key.encode(self.anyWriter(), k, true, self.back_screen.csi_u_flags),
    }
}

fn opaqueWrite(ptr: *const anyopaque, buf: []const u8) !usize {
    const self: *const Terminal = @ptrCast(@alignCast(ptr));
    return posix.write(self.pty.pty, buf);
}

pub fn anyWriter(self: *const Terminal) std.io.AnyWriter {
    return .{
        .context = self,
        .writeFn = Terminal.opaqueWrite,
    };
}

fn opaqueRead(ptr: *const anyopaque, buf: []u8) !usize {
    const self: *const Terminal = @ptrCast(@alignCast(ptr));
    return posix.read(self.pty.pty, buf);
}

fn anyReader(self: *const Terminal) std.io.AnyReader {
    return .{
        .context = self,
        .readFn = Terminal.opaqueRead,
    };
}

/// process the output from the command on the pty
fn run(self: *Terminal) !void {
    var parser: Parser = .{
        .buf = try std.ArrayList(u8).initCapacity(self.allocator, 128),
    };
    defer parser.buf.deinit();

    // Use our anyReader to make a buffered reader, then get *that* any reader
    var reader = std.io.bufferedReader(self.anyReader());

    while (!self.should_quit) {
        const event = try parser.parseReader(&reader);
        self.back_mutex.lock();
        defer self.back_mutex.unlock();

        if (!self.dirty and self.event_queue.tryPush(.redraw))
            self.dirty = true;

        switch (event) {
            .print => |str| {
                var iter = grapheme.Iterator.init(str, &self.unicode.width_data.g_data);
                while (iter.next()) |g| {
                    const gr = g.bytes(str);
                    // TODO: use actual instead of .unicode
                    const w = vaxis.gwidth.gwidth(gr, .unicode, &self.unicode.width_data);
                    try self.back_screen.print(gr, @truncate(w), self.mode.autowrap);
                }
            },
            .c0 => |b| try self.handleC0(b),
            .escape => |esc| {
                const final = esc[esc.len - 1];
                switch (final) {
                    'B' => {}, // TODO: handle charsets
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
                        try self.tab_stops.append(@truncate(self.back_screen.cursor.col));
                        std.mem.sort(u16, self.tab_stops.items, {}, std.sort.asc(u16));
                    },
                    // Reverse Index
                    'M' => try self.back_screen.reverseIndex(),
                    else => log.info("unhandled escape: {s}", .{esc}),
                }
            },
            .ss2 => |ss2| log.info("unhandled ss2: {c}", .{ss2}),
            .ss3 => |ss3| log.info("unhandled ss3: {c}", .{ss3}),
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
                    'H', 'f' => {
                        var iter = seq.iterator(u16);
                        const row = iter.next() orelse 1;
                        const col = iter.next() orelse 1;
                        self.back_screen.cursor.col = col -| 1;
                        self.back_screen.cursor.row = row -| 1;
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
                            self.tab_stops.clearRetainingCapacity();
                            var col: u16 = 0;
                            while (col < self.back_screen.width) : (col += 8) {
                                try self.tab_stops.append(col);
                            }
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
                            self.back_screen.buf[i].erase(self.back_screen.cursor.style.bg);
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
                        const w = vaxis.gwidth.gwidth(self.last_printed, .unicode, &self.unicode.width_data);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            try self.back_screen.print(self.last_printed, @truncate(w), self.mode.autowrap);
                        }
                    },
                    // Device Attributes
                    'c' => {
                        if (seq.private_marker) |pm| {
                            switch (pm) {
                                // Secondary
                                '>' => try self.anyWriter().writeAll("\x1B[>1;69;0c"),
                                '=' => try self.anyWriter().writeAll("\x1B[=0000c"),
                                else => log.info("unhandled CSI: {}", .{seq}),
                            }
                        } else {
                            // Primary
                            try self.anyWriter().writeAll("\x1B[?62;22c");
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
                                const current = try self.tab_stops.toOwnedSlice();
                                defer self.tab_stops.allocator.free(current);
                                self.tab_stops.clearRetainingCapacity();
                                for (current) |stop| {
                                    if (stop == self.back_screen.cursor.col) continue;
                                    try self.tab_stops.append(stop);
                                }
                            },
                            3 => self.tab_stops.clearAndFree(),
                            else => log.info("unhandled CSI: {}", .{seq}),
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
                            switch (ps) {
                                5 => try self.anyWriter().writeAll("\x1b[0n"),
                                6 => try self.anyWriter().print("\x1b[{d};{d}R", .{
                                    self.back_screen.cursor.row + 1,
                                    self.back_screen.cursor.col + 1,
                                }),
                                else => log.info("unhandled CSI: {}", .{seq}),
                            }
                        }
                    },
                    'p' => {
                        var iter = seq.iterator(u16);
                        const ps = iter.next() orelse 0;
                        if (seq.intermediate) |int| {
                            switch (int) {
                                // report mode
                                '$' => {
                                    switch (ps) {
                                        2026 => try self.anyWriter().writeAll("\x1b[?2026;2$p"),
                                        else => {
                                            std.log.warn("unhandled mode: {}", .{ps});
                                            try self.anyWriter().print("\x1b[?{d};0$p", .{ps});
                                        },
                                    }
                                },
                                else => log.info("unhandled CSI: {}", .{seq}),
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
                            switch (pm) {
                                // XTVERSION
                                '>' => try self.anyWriter().print(
                                    "\x1bP>|libvaxis {s}\x1B\\",
                                    .{"dev"},
                                ),
                                else => log.info("unhandled CSI: {}", .{seq}),
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
                        self.back_screen.cursor.pending_wrap = false;
                        if (self.mode.origin) {
                            self.back_screen.cursor.col = self.back_screen.scrolling_region.left;
                            self.back_screen.cursor.row = self.back_screen.scrolling_region.top;
                        } else {
                            self.back_screen.cursor.col = 0;
                            self.back_screen.cursor.row = 0;
                        }
                    },
                    else => log.info("unhandled CSI: {}", .{seq}),
                }
            },
            .osc => |osc| {
                const semicolon = std.mem.indexOfScalar(u8, osc, ';') orelse {
                    log.info("unhandled osc: {s}", .{osc});
                    continue;
                };
                const ps = std.fmt.parseUnsigned(u8, osc[0..semicolon], 10) catch {
                    log.info("unhandled osc: {s}", .{osc});
                    continue;
                };
                switch (ps) {
                    0 => {
                        self.title.clearRetainingCapacity();
                        try self.title.appendSlice(osc[semicolon + 1 ..]);
                        self.event_queue.push(.{ .title_change = self.title.items });
                    },
                    7 => {
                        // OSC 7 ; file:// <hostname> <pwd>
                        log.err("osc: {s}", .{osc});
                        self.working_directory.clearRetainingCapacity();
                        const scheme = "file://";
                        const start = std.mem.indexOfScalarPos(u8, osc, semicolon + 2 + scheme.len + 1, '/') orelse {
                            log.info("unknown OSC 7 format: {s}", .{osc});
                            continue;
                        };
                        const enc = osc[start..];
                        var i: usize = 0;
                        while (i < enc.len) : (i += 1) {
                            const b = if (enc[i] == '%') blk: {
                                defer i += 2;
                                break :blk try std.fmt.parseUnsigned(u8, enc[i + 1 .. i + 3], 16);
                            } else enc[i];
                            try self.working_directory.append(b);
                        }
                        self.event_queue.push(.{ .pwd_change = self.working_directory.items });
                    },
                    else => log.info("unhandled osc: {s}", .{osc}),
                }
            },
            .apc => |apc| log.info("unhandled apc: {s}", .{apc}),
        }
    }
}

inline fn handleC0(self: *Terminal, b: ansi.C0) !void {
    switch (b) {
        .NUL, .SOH, .STX => {},
        .EOT => {}, // we send EOT to quit the read thread
        .ENQ => {},
        .BEL => self.event_queue.push(.bell),
        .BS => self.back_screen.cursorLeft(1),
        .HT => self.horizontalTab(1),
        .LF, .VT, .FF => try self.back_screen.index(),
        .CR => self.carriageReturn(),
        .SO => {}, // TODO: Charset shift out
        .SI => {}, // TODO: Charset shift in
        else => log.warn("unhandled C0: 0x{x}", .{@intFromEnum(b)}),
    }
}

pub fn setMode(self: *Terminal, mode: u16, val: bool) void {
    switch (mode) {
        7 => self.mode.autowrap = val,
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
        2026 => self.mode.sync = val,
        else => return,
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
