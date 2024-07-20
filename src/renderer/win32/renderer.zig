const Self = @This();
pub const log_name = "gui";

const std = @import("std");
//const cbor = @import("cbor");
const vaxis = @import("vaxis");
const Style = @import("theme").Style;
const Buffer = @import("Buffer");

pub const Plane = @import("tuirenderer").Plane;
pub const input = @import("tuirenderer").input;
const dui = @import("dui.zig");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.direct2d;
    usingnamespace @import("win32").graphics.direct2d.common;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").system.memory;
    usingnamespace @import("win32").ui.hi_dpi;
    usingnamespace @import("win32").ui.input.keyboard_and_mouse;
    usingnamespace @import("win32").ui.shell;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
};

pub const Cell = @import("tuirenderer").Cell;
pub const StyleBits = @import("tuirenderer").style;
pub const style = StyleBits;

allocator: std.mem.Allocator,
vx: vaxis.Vaxis,

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

thread: ?std.Thread = null,

fn oom(e: error{OutOfMemory}) noreturn { @panic(@errorName(e)); }

pub fn init(
    allocator: std.mem.Allocator,
    handler_ctx: *anyopaque,
    no_alternate: bool,
) !Self {
    _ = no_alternate;
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

const DropWriter = struct {
    pub const WriteError = error{};
    pub const Writer = std.io.Writer(DropWriter, WriteError, write);
    pub fn writer(self: DropWriter) Writer {
        return .{ .context = self };
    }
    pub fn write(self: DropWriter, bytes: []const u8) WriteError!usize {
        _ = self;
        return bytes.len;
    }

};

pub fn deinit(self: *Self) void {
    std.log.warn("TODO: implement win32 renderer deinit", .{});
    var drop_writer = DropWriter{ };
    self.vx.deinit(self.allocator, drop_writer.writer().any());
}
//pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
//    _ =
//    _ = msg;
//    _ = error_return_trace;
//    _ = ret_addr;
//    @panic("todo");
//}
pub fn run(self: *Self) !void {
    if (self.thread) |_| return;

    // dummy resize to fully init vaxis
    const drop_writer = DropWriter{ };
    try self.vx.resize(self.allocator, drop_writer.writer().any(), .{
        .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0
    });
    self.vx.queueRefresh();
    //if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"resize"}));

    self.thread = try std.Thread.spawn(.{}, thread_entry, .{self});
}

//fn fmtmsg(self: *Self, value: anytype) ![]const u8 {
//    self.event_buffer.clearRetainingCapacity();
//    try cbor.writeValue(self.event_buffer.writer(), value);
//    return self.event_buffer.items;
//}


const window_style_ex = win32.WINDOW_EX_STYLE{
    //.ACCEPTFILES = 1,
};
const window_style = win32.WS_OVERLAPPEDWINDOW;

fn d2dColorFromVAxis(c: vaxis.Cell.Color) win32.D2D1_COLOR_F {
    return switch (c) {
        .default => .{ .r = 1, .g = 0, .b = 0, .a = 1},
        .index => @panic("todo: color index"),
        .rgb => |rgb| .{
            .r = @as(f32, @floatFromInt(rgb[0])) / 255.0,
            .g = @as(f32, @floatFromInt(rgb[1])) / 255.0,
            .b = @as(f32, @floatFromInt(rgb[2])) / 255.0,
            .a = 1
        },
    };
}

const WindowData = struct {
    renderer: *Self,
    ui: dui.Ui,
    erase_bg_done: bool = false,
    pub fn deinit(self: *WindowData) void {
        self.ui.deinit();
        self.* = undefined;
    }
    fn paint(self: WindowData, dpi: u32, client_size: win32.D2D_SIZE_U) void {

        _ = client_size;

        const cell_width: i32 = dui.scale_dpi_i32(15, dpi);
        const cell_height : i32 = dui.scale_dpi_i32(30, dpi);
        for (0 .. self.renderer.vx.screen.height) |y| {
            const row_y = cell_height * @as(i32, @intCast(y));
            for (0 .. self.renderer.vx.screen.width) |x| {
                const column_x = cell_width * @as(i32, @intCast(x));
                const cell_index = self.renderer.vx.screen.width * y + x;
                const cell = &self.renderer.vx.screen.buf[cell_index];

                {
                    var rect: win32.D2D_RECT_F = .{
                        .left = @floatFromInt(column_x),
                        .top = @floatFromInt(row_y),
                        .right = @floatFromInt(column_x + cell_width),
                        .bottom = @floatFromInt(row_y + cell_height),
                    };
                    const c: win32.D2D1_COLOR_F = .{
                        .r = 0,
                        .g = 1,
                        .b = (
                            @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.renderer.vx.screen.height))
                        ),
                        .a = 0.5,
                    };
                    var brush: *win32.ID2D1SolidColorBrush = undefined;
                    {
                        const hr = self.ui.render.CreateSolidColorBrush(
                            &c,
                            null,
                            @ptrCast(&brush),
                        );
                        if (hr != win32.S_OK) apifatal("CreateSolidBrush", hr);
                    }
                    defer _ = brush.IUnknown.Release();
                    self.ui.render.FillRectangle(
                        &rect, @ptrCast(brush)
                    );
                }
                {
                    var rect: win32.D2D_RECT_F = .{
                        .left = @floatFromInt(column_x + @divFloor(cell_width, 4)),
                        .top = @floatFromInt(row_y + @divFloor(cell_height, 4)),
                        .right = @floatFromInt(column_x + @divFloor(cell_width, 2)),
                        .bottom = @floatFromInt(row_y + @divFloor(cell_height, 2)),
                    };
                    const c = d2dColorFromVAxis(cell.style.fg);
                    var brush: *win32.ID2D1SolidColorBrush = undefined;
                    {
                        const hr = self.ui.render.CreateSolidColorBrush(
                            &c,
                            null,
                            @ptrCast(&brush),
                        );
                        if (hr != win32.S_OK) apifatal("CreateSolidBrush", hr);
                    }
                    defer _ = brush.IUnknown.Release();
                    self.ui.render.FillRectangle(
                        &rect, @ptrCast(brush)
                    );
                }
            }
        }

    }
};
fn getWindowData(hwnd: win32.HWND) *WindowData {
    const data: ?*WindowData = @ptrFromInt(@as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
    if (data == null) @panic("codebug");
    return data.?;
}

const CreateWindowArgs = struct {
    allocator: std.mem.Allocator,
    renderer: *Self,
};

fn thread_entry(self: *Self) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    //const icons = getIcons();
    const CLASS_NAME = win32.L("Flow");
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = WndProc,
        .cbClsExtra = 0,
        .cbWndExtra = @sizeOf(*WindowData),
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = null, //icons.large,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null, //icons.small,
    };
    const class_id = win32.RegisterClassExW(&wc);
    if (class_id == 0) {
        std.log.err("RegisterClass failed, error={}", .{win32.GetLastError()});
        std.process.exit(0xff);
    }

    var create_args = CreateWindowArgs{
        .allocator = arena_instance.allocator(),
        .renderer = self,
    };
    const hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME, // Window class
        win32.L("Flow"),
        window_style,
        win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, // position
        800, 600,
        null, // Parent window
        null, // Menu
        win32.GetModuleHandleW(null), // Instance handle
        @ptrCast(&create_args), // Additional application data
    ) orelse {
        std.log.err("CreateWindow failed with {}", .{win32.GetLastError()});
        std.process.exit(0xff);
    };
    defer {
        if (0 == win32.DestroyWindow(hwnd)) std.debug.panic(
            "DestroyWindow failed, error={}", .{win32.GetLastError()}
        );
    }

    //resizeWindowToViewport();
    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        // No need for TranslateMessage since we don't use WM_*CHAR messages
        //_ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn WndProc(
    hwnd: win32.HWND,
    uMsg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_PAINT => {
            const data = getWindowData(hwnd);

            var ps: win32.PAINTSTRUCT = undefined;
            const dpi = getWindowDpi(hwnd);
            const client_size = getClientSize(hwnd);

            {
                var err: dui.Error = undefined;
                data.ui.beginPaintHwnd(&ps, dpi, client_size, &err) catch |ec| switch (ec) {
                    error.Dui => std.debug.panic(
                        "Direct2D error (BeginDraw), context={s}, hresult=0x{x}",
                        .{@tagName(err.context), err.hr},
                    ),
                };
            }

            data.paint(dpi, client_size);

            {
                var err: dui.Error = undefined;
                data.ui.endPaintHwnd(&ps, &err) catch |ec| switch (ec) {
                    error.Dui => std.debug.panic(
                        "Direct2D error (EndDraw), context={s}, hresult=0x{x}",
                        .{@tagName(err.context), err.hr},
                    ),
                };
            }

            return 0;
        },
        win32.WM_SIZE => {
            // since we "stretch" the image accross the full window, we
            // always invalidate the full client area on each window resize
            std.debug.assert(0 != win32.InvalidateRect(hwnd, null, 0));
        },
        win32.WM_ERASEBKGND => {
            const data = getWindowData(hwnd);
            if (!data.erase_bg_done) {
                data.erase_bg_done = true;
                const brush = win32.CreateSolidBrush(toColorRef(.{.r=29,.g=29,.b=29})) orelse
                    std.debug.panic("CreateSolidBrush failed, error={}", .{win32.GetLastError()});
                defer deleteObject(brush);
                const hdc: win32.HDC = @ptrFromInt(wparam);
                var rect: win32.RECT = undefined;
                if (0 == win32.GetClientRect(hwnd, &rect)) @panic("");
                if (0 == win32.FillRect(hdc, &rect, brush)) @panic("");
            }
            return 1; // background erased
        },
        win32.WM_CLOSE => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_CREATE => {
            const data: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const create_args: *CreateWindowArgs = @alignCast(@ptrCast(data.lpCreateParams));
            const window_data = create_args.allocator.create(WindowData) catch |e| oom(e);

            var err: dui.Error = .{};
            window_data.* = .{
                .renderer = create_args.renderer,
                .ui = dui.initHwnd(hwnd, &err, .{}) catch std.debug.panic(
                    "Direct2D error, context={s}, hresult=0x{x}",
                    .{ @tagName(err.context), err.hr },
                ),
            };
            const existing = win32.SetWindowLongPtrW(
                hwnd,
                @enumFromInt(0),
                @as(isize, @bitCast(@intFromPtr(window_data))),
            );
            std.debug.assert(existing == 0);
            std.debug.assert(window_data == getWindowData(hwnd));
        },
        win32.WM_DESTROY => {
            const data = getWindowData(hwnd);
            data.deinit();
            // no need to free, it was allocated via an arena
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wparam, lparam);
}

