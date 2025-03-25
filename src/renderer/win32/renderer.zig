const Self = @This();
pub const log_name = "renderer";

const std = @import("std");
const cbor = @import("cbor");
const vaxis = @import("vaxis");
const Style = @import("theme").Style;
const Color = @import("theme").Color;
pub const CursorShape = vaxis.Cell.CursorShape;

pub const Plane = @import("tuirenderer").Plane;
const input = @import("input");

const win32 = @import("win32").everything;

pub const Cell = @import("tuirenderer").Cell;
pub const StyleBits = @import("tuirenderer").style;
const gui = @import("gui");
const DropWriter = gui.DropWriter;
pub const style = StyleBits;
pub const styles = @import("tuirenderer").styles;

pub const Error = error{
    UnexpectedRendererEvent,
    OutOfMemory,
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    VaxisResizeError,
} || std.Thread.SpawnError;

pub const panic = messageBoxThenPanic(.{ .title = "Flow Panic" });

threadlocal var thread_is_panicing = false;
fn messageBoxThenPanic(
    opt: struct {
        title: [:0]const u8,
        style: win32.MESSAGEBOX_STYLE = .{ .ICONASTERISK = 1 },
        // TODO: add option/logic to include the stacktrace in the messagebox
    },
) std.builtin.PanicFn {
    return struct {
        pub fn panic(
            msg: []const u8,
            _: ?*std.builtin.StackTrace,
            ret_addr: ?usize,
        ) noreturn {
            if (!thread_is_panicing) {
                thread_is_panicing = true;
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
                    arena.allocator(),
                    "{s}",
                    .{msg},
                )) |msg_z| msg_z else |_| "failed allocate error message";
                _ = win32.MessageBoxA(null, msg_z, opt.title, opt.style);
            }
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic;
}

allocator: std.mem.Allocator,
vx: vaxis.Vaxis,

handler_ctx: *anyopaque,
dispatch_initialized: *const fn (ctx: *anyopaque) void,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

thread: ?std.Thread = null,

hwnd: ?win32.HWND = null,
title_buf: std.ArrayList(u16),
style_: ?Style = null,

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
    dispatch_initialized: *const fn (ctx: *anyopaque) void,
) Error!Self {
    std.debug.assert(!global.init_called);
    global.init_called = true;

    _ = no_alternate;

    gui.init();
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
    var result: Self = .{
        .allocator = allocator,
        .vx = try vaxis.init(allocator, opts),
        .handler_ctx = handler_ctx,
        .title_buf = std.ArrayList(u16).init(allocator),
        .dispatch_initialized = dispatch_initialized,
    };
    result.vx.caps.unicode = .unicode;
    result.vx.screen.width_method = .unicode;
    return result;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.thread == null);
    var drop_writer = DropWriter{};
    self.vx.deinit(self.allocator, drop_writer.writer().any());
    self.title_buf.deinit();
}

pub fn run(self: *Self) Error!void {
    if (self.thread) |_| return;

    // dummy resize to fully init vaxis
    const drop_writer = DropWriter{};
    self.vx.resize(
        self.allocator,
        drop_writer.writer().any(),
        .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    ) catch return error.VaxisResizeError;

    self.thread = try gui.start();
}

pub fn fmtmsg(buf: []u8, value: anytype) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    cbor.writeValue(fbs.writer(), value) catch |e| switch (e) {
        error.NoSpaceLeft => std.debug.panic("buffer of size {} not big enough", .{buf.len}),
    };
    return buf[0..fbs.pos];
}

