//! A virtual terminal widget
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
pub const Command = @import("Command.zig");
const Parser = @import("Parser.zig");
const Pty = @import("Pty.zig");
const vaxis = @import("../../main.zig");
const Winsize = vaxis.Winsize;
const Screen = @import("Screen.zig");
const DisplayWidth = @import("DisplayWidth");

const grapheme = @import("grapheme");

const posix = std.posix;

const log = std.log.scoped(.terminal);

pub const Options = struct {
    scrollback_size: usize = 500,
    winsize: Winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
};

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
    self.cmd.kill();
    if (self.thread) |thread| {
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
    self.thread = try std.Thread.spawn(.{}, Terminal.run, .{self});
}

/// resize the screen. Locks access to the back screen. Should only be called from the main thread
pub fn resize(self: *Terminal, ws: Winsize) !void {
    // don't deinit with no size change
    if (ws.cols == self.front_screen.width and
        ws.rows == self.front_screen.height)
    {
        std.log.debug("resize requested but no change", .{});
        return;
    }

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
    // TODO: check sync
    if (self.back_mutex.tryLock()) {
        defer self.back_mutex.unlock();
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
                std.log.err("print: {s}", .{str});
                var iter = grapheme.Iterator.init(str, &self.unicode.grapheme_data);
                while (iter.next()) |g| {
                    const bytes = g.bytes(str);
                    const w = try vaxis.gwidth.gwidth(bytes, .unicode, &self.unicode.width_data);
                    self.back_screen.print(bytes, @truncate(w));
                }
            },
            .c0 => |b| try self.handleC0(b),
            .csi => |seq| {
                const final = seq[seq.len - 1];
                switch (final) {
                    'B' => { // CUD
                        switch (seq.len) {
                            0 => unreachable,
                            1 => self.back_screen.cursor.row += 1,
                            else => {
                                const delta = parseParam(u16, seq[2 .. seq.len - 1], 1) orelse 1;
                                self.back_screen.cursor.row = @min(self.back_screen.height - 1, self.back_screen.cursor.row + delta);
                            },
                        }
                    },
                    'H' => { // CUP
                        const delim = std.mem.indexOfScalar(u8, seq, ';') orelse {
                            switch (seq.len) {
                                0 => unreachable,
                                1 => {
                                    self.back_screen.cursor.row = 0;
                                    self.back_screen.cursor.col = 0;
                                },
                                else => {
                                    const row = parseParam(u16, seq[0 .. seq.len - 1], 1) orelse 1;
                                    self.back_screen.cursor.row = row - 1;
                                },
                            }
                            continue;
                        };
                        const row = parseParam(u16, seq[0..delim], 1) orelse 1;
                        const col = parseParam(u16, seq[delim + 1 .. seq.len - 1], 1) orelse 1;
                        self.back_screen.cursor.col = col - 1;
                        self.back_screen.cursor.row = row - 1;
                    },
                    'm' => self.back_screen.sgr(seq[0 .. seq.len - 1]),
                    else => {},
                }
            },
            else => {},
        }
    }
}

inline fn handleC0(self: *Terminal, b: u8) !void {
    switch (b) {
        0x0a, 0x0b, 0x0c => try self.back_screen.index(), // line feed
        0x0d => {}, // carriage return
        else => log.warn("unhandled C0: 0x{x}", .{b}),
    }
}

/// Parse a param buffer, returning a default value if the param was empty
inline fn parseParam(comptime T: type, buf: []const u8, default: ?T) ?T {
    if (buf.len == 0) return default;
    return std.fmt.parseUnsigned(T, buf, 10) catch return null;
}
