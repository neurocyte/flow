const std = @import("std");
const cbor = @import("cbor");
const log = @import("log");
const nc = @import("notcurses");
const Style = @import("theme").Style;

pub const input = @import("input.zig");

pub const Plane = @import("Plane.zig").Plane;
pub const Cell = @import("Cell.zig").Cell;
pub const channels = @import("channels.zig");

pub const style = @import("style.zig").StyleBits;

const mod = input.modifier;
const key = input.key;
const event_type = input.event_type;

const Self = @This();
pub const log_name = "notcurses";

a: std.mem.Allocator,
ctx: nc.Context,

escape_state: EscapeState = .none,
escape_initial: ?nc.Input = null,
escape_code: std.ArrayList(u8),

event_buffer: std.ArrayList(u8),
mods: ModState = .{},
drag: bool = false,
drag_event: nc.Input = nc.input(),
bracketed_paste: bool = false,
bracketed_paste_buffer: std.ArrayList(u8),

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, dragging: bool, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

logger: log.Logger,

const EscapeState = enum { none, init, OSC, st, CSI };
const ModState = struct { ctrl: bool = false, shift: bool = false, alt: bool = false };

pub fn init(a: std.mem.Allocator, handler_ctx: *anyopaque, no_alternate: bool) !Self {
    var opts = nc.Context.Options{
        .termtype = null,
        .loglevel = @intFromEnum(nc.LogLevel.silent),
        .margin_t = 0,
        .margin_r = 0,
        .margin_b = 0,
        .margin_l = 0,
        .flags = nc.Context.option.SUPPRESS_BANNERS | nc.Context.option.INHIBIT_SETLOCALE | nc.Context.option.NO_WINCH_SIGHANDLER,
    };
    if (no_alternate)
        opts.flags |= nc.Context.option.NO_ALTERNATE_SCREEN;
    const nc_ = try nc.Context.core_init(&opts, null);
    nc_.mice_enable(nc.mice.ALL_EVENTS) catch {};
    try nc_.linesigs_disable();
    bracketed_paste_enable();

    return .{
        .a = a,
        .ctx = nc_,
        .escape_code = std.ArrayList(u8).init(a),
        .event_buffer = std.ArrayList(u8).init(a),
        .bracketed_paste_buffer = std.ArrayList(u8).init(a),
        .handler_ctx = handler_ctx,
        .logger = log.logger(log_name),
    };
}

pub fn deinit(self: *Self) void {
    self.escape_code.deinit();
    self.event_buffer.deinit();
    self.bracketed_paste_buffer.deinit();
}

pub fn run(_: *Self) !void {}

pub fn render(self: Self) !void {
    return self.ctx.render();
}

pub fn refresh(self: Self) !void {
    return self.ctx.refresh();
}

pub fn stop(self: Self) void {
    return self.ctx.stop();
}

pub fn stdplane(self: Self) Plane {
    return .{ .plane = self.ctx.stdplane() };
}

pub fn input_fd(self: Self) i32 {
    return self.ctx.inputready_fd();
}

pub fn leave_alternate_screen(self: Self) void {
    return self.ctx.leave_alternate_screen();
}

const InputError = error{
    OutOfMemory,
    InvalidCharacter,
    NoSpaceLeft,
    CborIntegerTooLarge,
    CborIntegerTooSmall,
    CborInvalidType,
    CborTooShort,
    Ucs32toUtf8Error,
    InvalidPadding,
    ReadInputError,
    WouldBlock,
};

pub fn process_input(self: *Self) InputError!void {
    var input_buffer: [256]nc.Input = undefined;

    while (true) {
        const nivec = self.ctx.getvec_nblock(&input_buffer) catch return error.ReadInputError;
        if (nivec.len == 0)
            break;
        for (nivec) |*ni| {
            if (ni.id == 27 or self.escape_state != .none) {
                try self.handle_escape(ni);
                continue;
            }
            self.dispatch_input_event(ni) catch |e|
                self.logger.err("input dispatch", e);
        }
    }
    if (self.escape_state == .init)
        try self.handle_escape_short();
}

