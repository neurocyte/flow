const std = @import("std");

const c = @cImport({
    @cInclude("ResourceNames.h");
});

const win32 = @import("win32").everything;
const ddui = @import("ddui");

const cbor = @import("cbor");
const thespian = @import("thespian");
const vaxis = @import("vaxis");

const input = @import("input");
const windowmsg = @import("windowmsg.zig");

const HResultError = ddui.HResultError;

pub const DropWriter = struct {
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

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn onexit(e: error{Exit}) void {
    switch (e) {
        error.Exit => {},
    }
}

const global = struct {
    var mutex: std.Thread.Mutex = .{};

    var init_called: bool = false;
    var start_called: bool = false;
    var icons: Icons = undefined;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    var d2d_factory: *win32.ID2D1Factory = undefined;
    var window_class: u16 = 0;
    var hwnd: ?win32.HWND = null;
};
const window_style_ex = win32.WINDOW_EX_STYLE{
    //.ACCEPTFILES = 1,
};
const window_style = win32.WS_OVERLAPPEDWINDOW;

pub fn init() void {
    std.debug.assert(!global.init_called);
    global.init_called = true;

    global.icons = getIcons();

    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&global.dwrite_factory),
        );
        if (hr < 0) fatalHr("DWriteCreateFactory", hr);
    }
    {
        var err: HResultError = undefined;
        global.d2d_factory = ddui.createFactory(
            .SINGLE_THREADED,
            .{},
            &err,
        ) catch std.debug.panic("{}", .{err});
    }
}

const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};
fn getIcons() Icons {
    const small_x = win32.GetSystemMetrics(.CXSMICON);
    const small_y = win32.GetSystemMetrics(.CYSMICON);
    const large_x = win32.GetSystemMetrics(.CXICON);
    const large_y = win32.GetSystemMetrics(.CYICON);
    std.log.info("icons small={}x{} large={}x{}", .{
        small_x, small_y,
        large_x, large_y,
    });
    const small = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(c.ID_ICON_FLOW),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ) orelse fatalWin32("LoadImage for small icon", win32.GetLastError());
    const large = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(c.ID_ICON_FLOW),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ) orelse fatalWin32("LoadImage for large icon", win32.GetLastError());
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}

fn d2dColorFromVAxis(color: vaxis.Cell.Color) win32.D2D_COLOR_F {
    return switch (color) {
        .default => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .index => @panic("todo: color index"),
        .rgb => |rgb| .{
            .r = @as(f32, @floatFromInt(rgb[0])) / 255.0,
            .g = @as(f32, @floatFromInt(rgb[1])) / 255.0,
            .b = @as(f32, @floatFromInt(rgb[2])) / 255.0,
            .a = 1,
        },
    };
}

const Dpi = struct {
    value: u32,
    pub fn eql(self: Dpi, other: Dpi) bool {
        return self.value == other.value;
    }
};

fn createTextFormatEditor(dpi: Dpi) *win32.IDWriteTextFormat {
    var err: HResultError = undefined;
    return ddui.createTextFormat(global.dwrite_factory, &err, .{
        .size = win32.scaleDpi(f32, 14, dpi.value),
        .family_name = win32.L("Cascadia Code"),
        .center_x = true,
        .center_y = true,
    }) catch std.debug.panic("{s} failed, hresult=0x{x}", .{ err.context, err.hr });
}

