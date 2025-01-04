const std = @import("std");
const cbor = @import("cbor");
const log = @import("log");
const Style = @import("theme").Style;
const Color = @import("theme").Color;
const vaxis = @import("vaxis");
const input = @import("input");
const builtin = @import("builtin");

pub const Plane = @import("Plane.zig");
pub const Cell = @import("Cell.zig");
pub const CursorShape = vaxis.Cell.CursorShape;

pub const style = @import("style.zig").StyleBits;

const Self = @This();
pub const log_name = "vaxis";

allocator: std.mem.Allocator,

tty: vaxis.Tty,
vx: vaxis.Vaxis,

no_alternate: bool,
event_buffer: std.ArrayList(u8),
input_buffer: std.ArrayList(u8),
mods: vaxis.Key.Modifiers = .{},

bracketed_paste: bool = false,
bracketed_paste_buffer: std.ArrayList(u8),

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

logger: log.Logger,

loop: Loop,

pub fn init(allocator: std.mem.Allocator, handler_ctx: *anyopaque, no_alternate: bool) !Self {
    const opts: vaxis.Vaxis.Options = .{
        .kitty_keyboard_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternate_keys = true,
            .report_all_as_ctl_seqs = true,
            .report_text = true,
        },
        .system_clipboard_allocator = allocator,
    };
    return .{
        .allocator = allocator,
        .tty = try vaxis.Tty.init(),
        .vx = try vaxis.init(allocator, opts),
        .no_alternate = no_alternate,
        .event_buffer = std.ArrayList(u8).init(allocator),
        .input_buffer = std.ArrayList(u8).init(allocator),
        .bracketed_paste_buffer = std.ArrayList(u8).init(allocator),
        .handler_ctx = handler_ctx,
        .logger = log.logger(log_name),
        .loop = undefined,
    };
}

pub fn deinit(self: *Self) void {
    panic_cleanup = null;
    self.loop.stop();
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
    self.bracketed_paste_buffer.deinit();
    self.input_buffer.deinit();
    self.event_buffer.deinit();
}

var panic_cleanup: ?struct {
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
} = null;
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const cleanup = panic_cleanup;
    panic_cleanup = null;
    if (cleanup) |self| {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
    }
    return std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub fn run(self: *Self) !void {
    self.vx.sgr = .legacy;

    panic_cleanup = .{ .allocator = self.allocator, .tty = &self.tty, .vx = &self.vx };
    if (!self.no_alternate) try self.vx.enterAltScreen(self.tty.anyWriter());
    if (builtin.os.tag == .windows) {
        try self.resize(.{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 }); // dummy resize to fully init vaxis
    } else {
        try self.sigwinch();
    }
    try self.vx.setBracketedPaste(self.tty.anyWriter(), true);
    try self.vx.queryTerminalSend(self.tty.anyWriter());

    self.loop = Loop.init(&self.tty, &self.vx);
    try self.loop.start();
}

pub fn render(self: *Self) !void {
    var bufferedWriter = self.tty.bufferedWriter();
    try self.vx.render(bufferedWriter.writer().any());
    try bufferedWriter.flush();
}

pub fn sigwinch(self: *Self) !void {
    if (builtin.os.tag == .windows or self.vx.state.in_band_resize) return;
    try self.resize(try vaxis.Tty.getWinsize(self.input_fd_blocking()));
}

fn resize(self: *Self, ws: vaxis.Winsize) !void {
    try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
    self.vx.queueRefresh();
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"resize"}));
}

pub fn stop(self: *Self) void {
    _ = self;
}

pub fn stdplane(self: *Self) Plane {
    const name = "root";
    var plane: Plane = .{
        .window = self.vx.window(),
        .name_buf = undefined,
        .name_len = name.len,
    };
    @memcpy(plane.name_buf[0..name.len], name);
    return plane;
}

pub fn input_fd_blocking(self: Self) i32 {
    return self.tty.fd;
}

pub fn leave_alternate_screen(self: *Self) void {
    self.vx.exitAltScreen() catch {};
}

