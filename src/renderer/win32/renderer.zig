const Self = @This();
pub const log_name = "renderer";

const std = @import("std");
const cbor = @import("cbor");
const thespian = @import("thespian");
const vaxis = @import("vaxis");
const Style = @import("theme").Style;
const Color = @import("theme").Color;
const Buffer = @import("Buffer");
pub const CursorShape = vaxis.Cell.CursorShape;

pub const Plane = @import("tuirenderer").Plane;
const input = @import("input");

const win32 = @import("win32").everything;

pub const Cell = @import("tuirenderer").Cell;
pub const StyleBits = @import("tuirenderer").style;
const guithread = @import("guithread.zig");
const DropWriter = guithread.DropWriter;
pub const style = StyleBits;

allocator: std.mem.Allocator,
vx: vaxis.Vaxis,

renders_missed: u32 = 0,

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

thread: ?std.Thread = null,

const global = struct {
    var init_called: bool = false;
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn init(
    allocator: std.mem.Allocator,
    handler_ctx: *anyopaque,
    no_alternate: bool,
) !Self {
    std.debug.assert(!global.init_called);
    global.init_called = true;

    _ = no_alternate;

    guithread.init();
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
    var result = .{
        .allocator = allocator,
        .vx = try vaxis.init(allocator, opts),
        .handler_ctx = handler_ctx,
    };
    result.vx.caps.unicode = .unicode;
    result.vx.screen.width_method = .unicode;
    return result;
}

pub fn deinit(self: *Self) void {
    std.log.warn("TODO: implement win32 renderer deinit", .{});
    var drop_writer = DropWriter{};
    self.vx.deinit(self.allocator, drop_writer.writer().any());
}

threadlocal var thread_is_panicing = false;

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            std.heap.page_allocator,
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "Flow Panic", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub fn run(self: *Self) !void {
    if (self.thread) |_| return;

    // dummy resize to fully init vaxis
    const drop_writer = DropWriter{};
    try self.vx.resize(
        self.allocator,
        drop_writer.writer().any(),
        .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    );
    self.vx.queueRefresh();
    //if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"resize"}));
    self.thread = try guithread.start();
}

pub fn fmtmsg(buf: []u8, value: anytype) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    cbor.writeValue(fbs.writer(), value) catch |e| switch (e) {
        error.NoSpaceLeft => std.debug.panic("buffer of size {} not big enough", .{buf.len}),
    };
    return buf[0..fbs.pos];
}