const D2d = struct {
    target: *win32.ID2D1HwndRenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    pub fn init(hwnd: win32.HWND, err: *HResultError) error{HResult}!D2d {
        var target: *win32.ID2D1HwndRenderTarget = undefined;
        const target_props = win32.D2D1_RENDER_TARGET_PROPERTIES{
            .type = .DEFAULT,
            .pixelFormat = .{
                .format = .B8G8R8A8_UNORM,
                .alphaMode = .PREMULTIPLIED,
            },
            .dpiX = 0,
            .dpiY = 0,
            .usage = .{},
            .minLevel = .DEFAULT,
        };
        const hwnd_target_props = win32.D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = hwnd,
            .pixelSize = .{ .width = 0, .height = 0 },
            .presentOptions = .{},
        };

        {
            const hr = global.d2d_factory.CreateHwndRenderTarget(
                &target_props,
                &hwnd_target_props,
                &target,
            );
            if (hr < 0) return err.set(hr, "CreateHwndRenderTarget");
        }
        errdefer _ = target.IUnknown.Release();

        {
            var dc: *win32.ID2D1DeviceContext = undefined;
            {
                const hr = target.IUnknown.QueryInterface(win32.IID_ID2D1DeviceContext, @ptrCast(&dc));
                if (hr < 0) return err.set(hr, "GetDeviceContext");
            }
            defer _ = dc.IUnknown.Release();
            // just make everything DPI aware, all applications should just do this
            dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);
        }

        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const hr = target.ID2D1RenderTarget.CreateSolidColorBrush(&color, null, &brush);
            if (hr < 0) return err.set(hr, "CreateSolidBrush");
        }
        errdefer _ = brush.IUnknown.Release();

        return .{
            .target = target,
            .brush = brush,
        };
    }
    pub fn deinit(self: *D2d) void {
        _ = self.brush.IUnknown.Release();
        _ = self.target.IUnknown.Release();
    }
    pub fn solid(self: *const D2d, color: win32.D2D_COLOR_F) *win32.ID2D1Brush {
        self.brush.SetColor(&color);
        return &self.brush.ID2D1Brush;
    }
};

const State = struct {
    pid: thespian.pid,
    maybe_d2d: ?D2d = null,
    erase_bg_done: bool = false,
    text_format_editor: ddui.TextFormatCache(Dpi, createTextFormatEditor) = .{},

    // these fields should only be accessed inside the global mutex
    shared_screen_arena: std.heap.ArenaAllocator,
    shared_screen: vaxis.Screen = .{},
    pub fn deinit(self: *State) void {
        {
            global.mutex.lock();
            defer global.mutex.unlock();
            self.shared_screen.deinit(self.shared_screen_arena.allocator());
            self.shared_screen_arena.deinit();
        }
        if (self.maybe_d2d) |*d2d| {
            d2d.deinit();
        }
        self.* = undefined;
    }
};
fn stateFromHwnd(hwnd: win32.HWND) *State {
    const addr: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, @enumFromInt(0)));
    if (addr == 0) @panic("window is missing it's state!");
    return @ptrFromInt(addr);
}

fn paint(
    //self: State, dpi: u32, client_size: win32.D2D_SIZE_U
    d2d: *const D2d,
    dpi: u32,
    screen: *const vaxis.Screen,
    //layout: *const Layout,
    //mouse: *const ddui.mouse.State(MouseTarget),
    text_format_editor: *win32.IDWriteTextFormat,
) void {
    // TODO: this should probably be configurable?
    {
        const color = ddui.rgb8(0, 0, 0);
        d2d.target.ID2D1RenderTarget.Clear(&color);
    }
    const cell_size = getCellSize(dpi, text_format_editor);
    for (0..screen.height) |y| {
        const row_y = cell_size.y * @as(i32, @intCast(y));
        for (0..screen.width) |x| {
            const column_x = cell_size.x * @as(i32, @intCast(x));
            const cell_index = screen.width * y + x;
            const cell = &screen.buf[cell_index];

            const cell_rect: win32.RECT = .{
                .left = column_x,
                .top = row_y,
                .right = column_x + cell_size.x,
                .bottom = row_y + cell_size.y,
            };
            ddui.FillRectangle(
                &d2d.target.ID2D1RenderTarget,
                cell_rect,
                d2d.solid(d2dColorFromVAxis(cell.style.bg)),
            );

            // TODO: pre-caclulate the buffer size needed, for now this should just
            //       cause out-of-bounds access
            var buf_wtf16: [100]u16 = undefined;
            const grapheme_len = std.unicode.wtf8ToWtf16Le(&buf_wtf16, cell.char.grapheme) catch |err| switch (err) {
                error.InvalidWtf8 => @panic("TODO: handle invalid wtf8"),
            };
            ddui.DrawText(
                &d2d.target.ID2D1RenderTarget,
                buf_wtf16[0..grapheme_len],
                text_format_editor,
                ddui.rectFloatFromInt(cell_rect),
                d2d.solid(d2dColorFromVAxis(cell.style.fg)),
                .{},
                .NATURAL,
            );
        }
    }
}