pub fn process_renderer_event(self: *Self, msg: []const u8) !void {
    var input_: []const u8 = undefined;
    var text_: []const u8 = undefined;
    if (!try cbor.match(msg, .{ "RDR", cbor.extract(&input_), cbor.extract(&text_) }))
        return error.UnexpectedRendererEvent;
    const text = if (text_.len > 0) text_ else null;
    const event = std.mem.bytesAsValue(vaxis.Event, input_);
    switch (event.*) {
        .key_press => |key__| {
            const key_ = filter_mods(key__);
            try self.sync_mod_state(key_.codepoint, key_.mods);
            const cbor_msg = try self.fmtmsg(.{
                "I",
                input.event.press,
                key_.codepoint,
                key_.shifted_codepoint orelse key_.codepoint,
                text orelse "",
                @as(u8, @bitCast(key_.mods)),
            });
            if (self.bracketed_paste and self.handle_bracketed_paste_input(cbor_msg) catch |e| return self.handle_bracketed_paste_error(e)) {
                // we have stored it to handle on .paste_end, so do nothing more here
            } else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
        },
        .key_release => |key__| {
            const key_ = filter_mods(key__);
            const cbor_msg = try self.fmtmsg(.{
                "I",
                input.event.release,
                key_.codepoint,
                key_.shifted_codepoint orelse key_.codepoint,
                text orelse "",
                @as(u8, @bitCast(key_.mods)),
            });
            if (self.bracketed_paste) {} else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
        },
        .mouse => |mouse_| {
            const mouse = self.vx.translateMouse(mouse_);
            try self.sync_mod_state(0, .{ .ctrl = mouse.mods.ctrl, .shift = mouse.mods.shift, .alt = mouse.mods.alt });
            if (self.dispatch_mouse) |f| switch (mouse.type) {
                .motion => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                    "M",
                    mouse.col,
                    mouse.row,
                    mouse.xoffset,
                    mouse.yoffset,
                })),
                .press => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                    "B",
                    input.event.press,
                    @intFromEnum(mouse.button),
                    input.utils.button_id_string(mouse.button),
                    mouse.col,
                    mouse.row,
                    mouse.xoffset,
                    mouse.yoffset,
                })),
                .release => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                    "B",
                    input.event.release,
                    @intFromEnum(mouse.button),
                    input.utils.button_id_string(mouse.button),
                    mouse.col,
                    mouse.row,
                    mouse.xoffset,
                    mouse.yoffset,
                })),
                .drag => if (self.dispatch_mouse_drag) |f_|
                    f_(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                        "D",
                        input.event.press,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(mouse.button),
                        mouse.col,
                        mouse.row,
                        mouse.xoffset,
                        mouse.yoffset,
                    })),
            };
        },
        .focus_in => {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"focus_in"}));
        },
        .focus_out => {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"focus_out"}));
        },
        .paste_start => try self.handle_bracketed_paste_start(),
        .paste_end => try self.handle_bracketed_paste_end(),
        .paste => |_| {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", text }));
        },
        .color_report => {},
        .color_scheme => {},
        .winsize => |ws| {
            if (!self.vx.state.in_band_resize) {
                self.vx.state.in_band_resize = true;
                self.logger.print("in band resize capability detected", .{});
            }
            try self.resize(ws);
        },

        .cap_unicode => {
            self.logger.print("unicode capability detected", .{});
            self.vx.caps.unicode = .unicode;
            self.vx.screen.width_method = .unicode;
        },
        .cap_sgr_pixels => {
            self.logger.print("pixel mouse capability detected", .{});
            self.vx.caps.sgr_pixels = true;
        },
        .cap_da1 => {
            self.vx.enableDetectedFeatures(self.tty.anyWriter()) catch |e| self.logger.err("enable features", e);
            try self.vx.setMouseMode(self.tty.anyWriter(), true);
        },
        .cap_kitty_keyboard => {
            self.logger.print("kitty keyboard capability detected", .{});
            self.vx.caps.kitty_keyboard = true;
        },
        .cap_kitty_graphics => {
            if (!self.vx.caps.kitty_graphics) {
                self.vx.caps.kitty_graphics = true;
            }
        },
        .cap_rgb => {
            self.logger.print("rgb capability detected", .{});
            self.vx.caps.rgb = true;
        },
        .cap_color_scheme_updates => {},
    }
}

fn fmtmsg(self: *Self, value: anytype) ![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(self.event_buffer.writer(), value);
    return self.event_buffer.items;
}

fn handle_bracketed_paste_input(self: *Self, cbor_msg: []const u8) !bool {
    var keypress: input.Key = undefined;
    var egc_: input.Key = undefined;
    if (try cbor.match(cbor_msg, .{ "I", cbor.number, cbor.extract(&keypress), cbor.extract(&egc_), cbor.string, 0 })) {
        switch (keypress) {
            input.key.enter => try self.bracketed_paste_buffer.appendSlice("\n"),
            input.key.tab => try self.bracketed_paste_buffer.appendSlice("\t"),
            else => if (!input.is_non_input_key(keypress)) {
                var buf: [6]u8 = undefined;
                const bytes = try input.ucs32_to_utf8(&[_]u32{egc_}, &buf);
                try self.bracketed_paste_buffer.appendSlice(buf[0..bytes]);
            } else {
                var buf: [6]u8 = undefined;
                const bytes = try input.ucs32_to_utf8(&[_]u32{egc_}, &buf);
                self.logger.print("unexpected codepoint in paste: {d} {s}", .{ keypress, buf[0..bytes] });
            },
        }
        return true;
    }
    return false;
}

