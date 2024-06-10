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

pub const Event = union(enum) {
    exited,
    bell,
};

const grapheme = @import("grapheme");

const posix = std.posix;

const log = std.log.scoped(.terminal);

pub const Options = struct {
    scrollback_size: usize = 500,
    winsize: Winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
};

pub const Mode = struct {
    origin: bool = false,
    cursor: bool = true,
    sync: bool = false,
};

pub const InputEvent = union(enum) {
    key_press: vaxis.Key,
};

pub var global_vt_mutex: std.Thread.Mutex = .{};
pub var global_vts: ?std.AutoHashMap(i32, *Terminal) = null;

allocator: std.mem.Allocator,
scrollback_size: usize,

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

unicode: *const vaxis.Unicode,
should_quit: bool = false,

mode: Mode = .{},

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
    const pty = try Pty.init();
    try pty.setSize(opts.winsize);
    const cmd: Command = .{
        .argv = argv,
        .env_map = env,
        .pty = pty,
    };
    return .{
        .allocator = allocator,
        .pty = pty,
        .cmd = cmd,
        .scrollback_size = opts.scrollback_size,
        .front_screen = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows),
        .back_screen_pri = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows + opts.scrollback_size),
        .back_screen_alt = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows),
        .unicode = unicode,
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
}

pub fn spawn(self: *Terminal) !void {
    if (self.thread != null) return;
    self.back_screen = &self.back_screen_pri;

    try self.cmd.spawn(self.allocator);

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
        if (!self.mode.sync)
            try self.back_screen.copyTo(&self.front_screen);
    }

    var row: usize = 0;
    while (row < self.front_screen.height) : (row += 1) {
        var col: usize = 0;
        while (col < self.front_screen.width) {
            const cell = self.front_screen.readCell(col, row) orelse continue;
            win.writeCell(col, row, cell);
            col += @max(cell.char.width, 1);
        }
    }

    if (self.front_screen.cursor.visible) {
        win.setCursorShape(self.front_screen.cursor.shape);
        win.showCursor(self.front_screen.cursor.col, self.front_screen.cursor.row);
    }
}

pub fn tryEvent(self: *Terminal) ?Event {
    return self.event_queue.tryPop();
}

pub fn update(self: *Terminal, event: InputEvent) !void {
    switch (event) {
        .key_press => |key| try self.encodeKey(key, true),
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
    var buffered = std.io.bufferedReader(self.anyReader());
    const reader = buffered.reader().any();

    while (!self.should_quit) {
        const event = try parser.parseReader(reader);
        self.back_mutex.lock();
        defer self.back_mutex.unlock();

        switch (event) {
            .print => |str| {
                var iter = grapheme.Iterator.init(str, &self.unicode.grapheme_data);
                while (iter.next()) |g| {
                    const bytes = g.bytes(str);
                    const w = try vaxis.gwidth.gwidth(bytes, .unicode, &self.unicode.width_data);
                    self.back_screen.print(bytes, @truncate(w));
                }
            },
            .c0 => |b| try self.handleC0(b),
            .escape => |_| {}, // std.log.err("unhandled escape: {s}", .{str}),
            .ss2 => |ss2| std.log.err("unhandled ss2: {c}", .{ss2}),
            .ss3 => |ss3| std.log.err("unhandled ss3: {c}", .{ss3}),
            .csi => |seq| {
                switch (seq.final) {
                    // Cursor up
                    'A', 'k' => {
                        self.back_screen.cursor.pending_wrap = false;
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        if (self.back_screen.withinScrollingRegion())
                            self.back_screen.cursor.row = @max(
                                self.back_screen.cursor.row -| delta,
                                self.back_screen.scrolling_region.top,
                            )
                        else
                            self.back_screen.cursor.row = self.back_screen.cursor.row -| delta;
                    },
                    // Cursor Down
                    'B' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        self.back_screen.cursorDown(delta);
                    },
                    // Cursor Right
                    'C' => {
                        self.back_screen.cursor.pending_wrap = false;
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        const within = self.back_screen.withinScrollingRegion();
                        if (within)
                            self.back_screen.cursor.col = @min(
                                self.back_screen.cursor.col + delta,
                                self.back_screen.scrolling_region.right,
                            )
                        else
                            self.back_screen.cursor.col = @min(
                                self.back_screen.cursor.col + delta,
                                self.back_screen.width,
                            );
                    },
                    // Cursor Left
                    'D', 'j' => {
                        self.back_screen.cursor.pending_wrap = false;
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
                    'H', 'f' => {
                        var iter = seq.iterator(u16);
                        const row = iter.next() orelse 1;
                        const col = iter.next() orelse 1;
                        self.back_screen.cursor.col = col -| 1;
                        self.back_screen.cursor.row = row -| 1;
                    },
                    'K' => {
                        // TODO selective erase (private_marker == '?')
                        var iter = seq.iterator(u8);
                        const ps = iter.next() orelse 0;
                        switch (ps) {
                            0 => self.back_screen.eraseRight(),
                            1 => {},
                            2 => {},
                            else => continue,
                        }
                    },
                    'L' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.insertLine(n);
                    },
                    'M' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.deleteLine(n);
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
                        self.back_screen.scrolling_region.top = top - 1;
                        self.back_screen.scrolling_region.bottom = bottom - 1;
                    },
                    else => std.log.err("unhandled CSI: {}", .{seq}),
                }
            },
            .osc => |osc| std.log.err("unhandled osc: {s}", .{osc}),
            .apc => |apc| std.log.err("unhandled apc: {s}", .{apc}),
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
        .HT => {}, // TODO: HT
        .LF, .VT, .FF => try self.back_screen.index(),
        .CR => self.carriageReturn(),
        .SO => {}, // TODO: Charset shift out
        .SI => {}, // TODO: Charset shift in
        else => log.warn("unhandled C0: 0x{x}", .{@intFromEnum(b)}),
    }
}

pub fn setMode(self: *Terminal, mode: u16, val: bool) void {
    switch (mode) {
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

pub fn encodeKey(self: *Terminal, key: vaxis.Key, press: bool) !void {
    switch (press) {
        true => {
            if (key.text) |text| {
                try self.anyWriter().writeAll(text);
                return;
            }
            switch (key.codepoint) {
                0x00...0x7F => try self.anyWriter().writeByte(@intCast(key.codepoint)),
                else => {},
            }
        },
        false => {},
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