const CreateWindowArgs = struct {
    allocator: std.mem.Allocator,
    pid: thespian.pid,
};

pub fn start() !std.Thread {
    std.debug.assert(!global.start_called);
    global.start_called = true;
    const pid = thespian.self_pid().clone();
    return try std.Thread.spawn(.{}, entry, .{pid});
}
fn entry(pid: thespian.pid) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    //const icons = getIcons();
    const CLASS_NAME = win32.L("Flow");

    // we only need to register the window class once per process
    if (global.window_class == 0) {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = @sizeOf(*State),
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = global.icons.large,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = global.icons.small,
        };
        global.window_class = win32.RegisterClassExW(&wc);
        if (global.window_class == 0) fatalWin32(
            "RegisterClass for main window",
            win32.GetLastError(),
        );
    }

    var create_args = CreateWindowArgs{
        .allocator = arena_instance.allocator(),
        .pid = pid,
    };
    const hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME, // Window class
        win32.L("Flow"),
        window_style,
        win32.CW_USEDEFAULT, // x
        win32.CW_USEDEFAULT, // y
        win32.CW_USEDEFAULT, // width
        win32.CW_USEDEFAULT, // height
        null, // Parent window
        null, // Menu
        win32.GetModuleHandleW(null),
        @ptrCast(&create_args),
    ) orelse fatalWin32("CreateWindow", win32.GetLastError());
    defer if (0 == win32.DestroyWindow(hwnd)) fatalWin32("DestroyWindow", win32.GetLastError());

    {
        global.mutex.lock();
        defer global.mutex.unlock();
        std.debug.assert(global.hwnd == null);
        global.hwnd = hwnd;
    }
    defer {
        global.mutex.lock();
        defer global.mutex.unlock();
        std.debug.assert(global.hwnd == hwnd);
        global.hwnd = null;
    }

    {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={}",
            .{ dark_value, win32.GetLastError() },
        );
    }

    if (0 == win32.UpdateWindow(hwnd)) fatalWin32("UpdateWindow", win32.GetLastError());
    //resizeWindowToViewport();
    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        // No need for TranslateMessage since we don't use WM_*CHAR messages
        //_ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }

    const exit_code = std.math.cast(u32, msg.wParam) orelse 0xffffffff;
    std.log.info("gui thread exit {} ({})", .{ exit_code, msg.wParam });
    // TODO: is there another way to exit the program? Maybe an event we can
    //       send to the main thread to tell it to exit?
    pid.send(.{"quit"}) catch @panic("pid send failed");
}

// returns false if there is no hwnd
pub fn updateScreen(screen: *const vaxis.Screen) bool {
    global.mutex.lock();
    defer global.mutex.unlock();

    const hwnd = global.hwnd orelse return false;
    const state = stateFromHwnd(hwnd);

    _ = state.shared_screen_arena.reset(.retain_capacity);

    const buf = state.shared_screen_arena.allocator().alloc(vaxis.Cell, screen.buf.len) catch |e| oom(e);
    @memcpy(buf, screen.buf);
    for (buf) |*cell| {
        cell.char.grapheme = state.shared_screen_arena.allocator().dupe(u8, cell.char.grapheme) catch |e| oom(e);
    }
    state.shared_screen = .{
        .width = screen.width,
        .height = screen.height,
        .width_pix = screen.width_pix,
        .height_pix = screen.height_pix,
        .buf = buf,
        .cursor_row = screen.cursor_row,
        .cursor_col = screen.cursor_col,
        .cursor_vis = screen.cursor_vis,
        .unicode = undefined,
        .width_method = undefined,
        .mouse_shape = screen.mouse_shape,
        .cursor_shape = undefined,
    };
    win32.invalidateHwnd(hwnd);
    return true;
}

fn getCellSize(
    dpi: u32,
    text_format_editor: *win32.IDWriteTextFormat,
) XY(i32) {
    _ = text_format_editor;
    // TODO: get the actual font metrics
    return .{
        .x = win32.scaleDpi(i32, 9, dpi),
        .y = win32.scaleDpi(i32, 19, dpi),
    };
}