fn handle_bracketed_paste_start(self: *Self) !void {
    self.bracketed_paste = true;
    self.bracketed_paste_buffer.clearRetainingCapacity();
}

fn handle_bracketed_paste_end(self: *Self) !void {
    defer {
        self.bracketed_paste_buffer.clearAndFree();
        self.bracketed_paste = false;
    }
    if (!self.bracketed_paste) return;
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", self.bracketed_paste_buffer.items }));
}

fn handle_bracketed_paste_error(self: *Self, e: anytype) !void {
    self.logger.err("bracketed paste", e);
    self.bracketed_paste_buffer.clearAndFree();
    self.bracketed_paste = false;
    return e;
}

pub fn set_terminal_title(self: *Self, text: []const u8) void {
    self.vx.setTitle(self.tty.anyWriter(), text) catch {};
}

pub fn set_terminal_style(self: *Self, style_: Style) void {
    if (style_.fg) |color|
        self.vx.setTerminalForegroundColor(self.tty.anyWriter(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
    if (style_.bg) |color|
        self.vx.setTerminalBackgroundColor(self.tty.anyWriter(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
}

pub fn set_terminal_cursor_color(self: *Self, color: Color) void {
    self.vx.setTerminalCursorColor(self.tty.anyWriter(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
}

pub fn set_terminal_working_directory(self: *Self, absolute_path: []const u8) void {
    self.vx.setTerminalWorkingDirectory(self.tty.anyWriter(), absolute_path) catch {};
}

pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    var bufferedWriter = self.tty.bufferedWriter();
    self.vx.copyToSystemClipboard(bufferedWriter.writer().any(), text, self.allocator) catch |e| log.logger(log_name).err("copy_to_system_clipboard", e);
    bufferedWriter.flush() catch @panic("flush failed");
}

pub fn request_system_clipboard(self: *Self) void {
    self.vx.requestSystemClipboard(self.tty.anyWriter()) catch |e| log.logger(log_name).err("request_system_clipboard", e);
}

pub fn request_windows_clipboard(allocator: std.mem.Allocator) ![]u8 {
    const windows = std.os.windows;
    const win32 = struct {
        pub extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(windows.WINAPI) windows.BOOL;
        pub extern "user32" fn CloseClipboard() callconv(windows.WINAPI) windows.BOOL;
        pub extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: windows.HANDLE) callconv(windows.WINAPI) ?windows.HANDLE;
        pub extern "user32" fn GetClipboardData(uFormat: windows.UINT) callconv(windows.WINAPI) ?windows.HANDLE;
        pub extern "kernel32" fn GlobalLock(hMem: windows.HANDLE) ?windows.LPVOID;
        pub extern "kernel32" fn GlobalUnlock(hMem: windows.HANDLE) windows.BOOL;
        const CF_TEXT = @as(c_int, 1);
    };

    if (win32.OpenClipboard(null) == 0)
        return error.OpenClipBoardFailed;
    defer _ = win32.CloseClipboard();

    const mem = win32.GetClipboardData(win32.CF_TEXT) orelse return error.ClipboardDataRetrievalFailed;
    const data: [*c]u8 = @ptrCast(win32.GlobalLock(mem) orelse return error.ClipboardDataLockFailed);
    const text = std.mem.span(data);
    defer _ = win32.GlobalUnlock(mem);

    return allocator.dupe(u8, text);
}

pub fn request_mouse_cursor_text(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.text) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_pointer(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.pointer) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_default(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.default) else self.vx.setMouseShape(.default);
}

pub fn cursor_enable(self: *Self, y: c_int, x: c_int, shape: CursorShape) !void {
    self.vx.screen.cursor_vis = true;
    self.vx.screen.cursor_row = @intCast(y);
    self.vx.screen.cursor_col = @intCast(x);
    self.vx.screen.cursor_shape = shape;
}

pub fn cursor_disable(self: *Self) void {
    self.vx.screen.cursor_vis = false;
}

fn sync_mod_state(self: *Self, keypress: u32, modifiers: vaxis.Key.Modifiers) !void {
    if (modifiers.ctrl and !self.mods.ctrl and !(keypress == input.key.left_control or keypress == input.key.right_control))
        try self.send_sync_key(input.event.press, input.key.left_control, "", modifiers);
    if (!modifiers.ctrl and self.mods.ctrl and !(keypress == input.key.left_control or keypress == input.key.right_control))
        try self.send_sync_key(input.event.release, input.key.left_control, "", modifiers);
    if (modifiers.alt and !self.mods.alt and !(keypress == input.key.left_alt or keypress == input.key.right_alt))
        try self.send_sync_key(input.event.press, input.key.left_alt, "", modifiers);
    if (!modifiers.alt and self.mods.alt and !(keypress == input.key.left_alt or keypress == input.key.right_alt))
        try self.send_sync_key(input.event.release, input.key.left_alt, "", modifiers);
    if (modifiers.shift and !self.mods.shift and !(keypress == input.key.left_shift or keypress == input.key.right_shift))
        try self.send_sync_key(input.event.press, input.key.left_shift, "", modifiers);
    if (!modifiers.shift and self.mods.shift and !(keypress == input.key.left_shift or keypress == input.key.right_shift))
        try self.send_sync_key(input.event.release, input.key.left_shift, "", modifiers);
    self.mods = modifiers;
}

fn send_sync_key(self: *Self, event: input.Event, keypress: u32, key_string: []const u8, modifiers: vaxis.Key.Modifiers) !void {
    if (self.dispatch_input) |f| f(
        self.handler_ctx,
        try self.fmtmsg(.{
            "I",
            event,
            keypress,
            keypress,
            key_string,
            @as(u8, @bitCast(modifiers)),
        }),
    );
}

fn filter_mods(key_: vaxis.Key) vaxis.Key {
    var key__ = key_;
    key__.mods = .{
        .shift = key_.mods.shift,
        .alt = key_.mods.alt,
        .ctrl = key_.mods.ctrl,
    };
    return key__;
}

const Loop = struct {
    tty: *vaxis.Tty,
    vaxis: *vaxis.Vaxis,
    pid: tp.pid,

    thread: ?std.Thread = null,
    should_quit: bool = false,

    const tp = @import("thespian");

    pub fn init(tty: *vaxis.Tty, vaxis_: *vaxis.Vaxis) Loop {
        return .{
            .tty = tty,
            .vaxis = vaxis_,
            .pid = tp.self_pid().clone(),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.pid.deinit();
    }

    /// spawns the input thread to read input from the tty
    pub fn start(self: *Loop) !void {
        if (self.thread) |_| return;
        self.thread = try std.Thread.spawn(.{}, Loop.ttyRun, .{self});
    }

    /// stops reading from the tty.
    pub fn stop(self: *Loop) void {
        self.should_quit = true;
        // trigger a read
        self.vaxis.deviceStatusReport(self.tty.anyWriter()) catch {};

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
            self.should_quit = false;
        }
    }

    fn postEvent(self: *Loop, event: vaxis.Event) void {
        var text: []const u8 = "";
        var free_text: bool = false;
        switch (event) {
            .key_press => |key_| {
                if (key_.text) |text_| text = text_;
            },
            .key_release => |key_| {
                if (key_.text) |text_| text = text_;
            },
            .paste => |text_| {
                text = text_;
                free_text = true;
            },
            else => {},
        }
        self.pid.send(.{ "RDR", std.mem.asBytes(&event), text }) catch @panic("send RDR event failed");
        if (free_text)
            self.vaxis.opts.system_clipboard_allocator.?.free(text);
    }

    fn ttyRun(self: *Loop) !void {
        switch (builtin.os.tag) {
            .windows => {
                var parser: vaxis.Parser = .{
                    .grapheme_data = &self.vaxis.unicode.width_data.g_data,
                };
                const a = self.vaxis.opts.system_clipboard_allocator orelse @panic("no tty allocator");
                while (!self.should_quit) {
                    self.postEvent(try self.tty.nextEvent(&parser, a));
                }
            },
            else => {
                var parser: vaxis.Parser = .{
                    .grapheme_data = &self.vaxis.unicode.width_data.g_data,
                };

                const a = self.vaxis.opts.system_clipboard_allocator orelse @panic("no tty allocator");

                var buf = try a.alloc(u8, 512);
                defer a.free(buf);
                var n: usize = 0;
                var need_read = false;

                while (!self.should_quit) {
                    if (n >= buf.len) {
                        const buf_grow = try a.alloc(u8, buf.len * 2);
                        @memcpy(buf_grow[0..buf.len], buf);
                        a.free(buf);
                        buf = buf_grow;
                    }
                    if (n == 0 or need_read) {
                        const n_ = try self.tty.read(buf[n..]);
                        n = n + n_;
                        need_read = false;
                    }
                    const result = try parser.parse(buf[0..n], a);
                    if (result.n == 0) {
                        need_read = true;
                        continue;
                    }
                    if (result.event) |event| {
                        self.postEvent(event);
                    }
                    if (result.n < n) {
                        const buf_move = try a.alloc(u8, buf.len);
                        @memcpy(buf_move[0 .. n - result.n], buf[result.n..n]);
                        a.free(buf);
                        buf = buf_move;
                        n = n - result.n;
                    } else {
                        n = 0;
                    }
                }
            },
        }
    }
};
