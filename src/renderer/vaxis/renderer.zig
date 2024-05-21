const std = @import("std");
const cbor = @import("cbor");
const log = @import("log");
const Style = @import("theme").Style;

const vaxis = @import("vaxis");

pub const input = @import("input.zig");

pub const Plane = @import("Plane.zig");
pub const Cell = @import("Cell.zig");

pub const style = @import("style.zig").StyleBits;

const mod = input.modifier;
const key = input.key;
const event_type = input.event_type;

const Self = @This();
pub const log_name = "vaxis";

a: std.mem.Allocator,

vx: vaxis.Vaxis,

no_alternate: bool,
event_buffer: std.ArrayList(u8),
input_buffer: std.ArrayList(u8),

bracketed_paste: bool = false,
bracketed_paste_buffer: std.ArrayList(u8),

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, dragging: bool, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

logger: log.Logger,

const ModState = struct { ctrl: bool = false, shift: bool = false, alt: bool = false };

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub fn init(a: std.mem.Allocator, handler_ctx: *anyopaque, no_alternate: bool) !Self {
    const opts: vaxis.Vaxis.Options = .{
        .kitty_keyboard_flags = .{ .report_events = true },
    };
    return .{
        .a = a,
        .vx = try vaxis.init(a, opts),
        .no_alternate = no_alternate,
        .event_buffer = std.ArrayList(u8).init(a),
        .input_buffer = std.ArrayList(u8).init(a),
        .bracketed_paste_buffer = std.ArrayList(u8).init(a),
        .handler_ctx = handler_ctx,
        .logger = log.logger(log_name),
    };
}

pub fn deinit(self: *Self) void {
    self.vx.deinit(self.a);
    self.bracketed_paste_buffer.deinit();
    self.input_buffer.deinit();
    self.event_buffer.deinit();
}

pub fn run(self: *Self) !void {
    if (self.vx.tty == null) self.vx.tty = try vaxis.Tty.init();
    if (!self.no_alternate) try self.vx.enterAltScreen();
    try self.vx.queryTerminal();
    const ws = try vaxis.Tty.getWinsize(self.input_fd_blocking());
    try self.vx.resize(self.a, ws);
    self.vx.queueRefresh();
    try self.vx.setMouseMode(.pixels);
}

pub fn render(self: *Self) !void {
    return self.vx.render();
}

pub fn refresh(self: *Self) !void {
    const ws = try vaxis.Tty.getWinsize(self.input_fd_blocking());
    try self.vx.resize(self.a, ws);
    self.vx.queueRefresh();
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
    return self.vx.tty.?.fd;
}

pub fn leave_alternate_screen(self: *Self) void {
    self.vx.exitAltScreen() catch {};
}

pub fn process_input(self: *Self, input_: []const u8) !void {
    var parser: vaxis.Parser = .{
        .grapheme_data = &self.vx.screen.unicode.grapheme_data,
    };
    try self.input_buffer.appendSlice(input_);
    var buf = self.input_buffer.items;
    defer {
        if (buf.len == 0) {
            self.input_buffer.clearRetainingCapacity();
        } else {
            const rest = self.a.alloc(u8, buf.len) catch |e| std.debug.panic("{any}", .{e});
            @memcpy(rest, buf);
            self.input_buffer.deinit();
            self.input_buffer = std.ArrayList(u8).fromOwnedSlice(self.a, rest);
        }
    }
    while (buf.len > 0) {
        const result = try parser.parse(buf);
        if (result.n == 0)
            return;
        buf = buf[result.n..];
        const event = result.event orelse continue;
        switch (event) {
            .key_press => |key_| {
                const cbor_msg = try self.fmtmsg(.{
                    "I",
                    event_type.PRESS,
                    key_.codepoint,
                    key_.shifted_codepoint orelse key_.codepoint,
                    key_.text orelse input.utils.key_id_string(key_.codepoint),
                    @as(u8, @bitCast(key_.mods)),
                });
                if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            },
            .key_release => |*key_| {
                const cbor_msg = try self.fmtmsg(.{
                    "I",
                    event_type.RELEASE,
                    key_.codepoint,
                    key_.shifted_codepoint orelse key_.codepoint,
                    key_.text orelse input.utils.key_id_string(key_.codepoint),
                    @as(u8, @bitCast(key_.mods)),
                });
                if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            },
            .mouse => |mouse| {
                const ypos = mouse.row - 1;
                const xpos = mouse.col - 1;
                const ycell = self.vx.screen.height_pix / self.vx.screen.height;
                const xcell = self.vx.screen.width_pix / self.vx.screen.width;
                const y = ypos / ycell;
                const x = xpos / xcell;
                const ypx = ypos % ycell;
                const xpx = xpos % xcell;
                if (self.dispatch_mouse) |f| switch (mouse.type) {
                    .motion => f(self.handler_ctx, @intCast(y), @intCast(x), try self.fmtmsg(.{
                        "M",
                        x,
                        y,
                        xpx,
                        ypx,
                    })),
                    .press => f(self.handler_ctx, @intCast(y), @intCast(x), try self.fmtmsg(.{
                        "B",
                        event_type.PRESS,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(@intFromEnum(mouse.button)),
                        x,
                        y,
                        xpx,
                        ypx,
                    })),
                    .release => f(self.handler_ctx, @intCast(y), @intCast(x), try self.fmtmsg(.{
                        "B",
                        event_type.RELEASE,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(@intFromEnum(mouse.button)),
                        x,
                        y,
                        xpx,
                        ypx,
                    })),
                    .drag => if (self.dispatch_mouse_drag) |f_|
                        f_(self.handler_ctx, @intCast(y), @intCast(x), true, try self.fmtmsg(.{
                            "D",
                            event_type.PRESS,
                            @intFromEnum(mouse.button),
                            input.utils.button_id_string(@intFromEnum(mouse.button)),
                            x,
                            y,
                            xpx,
                            ypx,
                        })),
                };
            },
            .focus_in => {
                // FIXME
            },
            .focus_out => {
                // FIXME
            },
            .paste_start => {
                self.bracketed_paste = true;
                self.bracketed_paste_buffer.clearRetainingCapacity();
            },
            .paste_end => {
                defer self.bracketed_paste_buffer.clearAndFree();
                if (!self.bracketed_paste) return;
                self.bracketed_paste = false;
                if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", self.bracketed_paste_buffer.items }));
            },
            .cap_unicode => {
                self.vx.caps.unicode = .unicode;
                self.vx.screen.width_method = .unicode;
            },
            .cap_da1 => {
                std.Thread.Futex.wake(&self.vx.query_futex, 10);
            },
            .cap_kitty_keyboard => {
                self.vx.caps.kitty_keyboard = true;
            },
            .cap_kitty_graphics => {
                if (!self.vx.caps.kitty_graphics) {
                    self.vx.caps.kitty_graphics = true;
                }
            },
            .cap_rgb => {
                self.vx.caps.rgb = true;
            },
        }
    }
}