fn cellFromPos(cell_size: XY(i32), x: i32, y: i32) XY(i32) {
    return XY(i32){
        .x = @divTrunc(x, cell_size.x),
        .y = @divTrunc(y, cell_size.y),
    };
}
fn cellOffsetFromPos(cell_size: XY(i32), x: i32, y: i32) XY(i32) {
    return .{
        .x = @mod(x, cell_size.x),
        .y = @mod(y, cell_size.y),
    };
}

pub fn fmtmsg(buf: []u8, value: anytype) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    cbor.writeValue(fbs.writer(), value) catch |e| switch (e) {
        error.NoSpaceLeft => std.debug.panic("buffer of size {} not big enough", .{buf.len}),
    };
    return buf[0..fbs.pos];
}

fn sendMouse(
    hwnd: win32.HWND,
    kind: enum {
        move,
        left_down,
        left_up,
        right_down,
        right_up,
    },
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    const point = ddui.pointFromLparam(lparam);
    const state = stateFromHwnd(hwnd);
    const dpi = win32.dpiFromHwnd(hwnd);
    const text_format = state.text_format_editor.getOrCreate(Dpi{ .value = dpi });
    const cell_size = getCellSize(dpi, text_format);
    const cell = cellFromPos(cell_size, point.x, point.y);
    const cell_offset = cellOffsetFromPos(cell_size, point.x, point.y);
    _ = wparam;
    switch (kind) {
        .move => state.pid.send(.{
            "GUI",
            "M",
            cell.x,
            cell.y,
            cell_offset.x,
            cell_offset.y,
        }) catch |e| onexit(e),
        else => |b| state.pid.send(.{
            "GUI",
            "B",
            switch (b) {
                .move => unreachable,
                .left_down, .right_down => input.event.press,
                .left_up, .right_up => input.event.release,
            },
            switch (b) {
                .move => unreachable,
                .left_down, .left_up => @intFromEnum(input.mouse.BUTTON1),
                .right_down, .right_up => @intFromEnum(input.mouse.BUTTON2),
            },
            cell.x,
            cell.y,
            cell_offset.x,
            cell_offset.y,
        }) catch |e| onexit(e),
    }
}