fn fmtmsg(self: *Self, value: anytype) ![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(self.event_buffer.writer(), value);
    return self.event_buffer.items;
}

fn dispatch_input_event(self: *Self, ni: *nc.Input) !void {
    const keypress: u32 = ni.id;
    ni.modifiers &= mod.CTRL | mod.SHIFT | mod.ALT | mod.SUPER | mod.META | mod.HYPER;
    if (keypress == key.RESIZE) return;
    try self.sync_mod_state(keypress, ni.modifiers);
    if (keypress == key.MOTION) {
        if (ni.y == 0 and ni.x == 0 and ni.ypx == -1 and ni.xpx == -1) return;
        if (self.dispatch_mouse) |f| f(
            self.handler_ctx,
            ni.y,
            ni.x,
            try self.fmtmsg(.{
                "M",
                ni.x,
                ni.y,
                ni.xpx,
                ni.ypx,
            }),
        );
    } else if (keypress > key.MOTION and keypress <= key.BUTTON11) {
        if (ni.y == 0 and ni.x == 0 and ni.ypx == -1 and ni.xpx == -1) return;
        if (try self.detect_drag(ni)) return;
        if (self.dispatch_mouse) |f| f(
            self.handler_ctx,
            ni.y,
            ni.x,
            try self.fmtmsg(.{
                "B",
                ni.evtype,
                keypress,
                input.utils.key_string(ni),
                ni.x,
                ni.y,
                ni.xpx,
                ni.ypx,
            }),
        );
    } else {
        const cbor_msg = try self.fmtmsg(.{
            "I",
            normalized_evtype(ni.evtype),
            keypress,
            if (@hasField(nc.Input, "eff_text")) ni.eff_text[0] else keypress,
            input.utils.key_string(ni),
            ni.modifiers,
        });
        if (self.bracketed_paste and self.handle_bracketed_paste_input(cbor_msg) catch |e| {
            self.bracketed_paste_buffer.clearAndFree();
            self.bracketed_paste = false;
            return e;
        }) {} else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
    }
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

fn normalized_evtype(evtype: c_uint) c_uint {
    return if (evtype == event_type.UNKNOWN) @as(c_uint, @intCast(event_type.PRESS)) else evtype;
}

fn sync_mod_state(self: *Self, keypress: u32, modifiers: u32) !void {
    if (input.utils.isCtrl(modifiers) and !self.mods.ctrl and !(keypress == key.LCTRL or keypress == key.RCTRL))
        try self.send_sync_key(event_type.PRESS, key.LCTRL, "lctrl", modifiers);
    if (!input.utils.isCtrl(modifiers) and self.mods.ctrl and !(keypress == key.LCTRL or keypress == key.RCTRL))
        try self.send_sync_key(event_type.RELEASE, key.LCTRL, "lctrl", modifiers);
    if (input.utils.isAlt(modifiers) and !self.mods.alt and !(keypress == key.LALT or keypress == key.RALT))
        try self.send_sync_key(event_type.PRESS, key.LALT, "lalt", modifiers);
    if (!input.utils.isAlt(modifiers) and self.mods.alt and !(keypress == key.LALT or keypress == key.RALT))
        try self.send_sync_key(event_type.RELEASE, key.LALT, "lalt", modifiers);
    if (input.utils.isShift(modifiers) and !self.mods.shift and !(keypress == key.LSHIFT or keypress == key.RSHIFT))
        try self.send_sync_key(event_type.PRESS, key.LSHIFT, "lshift", modifiers);
    if (!input.utils.isShift(modifiers) and self.mods.shift and !(keypress == key.LSHIFT or keypress == key.RSHIFT))
        try self.send_sync_key(event_type.RELEASE, key.LSHIFT, "lshift", modifiers);
    self.mods = .{
        .ctrl = input.utils.isCtrl(modifiers),
        .alt = input.utils.isAlt(modifiers),
        .shift = input.utils.isShift(modifiers),
    };
}

fn send_sync_key(self: *Self, event_type_: c_int, keypress: u32, key_string: []const u8, modifiers: u32) !void {
    if (self.dispatch_input) |f| f(
        self.handler_ctx,
        try self.fmtmsg(.{
            "I",
            event_type_,
            keypress,
            keypress,
            key_string,
            modifiers,
        }),
    );
}

fn detect_drag(self: *Self, ni: *nc.Input) !bool {
    return switch (ni.id) {
        key.BUTTON1...key.BUTTON3, key.BUTTON6...key.BUTTON9 => if (self.drag) self.detect_drag_end(ni) else self.detect_drag_begin(ni),
        else => false,
    };
}

fn detect_drag_begin(self: *Self, ni: *nc.Input) !bool {
    if (ni.evtype == event_type.PRESS and self.drag_event.id == ni.id) {
        self.drag_event = ni.*;
        self.drag = true;
        if (self.dispatch_mouse_drag) |f| f(
            self.handler_ctx,
            ni.y,
            ni.x,
            true,
            try self.fmtmsg(.{
                "D",
                event_type.PRESS,
                ni.id,
                input.utils.key_string(ni),
                ni.x,
                ni.y,
                ni.xpx,
                ni.ypx,
            }),
        );
        return true;
    }
    if (ni.evtype == event_type.PRESS)
        self.drag_event = ni.*
    else
        self.drag_event = nc.input();
    return false;
}

fn detect_drag_end(self: *Self, ni: *nc.Input) !bool {
    if (ni.id == self.drag_event.id and ni.evtype != event_type.PRESS) {
        if (self.dispatch_mouse_drag) |f| f(
            self.handler_ctx,
            ni.y,
            ni.x,
            false,
            try self.fmtmsg(.{
                "D",
                event_type.RELEASE,
                ni.id,
                input.utils.key_string(ni),
                ni.x,
                ni.y,
                ni.xpx,
                ni.ypx,
            }),
        );
        self.drag = false;
        self.drag_event = nc.input();
    } else if (self.dispatch_mouse_drag) |f| f(
        self.handler_ctx,
        ni.y,
        ni.x,
        true,
        try self.fmtmsg(.{
            "D",
            ni.evtype,
            ni.id,
            input.utils.key_string(ni),
            ni.x,
            ni.y,
            ni.xpx,
            ni.ypx,
        }),
    );
    return true;
}

fn handle_escape(self: *Self, ni: *nc.Input) !void {
    switch (self.escape_state) {
        .none => switch (ni.id) {
            '\x1B' => {
                self.escape_state = .init;
                self.escape_initial = ni.*;
            },
            else => unreachable,
        },
        .init => switch (ni.id) {
            ']' => self.escape_state = .OSC,
            '[' => self.escape_state = .CSI,
            else => {
                try self.handle_escape_short();
                _ = try self.dispatch_input_event(ni);
            },
        },
        .OSC => switch (ni.id) {
            '\x1B' => self.escape_state = .st,
            '\\' => try self.handle_OSC_escape_code(),
            ' '...'\\' - 1, '\\' + 1...127 => {
                const p = try self.escape_code.addOne();
                p.* = @intCast(ni.id);
            },
            else => try self.handle_OSC_escape_code(),
        },
        .st => switch (ni.id) {
            '\\' => try self.handle_OSC_escape_code(),
            else => try self.handle_OSC_escape_code(),
        },
        .CSI => switch (ni.id) {
            '0'...'9', ';', ' ', '-', '?' => {
                const p = try self.escape_code.addOne();
                p.* = @intCast(ni.id);
            },
            else => {
                const p = try self.escape_code.addOne();
                p.* = @intCast(ni.id);
                try self.handle_CSI_escape_code();
            },
        },
    }
}

fn handle_escape_short(self: *Self) !void {
    self.escape_code.clearAndFree();
    self.escape_state = .none;
    defer self.escape_initial = null;
    if (self.escape_initial) |*ni|
        _ = try self.dispatch_input_event(ni);
}

fn match_code(self: Self, match: []const u8, skip: usize) bool {
    const code = self.escape_code.items;
    if (!(code.len >= match.len - skip)) return false;
    const code_prefix = code[0 .. match.len - skip];
    return std.mem.eql(u8, match[skip..], code_prefix);
}

const OSC = "\x1B]"; // Operating System Command
const ST = "\x1B\\"; // String Terminator
const BEL = "\x07";
const OSC0_title = OSC ++ "0;";
const OSC52_clipboard = OSC ++ "52;c;";
const OSC52_clipboard_paste = OSC ++ "52;p;";
const OSC22_cursor = OSC ++ "22;";
const OSC22_cursor_reply = OSC ++ "22:";

fn handle_OSC_escape_code(self: *Self) !void {
    self.escape_state = .none;
    self.escape_initial = null;
    defer self.escape_code.clearAndFree();
    const code = self.escape_code.items;
    if (self.match_code(OSC52_clipboard, OSC.len))
        return self.handle_system_clipboard(code[OSC52_clipboard.len - OSC.len ..]);
    if (self.match_code(OSC52_clipboard_paste, OSC.len))
        return self.handle_system_clipboard(code[OSC52_clipboard_paste.len - OSC.len ..]);
    if (self.match_code(OSC22_cursor_reply, OSC.len))
        return self.handle_mouse_cursor(code[OSC22_cursor_reply.len - OSC.len ..]);
    self.logger.print("ignored escape code: OSC {s}", .{std.fmt.fmtSliceEscapeLower(code)});
}

fn handle_system_clipboard(self: *Self, base64: []const u8) !void {
    const decoder = std.base64.standard.Decoder;
    const text = try self.a.alloc(u8, try decoder.calcSizeForSlice(base64));
    defer self.a.free(text);
    try decoder.decode(text, base64);
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", text }));
}

fn handle_mouse_cursor(self: Self, text: []const u8) !void {
    self.logger.print("mouse cursor report: {s}", .{text});
}

const CSI = "\x1B["; // Control Sequence Introducer
const CSI_bracketed_paste_enable = CSI ++ "?2004h";
const CSI_bracketed_paste_disable = CSI ++ "?2004h";
const CIS_bracketed_paste_begin = CSI ++ "200~";
const CIS_bracketed_paste_end = CSI ++ "201~";

fn bracketed_paste_enable() void {
    write_stdout(CSI_bracketed_paste_enable);
}

fn bracketed_paste_disable() void {
    write_stdout(CSI_bracketed_paste_disable);
}

fn handle_CSI_escape_code(self: *Self) !void {
    self.escape_state = .none;
    self.escape_initial = null;
    defer self.escape_code.clearAndFree();
    const code = self.escape_code.items;
    if (self.match_code(CIS_bracketed_paste_begin, CSI.len))
        return self.handle_bracketed_paste_begin();
    if (self.match_code(CIS_bracketed_paste_end, CSI.len))
        return self.handle_bracketed_paste_end();
    self.logger.print("ignored escape code: CSI {s}", .{std.fmt.fmtSliceEscapeLower(code)});
}

fn handle_bracketed_paste_begin(self: *Self) !void {
    self.bracketed_paste_buffer.clearAndFree();
    self.bracketed_paste = true;
}

fn handle_bracketed_paste_end(self: *Self) !void {
    defer self.bracketed_paste_buffer.clearAndFree();
    if (!self.bracketed_paste) return;
    self.bracketed_paste = false;
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", self.bracketed_paste_buffer.items }));
}

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

pub fn cursor_enable(self: Self, y: c_int, x: c_int) !void {
    return self.ctx.cursor_enable(y, x);
}

pub fn cursor_disable(self: Self) void {
    self.ctx.cursor_disable() catch {};
}

pub const ucs32_to_utf8 = nc.ucs32_to_utf8;