fn fmtmsg(self: *Self, value: anytype) ![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(self.event_buffer.writer(), value);
    return self.event_buffer.items;
}

const OSC = "\x1B]"; // Operating System Command
const ST = "\x1B\\"; // String Terminator
const BEL = "\x07";
const OSC0_title = OSC ++ "0;";
const OSC52_clipboard = OSC ++ "52;c;";
const OSC52_clipboard_paste = OSC ++ "52;p;";
const OSC22_cursor = OSC ++ "22;";
const OSC22_cursor_reply = OSC ++ "22:";

const CSI = "\x1B["; // Control Sequence Introducer
const CSI_bracketed_paste_enable = CSI ++ "?2004h";
const CSI_bracketed_paste_disable = CSI ++ "?2004h";
const CIS_bracketed_paste_begin = CSI ++ "200~";
const CIS_bracketed_paste_end = CSI ++ "201~";

pub fn set_terminal_title(text: []const u8) void {
    var writer = std.io.getStdOut().writer();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const term_cmd = std.fmt.bufPrint(&buf, OSC0_title ++ "{s}" ++ BEL, .{text}) catch return;
    _ = writer.write(term_cmd) catch return;
}

pub fn copy_to_system_clipboard(tmp_a: std.mem.Allocator, text: []const u8) void {
    copy_to_system_clipboard_with_errors(tmp_a, text) catch |e| log.logger(log_name).err("copy_to_system_clipboard", e);
}

fn copy_to_system_clipboard_with_errors(tmp_a: std.mem.Allocator, text: []const u8) !void {
    var writer = std.io.getStdOut().writer();
    const encoder = std.base64.standard.Encoder;
    const size = OSC52_clipboard.len + encoder.calcSize(text.len) + ST.len;
    const buf = try tmp_a.alloc(u8, size);
    defer tmp_a.free(buf);
    @memcpy(buf[0..OSC52_clipboard.len], OSC52_clipboard);
    const b64 = encoder.encode(buf[OSC52_clipboard.len..], text);
    @memcpy(buf[OSC52_clipboard.len + b64.len ..], ST);
    _ = try writer.write(buf);
}

pub fn request_system_clipboard() void {
    write_stdout(OSC52_clipboard ++ "?" ++ ST);
}

pub fn request_mouse_cursor_text(push_or_pop: bool) void {
    if (push_or_pop) mouse_cursor_push("text") else mouse_cursor_pop();
}

pub fn request_mouse_cursor_pointer(push_or_pop: bool) void {
    if (push_or_pop) mouse_cursor_push("pointer") else mouse_cursor_pop();
}

pub fn request_mouse_cursor_default(push_or_pop: bool) void {
    if (push_or_pop) mouse_cursor_push("default") else mouse_cursor_pop();
}

fn mouse_cursor_push(comptime name: []const u8) void {
    write_stdout(OSC22_cursor ++ name ++ ST);
}

fn mouse_cursor_pop() void {
    write_stdout(OSC22_cursor ++ "default" ++ ST);
}

fn write_stdout(bytes: []const u8) void {
    _ = std.io.getStdOut().writer().write(bytes) catch |e| log.logger(log_name).err("stdout", e);
}

pub fn cursor_enable(self: *Self, y: c_int, x: c_int) !void {
    self.vx.screen.cursor_vis = true;
    self.vx.screen.cursor_row = @intCast(y);
    self.vx.screen.cursor_col = @intCast(x);
}

pub fn cursor_disable(self: *Self) void {
    self.vx.screen.cursor_vis = false;
}

pub fn ucs32_to_utf8(ucs32: []const u32, utf8: []u8) !usize {
    return @intCast(try std.unicode.utf8Encode(@intCast(ucs32[0]), utf8));
}
