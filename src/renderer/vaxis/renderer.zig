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
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, dragging: bool, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

logger: log.Logger,

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub fn init(a: std.mem.Allocator, handler_ctx: *anyopaque, no_alternate: bool) !Self {
    const opts: vaxis.Vaxis.Options = .{
        .kitty_keyboard_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternate_keys = true,
            .report_all_as_ctl_seqs = true,
            .report_text = true,
        },
        .system_clipboard_allocator = a,
    };
    return .{
        .a = a,
        .tty = try vaxis.Tty.init(),
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
    panic_cleanup_tty = null;
    self.vx.deinit(self.a, self.tty.anyWriter());
    self.tty.deinit();
    self.bracketed_paste_buffer.deinit();
    self.input_buffer.deinit();
    self.event_buffer.deinit();
}

var panic_cleanup_tty: ?*vaxis.Tty = null;
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (panic_cleanup_tty) |tty| tty.deinit();
    return std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub fn run(self: *Self) !void {
    self.vx.sgr = .legacy;

    panic_cleanup_tty = &self.tty;
    if (!self.no_alternate) try self.vx.enterAltScreen(self.tty.anyWriter());
    try self.query_resize();
    try self.vx.setBracketedPaste(self.tty.anyWriter(), true);
    try self.vx.queryTerminalSend(self.tty.anyWriter());
}

pub fn render(self: *Self) !void {
    var bufferedWriter = self.tty.bufferedWriter();
    try self.vx.render(bufferedWriter.writer().any());
    try bufferedWriter.flush();
}

pub fn query_resize(self: *Self) !void {
    try self.resize(try vaxis.Tty.getWinsize(self.input_fd_blocking()));
}

pub fn resize(self: *Self, ws: vaxis.Winsize) !void {
    try self.vx.resize(self.a, self.tty.anyWriter(), ws);
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
    return self.tty.fd;
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
        const result = try parser.parse(buf, self.a);
        if (result.n == 0)
            return;
        buf = buf[result.n..];
        const event = result.event orelse continue;
        switch (event) {
            .key_press => |key_| {
                try self.sync_mod_state(key_.codepoint, key_.mods);
                const cbor_msg = try self.fmtmsg(.{
                    "I",
                    event_type.PRESS,
                    key_.codepoint,
                    key_.shifted_codepoint orelse key_.codepoint,
                    key_.text orelse input.utils.key_id_string(key_.base_layout_codepoint orelse key_.codepoint),
                    @as(u8, @bitCast(key_.mods)),
                });
                if (self.bracketed_paste and self.handle_bracketed_paste_input(cbor_msg) catch |e| {
                    self.bracketed_paste_buffer.clearAndFree();
                    self.bracketed_paste = false;
                    return e;
                }) {} else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            },
            .key_release => |*key_| {
                const cbor_msg = try self.fmtmsg(.{
                    "I",
                    event_type.RELEASE,
                    key_.codepoint,
                    key_.shifted_codepoint orelse key_.codepoint,
                    key_.text orelse input.utils.key_id_string(key_.base_layout_codepoint orelse key_.codepoint),
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
                        event_type.PRESS,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(@intFromEnum(mouse.button)),
                        mouse.col,
                        mouse.row,
                        mouse.xoffset,
                        mouse.yoffset,
                    })),
                    .release => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                        "B",
                        event_type.RELEASE,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(@intFromEnum(mouse.button)),
                        mouse.col,
                        mouse.row,
                        mouse.xoffset,
                        mouse.yoffset,
                    })),
                    .drag => if (self.dispatch_mouse_drag) |f_|
                        f_(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), true, try self.fmtmsg(.{
                            "D",
                            event_type.PRESS,
                            @intFromEnum(mouse.button),
                            input.utils.button_id_string(@intFromEnum(mouse.button)),
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
            .paste_start => {
                self.bracketed_paste = true;
                self.bracketed_paste_buffer.clearRetainingCapacity();
            },
            .paste_end => try self.handle_bracketed_paste_end(),
            .paste => |text| {
                defer self.a.free(text);
                if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", text }));
            },
            .color_report => {},
            .color_scheme => {},
            .winsize => |ws| try self.resize(ws),

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
}

fn fmtmsg(self: *Self, value: anytype) ![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(self.event_buffer.writer(), value);
    return self.event_buffer.items;
}

fn handle_bracketed_paste_input(self: *Self, cbor_msg: []const u8) !bool {
    var keypress: u32 = undefined;
    var egc_: u32 = undefined;
    if (try cbor.match(cbor_msg, .{ "I", cbor.number, cbor.extract(&keypress), cbor.extract(&egc_), cbor.string, 0 })) {
        switch (keypress) {
            key.ENTER => try self.bracketed_paste_buffer.appendSlice("\n"),
            else => if (!key.synthesized_p(keypress)) {
                var buf: [6]u8 = undefined;
                const bytes = try ucs32_to_utf8(&[_]u32{egc_}, &buf);
                try self.bracketed_paste_buffer.appendSlice(buf[0..bytes]);
            } else {
                try self.handle_bracketed_paste_end();
                return false;
            },
        }
        return true;
    }
    return false;
}

fn handle_bracketed_paste_end(self: *Self) !void {
    defer self.bracketed_paste_buffer.clearAndFree();
    if (!self.bracketed_paste) return;
    self.bracketed_paste = false;
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", self.bracketed_paste_buffer.items }));
}

pub fn set_terminal_title(self: *Self, text: []const u8) void {
    self.vx.setTitle(self.tty.anyWriter(), text) catch {};
}

pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    var bufferedWriter = self.tty.bufferedWriter();
    self.vx.copyToSystemClipboard(bufferedWriter.writer().any(), text, self.a) catch |e| log.logger(log_name).err("copy_to_system_clipboard", e);
    bufferedWriter.flush() catch @panic("flush failed");
}