var global_msg_tail: ?*windowmsg.MessageNode = null;

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    var msg_node: windowmsg.MessageNode = undefined;
    msg_node.init(&global_msg_tail, hwnd, msg, wparam, lparam);
    defer msg_node.deinit();
    switch (msg) {
        // win32.WM_NCHITTEST,
        // win32.WM_SETCURSOR,
        // win32.WM_GETICON,
        // win32.WM_MOUSEMOVE,
        // win32.WM_NCMOUSEMOVE,
        // => {},
        else => if (false) std.log.info("{}", .{msg_node.fmtPath()}),
    }

    switch (msg) {
        win32.WM_MOUSEMOVE => sendMouse(hwnd, .move, wparam, lparam),
        win32.WM_LBUTTONDOWN => sendMouse(hwnd, .left_down, wparam, lparam),
        win32.WM_LBUTTONUP => sendMouse(hwnd, .left_up, wparam, lparam),
        win32.WM_RBUTTONDOWN => sendMouse(hwnd, .right_down, wparam, lparam),
        win32.WM_RBUTTONUP => sendMouse(hwnd, .right_up, wparam, lparam),
        win32.WM_PAINT => {
            const dpi = win32.dpiFromHwnd(hwnd);
            const client_size = getClientSize(hwnd);
            const state = stateFromHwnd(hwnd);

            const err: HResultError = blk: {
                var ps: win32.PAINTSTRUCT = undefined;
                _ = win32.BeginPaint(hwnd, &ps) orelse return fatalWin32(
                    "BeginPaint",
                    win32.GetLastError(),
                );
                defer if (0 == win32.EndPaint(hwnd, &ps)) fatalWin32(
                    "EndPaint",
                    win32.GetLastError(),
                );

                if (state.maybe_d2d == null) {
                    var err: HResultError = undefined;
                    state.maybe_d2d = D2d.init(hwnd, &err) catch break :blk err;
                }

                //state.layout.update(dpi, client_size);

                {
                    const size: win32.D2D_SIZE_U = .{
                        .width = @intCast(client_size.width),
                        .height = @intCast(client_size.height),
                    };
                    const hr = state.maybe_d2d.?.target.Resize(&size);
                    if (hr < 0) break :blk HResultError{ .context = "D2dResize", .hr = hr };
                }
                state.maybe_d2d.?.target.ID2D1RenderTarget.BeginDraw();

                {
                    global.mutex.lock();
                    defer global.mutex.unlock();
                    paint(
                        &state.maybe_d2d.?,
                        dpi,
                        &state.shared_screen,
                        //&state.layout,
                        //&state.mouse,
                        state.text_format_editor.getOrCreate(Dpi{ .value = dpi }),
                    );
                }

                break :blk HResultError{
                    .context = "D2dEndDraw",
                    .hr = state.maybe_d2d.?.target.ID2D1RenderTarget.EndDraw(null, null),
                };
            };

            if (err.hr == win32.D2DERR_RECREATE_TARGET) {
                std.log.debug("D2DERR_RECREATE_TARGET", .{});
                state.maybe_d2d.?.deinit();
                state.maybe_d2d = null;
                win32.invalidateHwnd(hwnd);
            } else if (err.hr < 0) std.debug.panic("paint error: {}", .{err});

            return 0;
        },
        win32.WM_SIZE => {
            // TODO: get the actual font metrics
            const font_width = 11;
            const font_height = 24;
            const new_size: XY(u16) = .{
                .x = win32.loword(lparam),
                .y = win32.hiword(lparam),
            };
            const new_cell_size: XY(u16) = .{
                .x = @divTrunc(new_size.x, font_width),
                .y = @divTrunc(new_size.y, font_height),
            };

            std.log.info("new size {}x{} {}x{}", .{ new_size.x, new_size.y, new_cell_size.x, new_cell_size.y });
            const state = stateFromHwnd(hwnd);
            state.pid.send(.{
                "GUI",
                "Resize",
                new_cell_size.x,
                new_cell_size.y,
                new_size.x,
                new_size.y,
            }) catch @panic("pid send failed");
        },
        win32.WM_DISPLAYCHANGE => win32.invalidateHwnd(hwnd),
        win32.WM_ERASEBKGND => {
            const state = stateFromHwnd(hwnd);
            if (!state.erase_bg_done) {
                state.erase_bg_done = true;
                const brush = win32.CreateSolidBrush(toColorRef(.{ .r = 29, .g = 29, .b = 29 })) orelse
                    fatalWin32("CreateSolidBrush", win32.GetLastError());
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
            const create_struct: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const create_args: *CreateWindowArgs = @alignCast(@ptrCast(create_struct.lpCreateParams));
            const state = create_args.allocator.create(State) catch |e| oom(e);

            state.* = .{
                .pid = create_args.pid,
                .shared_screen_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
            const existing = win32.SetWindowLongPtrW(
                hwnd,
                @enumFromInt(0),
                @as(isize, @bitCast(@intFromPtr(state))),
            );
            std.debug.assert(existing == 0);
            std.debug.assert(state == stateFromHwnd(hwnd));
        },
        win32.WM_DESTROY => {
            const state = stateFromHwnd(hwnd);
            state.deinit();
            // no need to free, it was allocated via an arena
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub const Rgb8 = struct { r: u8, g: u8, b: u8 };
fn toColorRef(rgb: Rgb8) u32 {
    return (@as(u32, rgb.r) << 0) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}
fn fatalWin32(what: []const u8, err: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, err.fmt() });
}
fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
fn deleteObject(obj: ?win32.HGDIOBJ) void {
    if (0 == win32.DeleteObject(obj)) fatalWin32("DeleteObject", win32.GetLastError());
}
fn getClientSize(hwnd: win32.HWND) win32.D2D_SIZE_U {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        fatalWin32("GetClientRect", win32.GetLastError());
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}
pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        pub fn init(x: T, y: T) @This() {
            return .{ .x = x, .y = y };
        }
    };
}