pub fn render(self: *Self) error{}!void {
    const hwnd = self.hwnd orelse return;
    _ = gui.updateScreen(hwnd, &self.vx.screen);
}
pub fn stop(self: *Self) void {
    // this is guaranteed because stop won't be called until after
    // the window is created and we call dispatch_initialized
    const hwnd = self.hwnd orelse unreachable;
    gui.stop(hwnd);
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
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

pub fn process_renderer_event(self: *Self, msg: []const u8) Error!void {
    const Input = struct {
        kind: u8,
        codepoint: u21,
        shifted_codepoint: u21,
        text: []const u8,
        mods: u8,
    };
    const MousePos = struct {
        col: i32,
        row: i32,
        xoffset: i32,
        yoffset: i32,
    };
    const Winsize = struct {
        cell_width: u16,
        cell_height: u16,
        pixel_width: u16,
        pixel_height: u16,
    };

    {
        var args: Input = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "I",
            cbor.extract(&args.kind),
            cbor.extract(&args.codepoint),
            cbor.extract(&args.shifted_codepoint),
            cbor.extract(&args.text),
            cbor.extract(&args.mods),
        })) {
            var buf: [300]u8 = undefined;
            const cbor_msg = fmtmsg(&buf, .{
                "I",
                args.kind,
                args.codepoint,
                args.shifted_codepoint,
                args.text,
                args.mods,
            });
            if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            return;
        }
    }

    {
        var args: Winsize = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "Resize",
            cbor.extract(&args.cell_width),
            cbor.extract(&args.cell_height),
            cbor.extract(&args.pixel_width),
            cbor.extract(&args.pixel_height),
        })) {
            var drop_writer = DropWriter{};
            self.vx.resize(self.allocator, drop_writer.writer().any(), .{
                .rows = @intCast(args.cell_height),
                .cols = @intCast(args.cell_width),
                .x_pixel = @intCast(args.pixel_width),
                .y_pixel = @intCast(args.pixel_height),
            }) catch |err| std.debug.panic("resize failed with {s}", .{@errorName(err)});
            self.vx.queueRefresh();
            {
                var buf: [200]u8 = undefined;
                if (self.dispatch_event) |f| f(self.handler_ctx, fmtmsg(&buf, .{"resize"}));
            }
            return;
        }
    }
    {
        var args: MousePos = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "M",
            cbor.extract(&args.col),
            cbor.extract(&args.row),
            cbor.extract(&args.xoffset),
            cbor.extract(&args.yoffset),
        })) {
            var buf: [200]u8 = undefined;
            if (self.dispatch_mouse) |f| f(
                self.handler_ctx,
                @intCast(args.row),
                @intCast(args.col),
                fmtmsg(&buf, .{
                    "M",
                    args.col,
                    args.row,
                    args.xoffset,
                    args.yoffset,
                }),
            );
            return;
        }
    }
    {
        var args: struct {
            pos: MousePos,
            button: struct {
                press: u8,
                id: u8,
            },
        } = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "B",
            cbor.extract(&args.button.press),
            cbor.extract(&args.button.id),
            cbor.extract(&args.pos.col),
            cbor.extract(&args.pos.row),
            cbor.extract(&args.pos.xoffset),
            cbor.extract(&args.pos.yoffset),
        })) {
            var buf: [200]u8 = undefined;
            if (self.dispatch_mouse) |f| f(
                self.handler_ctx,
                @intCast(args.pos.row),
                @intCast(args.pos.col),
                fmtmsg(&buf, .{
                    "B",
                    args.button.press,
                    args.button.id,
                    input.utils.button_id_string(@enumFromInt(args.button.id)),
                    args.pos.col,
                    args.pos.row,
                    args.pos.xoffset,
                    args.pos.yoffset,
                }),
            );
            return;
        }
    }
    {
        var args: struct {
            pos: MousePos,
            button_id: u8,
        } = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "D",
            cbor.extract(&args.button_id),
            cbor.extract(&args.pos.col),
            cbor.extract(&args.pos.row),
            cbor.extract(&args.pos.xoffset),
            cbor.extract(&args.pos.yoffset),
        })) {
            var buf: [200]u8 = undefined;
            if (self.dispatch_mouse_drag) |f| f(
                self.handler_ctx,
                @intCast(args.pos.row),
                @intCast(args.pos.col),
                fmtmsg(&buf, .{
                    "D",
                    input.event.press,
                    args.button_id,
                    input.utils.button_id_string(@enumFromInt(args.button_id)),
                    args.pos.col,
                    args.pos.row,
                    args.pos.xoffset,
                    args.pos.yoffset,
                }),
            );
            return;
        }
    }
    {
        var hwnd: usize = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "WindowCreated",
            cbor.extract(&hwnd),
        })) {
            std.debug.assert(self.hwnd == null);
            self.hwnd = @ptrFromInt(hwnd);
            self.dispatch_initialized(self.handler_ctx);
            self.update_window_title();
            self.update_window_style();
            return;
        }
    }
    return error.UnexpectedRendererEvent;
}

pub fn set_terminal_title(self: *Self, text: []const u8) void {
    self.title_buf.clearRetainingCapacity();
    std.unicode.utf8ToUtf16LeArrayList(&self.title_buf, text) catch {
        std.log.err("title is invalid UTF-8", .{});
        return;
    };
    self.update_window_title();
}

fn update_window_title(self: *Self) void {
    if (self.title_buf.items.len == 0) return;

    // keep the title buf around if the window isn't created yet
    const hwnd = self.hwnd orelse return;

    const title = self.title_buf.toOwnedSliceSentinel(0) catch @panic("OOM:update_window_title");
    if (win32.SetWindowTextW(hwnd, title) == 0) {
        std.log.warn("SetWindowText failed, error={}", .{win32.GetLastError()});
        self.title_buf = std.ArrayList(u16).fromOwnedSlice(self.allocator, title);
    } else {
        self.allocator.free(title);
    }
}

pub fn set_terminal_style(self: *Self, style_: Style) void {
    self.style_ = style_;
    self.update_window_style();
}
fn update_window_style(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    if (self.style_) |style_| {
        if (style_.bg) |color| gui.set_window_background(hwnd, @intCast(color.color));
    }
}

pub fn adjust_fontsize(self: *Self, amount: f32) void {
    const hwnd = self.hwnd orelse return;
    gui.adjust_fontsize(hwnd, amount);
}

pub fn set_fontsize(self: *Self, fontsize: f32) void {
    const hwnd = self.hwnd orelse return;
    gui.set_fontsize(hwnd, fontsize);
}

pub fn reset_fontsize(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    gui.reset_fontsize(hwnd);
}

pub fn set_fontface(self: *Self, fontface: []const u8) void {
    const hwnd = self.hwnd orelse return;
    gui.set_fontface(hwnd, fontface);
}

pub fn reset_fontface(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    gui.reset_fontface(hwnd);
}

pub fn get_fontfaces(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    gui.get_fontfaces(hwnd);
}

pub fn set_terminal_cursor_color(self: *Self, color: Color) void {
    _ = self;
    _ = color;
    //@panic("todo");
}

pub fn set_terminal_working_directory(self: *Self, absolute_path: []const u8) void {
    _ = self;
    _ = absolute_path;
    // this is usually a no-op for GUI renderers
    // it is used by terminals to spawn new windows or splits in the same directory
}

pub const copy_to_windows_clipboard = @import("tuirenderer").copy_to_windows_clipboard;
pub const request_windows_clipboard = @import("tuirenderer").request_windows_clipboard;

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