pub fn request_system_clipboard(self: *Self) void {
    self.vx.requestSystemClipboard(self.tty.anyWriter()) catch |e| log.logger(log_name).err("request_system_clipboard", e);
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

fn sync_mod_state(self: *Self, keypress: u32, modifiers: vaxis.Key.Modifiers) !void {
    if (modifiers.ctrl and !self.mods.ctrl and !(keypress == key.LCTRL or keypress == key.RCTRL))
        try self.send_sync_key(event_type.PRESS, key.LCTRL, "lctrl", modifiers);
    if (!modifiers.ctrl and self.mods.ctrl and !(keypress == key.LCTRL or keypress == key.RCTRL))
        try self.send_sync_key(event_type.RELEASE, key.LCTRL, "lctrl", modifiers);
    if (modifiers.alt and !self.mods.alt and !(keypress == key.LALT or keypress == key.RALT))
        try self.send_sync_key(event_type.PRESS, key.LALT, "lalt", modifiers);
    if (!modifiers.alt and self.mods.alt and !(keypress == key.LALT or keypress == key.RALT))
        try self.send_sync_key(event_type.RELEASE, key.LALT, "lalt", modifiers);
    if (modifiers.shift and !self.mods.shift and !(keypress == key.LSHIFT or keypress == key.RSHIFT))
        try self.send_sync_key(event_type.PRESS, key.LSHIFT, "lshift", modifiers);
    if (!modifiers.shift and self.mods.shift and !(keypress == key.LSHIFT or keypress == key.RSHIFT))
        try self.send_sync_key(event_type.RELEASE, key.LSHIFT, "lshift", modifiers);
    self.mods = modifiers;
}

fn send_sync_key(self: *Self, event_type_: usize, keypress: u32, key_string: []const u8, modifiers: vaxis.Key.Modifiers) !void {
    if (self.dispatch_input) |f| f(
        self.handler_ctx,
        try self.fmtmsg(.{
            "I",
            event_type_,
            keypress,
            keypress,
            key_string,
            @as(u8, @bitCast(modifiers)),
        }),
    );
}