pub const Rgb8 = struct { r: u8, g: u8, b: u8 };
fn toColorRef(rgb: Rgb8) u32 {
    return (@as(u32, rgb.r) << 0) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}
pub fn apifatal(function: []const u8, err: anytype) noreturn {
    std.debug.panic("function '{s}' unexpectedly failed, error={}", .{function, err});
}
fn getWindowDpi(hwnd: win32.HWND) u32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    if (dpi == 0) @panic("race condition detected"); // invalid hwnd, must be race condition
    std.debug.assert(dpi >= 96);
    return dpi;
}
fn deleteObject(obj: ?win32.HGDIOBJ) void {
    if (0 == win32.DeleteObject(obj)) std.debug.panic(
        "DeleteObject failed, error={}", .{win32.GetLastError()}
    );
}
fn getClientSize(hwnd: win32.HWND) win32.D2D_SIZE_U {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        apifatal("GetClientRect", win32.GetLastError());
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

pub fn render(self: *Self) !void {
    //var bufferedWriter = self.tty.bufferedWriter();
    //try self.vx.render(bufferedWriter.writer().any());
    //try bufferedWriter.flush();
    _ = self;
    std.log.warn("TODO: render", .{});
}
pub fn query_resize(self: *Self) !void {
    _ = self;
    return error.todo;
    //if (builtin.os.tag != .windows)
    //try self.resize(try vaxis.Tty.getWinsize(self.input_fd_blocking()));
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
pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    _ = self;
    _ = text;
    @panic("todo");
}
pub fn request_system_clipboard(self: *Self) void {
    _ = self;
    @panic("todo");
}
pub fn request_mouse_cursor_text(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    @panic("todo");
}
pub fn request_mouse_cursor_pointer(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    @panic("todo");
}
pub fn request_mouse_cursor_default(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    @panic("todo");
}
pub fn cursor_enable(self: *Self, y: c_int, x: c_int) !void {
    _ = self;
    _ = y;
    _ = x;
    @panic("todo");
}
pub fn cursor_disable(self: *Self) void {
    _ = self;
    @panic("todo");
}
pub fn ucs32_to_utf8(ucs32: []const u32, utf8: []u8) !usize {
    _ = ucs32;
    _ = utf8;
    @panic("todo");
}