pub fn render(self: *Self) error{}!void {
    if (!guithread.updateScreen(&self.vx.screen)) {
        self.renders_missed += 1;
        std.log.warn("missed {} renders, no gui window yet", .{self.renders_missed});
    }
}
pub fn stop(self: *Self) void {
    _ = self;
    std.log.warn("TODO: implement stop", .{});
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
    _ = self;
    @panic("todo");
}
pub fn leave_alternate_screen(self: *Self) void {
    _ = self;
    @panic("todo");
}
pub fn process_gui_event(self: *Self, m: thespian.message) !void {
    var mouse: struct {
        col: i32,
        row: i32,
        xoffset: i32,
        yoffset: i32,
    } = undefined;
    var button: struct {
        press: u8,
        id: u8,
    } = undefined;
    var winsize: struct {
        cell_width: u16,
        cell_height: u16,
        pixel_width: u16,
        pixel_height: u16,
    } = undefined;

    if (try m.match(.{
        thespian.any,
        "Resize",
        thespian.extract(&winsize.cell_width),
        thespian.extract(&winsize.cell_height),
        thespian.extract(&winsize.pixel_width),
        thespian.extract(&winsize.pixel_height),
    })) {
        var drop_writer = DropWriter{};
        self.vx.resize(self.allocator, drop_writer.writer().any(), .{
            .rows = @intCast(winsize.cell_height),
            .cols = @intCast(winsize.cell_width),
            .x_pixel = @intCast(winsize.pixel_width),
            .y_pixel = @intCast(winsize.pixel_height),
        }) catch |err| std.debug.panic("resize failed with {s}", .{@errorName(err)});
        self.vx.queueRefresh();
        {
            var buf: [200]u8 = undefined;
            if (self.dispatch_event) |f| f(self.handler_ctx, fmtmsg(&buf, .{"resize"}));
        }
    } else if (try m.match(.{
        thespian.any,
        "M",
        thespian.extract(&mouse.col),
        thespian.extract(&mouse.row),
        thespian.extract(&mouse.xoffset),
        thespian.extract(&mouse.yoffset),
    })) {
        var buf: [200]u8 = undefined;
        if (self.dispatch_mouse) |f| f(
            self.handler_ctx,
            @intCast(mouse.row),
            @intCast(mouse.col),
            fmtmsg(&buf, .{
                "M",
                mouse.col,
                mouse.row,
                mouse.xoffset,
                mouse.yoffset,
            }),
        );
    } else if (try m.match(.{
        thespian.any,
        "B",
        thespian.extract(&button.press),
        thespian.extract(&button.id),
        thespian.extract(&mouse.col),
        thespian.extract(&mouse.row),
        thespian.extract(&mouse.xoffset),
        thespian.extract(&mouse.yoffset),
    })) {
        var buf: [200]u8 = undefined;
        if (self.dispatch_mouse) |f| f(
            self.handler_ctx,
            @intCast(mouse.row),
            @intCast(mouse.col),
            fmtmsg(&buf, .{
                "B",
                button.press,
                button.id,
                input.utils.button_id_string(@enumFromInt(button.id)),
                mouse.col,
                mouse.row,
                mouse.xoffset,
                mouse.yoffset,
            }),
        );
    } else return thespian.unexpected(m);
}

pub fn process_input_event(self: *Self, input_: []const u8, text: ?[]const u8) !void {
    _ = self;
    _ = input_;
    _ = text;
    @panic("todo");
}
pub fn set_terminal_title(self: *Self, text: []const u8) void {
    _ = self;
    std.log.warn("TODO: set_terminal_title '{s}'", .{text});
}
pub fn set_terminal_style(self: *Self, style_: Style) void {
    _ = self;
    _ = style_;
    std.log.warn("TODO: implement set_terminal_style", .{});
    //if (style_.fg) |color|
    //self.vx.setTerminalForegroundColor(self.tty.anyWriter(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
    //if (style_.bg) |color|
    //self.vx.setTerminalBackgroundColor(self.tty.anyWriter(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
}

pub fn set_terminal_cursor_color(self: *Self, color: Color) void {
    _ = self;
    std.log.warn("TODO: set_terminal_cursor_color '{any}'", .{color});
    //self.vx.setTerminalCursorColor(self.tty.anyWriter(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
}

pub fn set_terminal_working_directory(self: *Self, absolute_path: []const u8) void {
    _ = self;
    std.log.warn("TODO: set_terminal_working_directory '{s}'", .{absolute_path});
    //self.vx.setTerminalWorkingDirectory(self.tty.anyWriter(), absolute_path) catch {};
}
pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    _ = self;
    _ = text;
    @panic("todo");
}
pub fn request_system_clipboard(self: *Self) void {
    _ = self;
    @panic("todo");
}
pub fn request_windows_clipboard(self: *Self) ![]u8 {
    _ = self;
    @panic("todo");
}
pub fn request_mouse_cursor_text(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    //@panic("todo");
}
pub fn request_mouse_cursor_pointer(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    //@panic("todo");
}
pub fn request_mouse_cursor_default(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    //@panic("todo");
}
pub fn cursor_enable(self: *Self, y: c_int, x: c_int, shape: CursorShape) !void {
    _ = self;
    _ = y;
    _ = x;
    _ = shape;
    //@panic("todo");
}
pub fn cursor_disable(self: *Self) void {
    _ = self;
    //@panic("todo");
}
pub fn ucs32_to_utf8(ucs32: []const u32, utf8: []u8) !usize {
    _ = ucs32;
    _ = utf8;
    @panic("todo");
}