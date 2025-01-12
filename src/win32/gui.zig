const std = @import("std");
const root = @import("root");

const c = @cImport({
    @cInclude("ResourceNames.h");
});

const win32 = @import("win32").everything;
const ddui = @import("ddui");

const cbor = @import("cbor");
const thespian = @import("thespian");
const vaxis = @import("vaxis");
const gui_config = @import("gui_config");

const RGB = @import("color").RGB;
const input = @import("input");
const windowmsg = @import("windowmsg.zig");

const HResultError = ddui.HResultError;

const WM_APP_EXIT = win32.WM_APP + 1;
const WM_APP_SET_BACKGROUND = win32.WM_APP + 2;
const WM_APP_ADJUST_FONTSIZE = win32.WM_APP + 3;
const WM_APP_SET_FONTSIZE = win32.WM_APP + 4;
const WM_APP_SET_FONTFACE = win32.WM_APP + 5;

const WM_APP_EXIT_RESULT = 0x45feaa11;
const WM_APP_SET_BACKGROUND_RESULT = 0x369a26cd;
const WM_APP_ADJUST_FONTSIZE_RESULT = 0x79aba9ef;
const WM_APP_SET_FONTSIZE_RESULT = 0x72fa44bc;
const WM_APP_SET_FONTFACE_RESULT = 0x1a49ffa8;

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
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var init_called: bool = false;
    var start_called: bool = false;
    var icons: Icons = undefined;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    var state: ?State = null;
    var d2d_factory: *win32.ID2D1Factory = undefined;
    var conf: ?gui_config = null;
    var fontface: ?[:0]const u16 = null;
    var fontsize: ?f32 = null;

    var text_format_editor: ddui.TextFormatCache(FontCacheParams, createTextFormatEditor) = .{};

    const shared_screen = struct {
        var mutex: std.Thread.Mutex = .{};
        // only access arena/obj while the mutex is locked
        var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var obj: vaxis.Screen = .{};
    };
};
const window_style_ex = win32.WINDOW_EX_STYLE{
    .APPWINDOW = 1,
    //.ACCEPTFILES = 1,
};
const window_style = win32.WS_OVERLAPPEDWINDOW;

pub fn init() void {
    std.debug.assert(!global.init_called);
    global.init_called = true;

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
fn getIcons(dpi: XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);
    std.log.debug("icons small={}x{} large={}x{} at dpi {}x{}", .{
        small_x, small_y,
        large_x, large_y,
        dpi.x,   dpi.y,
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
        .index => |idx| blk: {
            const rgb = RGB.from_u24(xterm_colors[idx]);
            break :blk .{
                .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                .a = 1,
            };
        },
        .rgb => |rgb| .{
            .r = @as(f32, @floatFromInt(rgb[0])) / 255.0,
            .g = @as(f32, @floatFromInt(rgb[1])) / 255.0,
            .b = @as(f32, @floatFromInt(rgb[2])) / 255.0,
            .a = 1,
        },
    };
}

const FontCacheParams = struct {
    dpi: u32,
    fontsize: f32,
    pub fn eql(self: FontCacheParams, other: FontCacheParams) bool {
        return self.dpi == other.dpi and self.fontsize == other.fontsize;
    }
};

fn getConfig() *const gui_config {
    if (global.conf == null) {
        global.conf, _ = root.read_config(gui_config, global.arena);
        root.write_config(global.conf.?, global.arena) catch
            std.log.err("failed to write gui config file", .{});
    }
    return &global.conf.?;
}

fn getFieldDefault(field: std.builtin.Type.StructField) ?*const field.type {
    return @alignCast(@ptrCast(field.default_value orelse return null));
}

fn getFontFace() [:0]const u16 {
    if (global.fontface == null) {
        const conf = getConfig();
        global.fontface = blk: {
            break :blk std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, conf.fontface) catch |e| {
                std.log.err("failed to convert fontface name with {s}", .{@errorName(e)});
                const default = comptime getFieldDefault(
                    std.meta.fieldInfo(gui_config, .fontface),
                ) orelse @compileError("fontface is missing default");
                break :blk win32.L(default.*);
            };
        };
    }
    return global.fontface.?;
}

fn getFontSize() f32 {
    if (global.fontsize == null) {
        global.fontsize = @floatFromInt(getConfig().fontsize);
    }
    return global.fontsize.?;
}

fn createTextFormatEditor(params: FontCacheParams) *win32.IDWriteTextFormat {
    var err: HResultError = undefined;
    return ddui.createTextFormat(global.dwrite_factory, &err, .{
        .size = win32.scaleDpi(f32, params.fontsize, params.dpi),
        .family_name = getFontFace(),
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
    hwnd: win32.HWND,
    pid: thespian.pid,
    maybe_d2d: ?D2d = null,
    erase_bg_done: bool = false,
    scroll_delta: isize = 0,
    currently_rendered_cell_size: ?XY(i32) = null,
    background: ?u32 = null,
    last_sizing_edge: ?win32.WPARAM = null,
    bounds: ?WindowBounds = null,
};
fn stateFromHwnd(hwnd: win32.HWND) *State {
    std.debug.assert(hwnd == global.state.?.hwnd);
    return &global.state.?;
}

fn paint(
    d2d: *const D2d,
    background: RGB,
    screen: *const vaxis.Screen,
    text_format_editor: *win32.IDWriteTextFormat,
    cell_size: XY(i32),
) void {
    {
        const color = ddui.rgb8(background.r, background.g, background.b);
        d2d.target.ID2D1RenderTarget.Clear(&color);
    }

    for (0..screen.height) |y| {
        const row_y: i32 = cell_size.y * @as(i32, @intCast(y));
        for (0..screen.width) |x| {
            const column_x: i32 = cell_size.x * @as(i32, @intCast(x));
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
            const grapheme_len = blk: {
                break :blk std.unicode.wtf8ToWtf16Le(&buf_wtf16, cell.char.grapheme) catch |err| switch (err) {
                    error.InvalidWtf8 => {
                        buf_wtf16[0] = std.unicode.replacement_character;
                        break :blk 1;
                    },
                };
            };
            const grapheme = buf_wtf16[0..grapheme_len];
            if (std.mem.eql(u16, grapheme, &[_]u16{' '}))
                continue;
            ddui.DrawText(
                &d2d.target.ID2D1RenderTarget,
                grapheme,
                text_format_editor,
                ddui.rectFloatFromInt(cell_rect),
                d2d.solid(d2dColorFromVAxis(cell.style.fg)),
                .{
                    .CLIP = 1,
                    .ENABLE_COLOR_FONT = 1,
                },
                .NATURAL,
            );
        }
    }
}

const WindowPlacement = struct {
    dpi: XY(u32),
    size: XY(i32),
    pos: XY(i32),
    pub const default: WindowPlacement = .{
        .dpi = .{
            .x = 96,
            .y = 96,
        },
        .pos = .{
            .x = win32.CW_USEDEFAULT,
            .y = win32.CW_USEDEFAULT,
        },
        .size = .{
            .x = win32.CW_USEDEFAULT,
            .y = win32.CW_USEDEFAULT,
        },
    };
};

fn calcWindowPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: XY(i32),
    initial_window_x: u16,
    initial_window_y: u16,
) WindowPlacement {
    var result = WindowPlacement.default;

    const monitor = maybe_monitor orelse return result;

    const work_rect: win32.RECT = blk: {
        var info: win32.MONITORINFO = undefined;
        info.cbSize = @sizeOf(win32.MONITORINFO);
        if (0 == win32.GetMonitorInfoW(monitor, &info)) {
            std.log.warn("GetMonitorInfo failed with {}", .{win32.GetLastError().fmt()});
            return result;
        }
        break :blk info.rcWork;
    };

    const work_size: XY(i32) = .{
        .x = work_rect.right - work_rect.left,
        .y = work_rect.bottom - work_rect.top,
    };
    std.log.debug(
        "primary monitor work topleft={},{} size={}x{}",
        .{ work_rect.left, work_rect.top, work_size.x, work_size.y },
    );

    const wanted_size: XY(i32) = .{
        .x = win32.scaleDpi(i32, @intCast(initial_window_x), result.dpi.x),
        .y = win32.scaleDpi(i32, @intCast(initial_window_y), result.dpi.y),
    };
    const bounding_size: XY(i32) = .{
        .x = @min(wanted_size.x, work_size.x),
        .y = @min(wanted_size.y, work_size.y),
    };
    const bouding_rect: win32.RECT = ddui.rectIntFromSize(.{
        .left = work_rect.left + @divTrunc(work_size.x - bounding_size.x, 2),
        .top = work_rect.top + @divTrunc(work_size.y - bounding_size.y, 2),
        .width = bounding_size.x,
        .height = bounding_size.y,
    });
    const adjusted_rect: win32.RECT = calcWindowRect(
        dpi,
        bouding_rect,
        null,
        cell_size,
    );
    result.pos = .{ .x = adjusted_rect.left, .y = adjusted_rect.top };
    result.size = .{
        .x = adjusted_rect.right - adjusted_rect.left,
        .y = adjusted_rect.bottom - adjusted_rect.top,
    };
    return result;
}

const CreateWindowArgs = struct {
    pid: thespian.pid,
};

pub fn start() !std.Thread {
    std.debug.assert(!global.start_called);
    global.start_called = true;
    const pid = thespian.self_pid().clone();
    return try std.Thread.spawn(.{}, entry, .{pid});
}
fn entry(pid: thespian.pid) !void {
    const conf = getConfig();

    const maybe_monitor: ?win32.HMONITOR = blk: {
        break :blk win32.MonitorFromPoint(
            .{
                .x = conf.initial_window_x,
                .y = conf.initial_window_y,
            },
            win32.MONITOR_DEFAULTTOPRIMARY,
        ) orelse {
            std.log.warn("MonitorFromPoint failed with {}", .{win32.GetLastError().fmt()});
            break :blk null;
        };
    };

    const dpi: XY(u32) = blk: {
        const monitor = maybe_monitor orelse break :blk .{ .x = 96, .y = 96 };
        var dpi: XY(u32) = undefined;
        const hr = win32.GetDpiForMonitor(
            monitor,
            win32.MDT_EFFECTIVE_DPI,
            &dpi.x,
            &dpi.y,
        );
        if (hr < 0) {
            std.log.warn("GetDpiForMonitor failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
            break :blk .{ .x = 96, .y = 96 };
        }
        std.log.debug("primary monitor dpi {}x{}", .{ dpi.x, dpi.y });
        break :blk dpi;
    };

    const text_format_editor = global.text_format_editor.getOrCreate(FontCacheParams{ .dpi = @max(dpi.x, dpi.y), .fontsize = @floatFromInt(conf.fontsize) });
    const cell_size = getCellSize(text_format_editor);
    const initial_placement = calcWindowPlacement(
        maybe_monitor,
        @max(dpi.x, dpi.y),
        cell_size,
        conf.initial_window_x,
        conf.initial_window_y,
    );
    global.icons = getIcons(initial_placement.dpi);

    const CLASS_NAME = win32.L("Flow");

    // we only need to register the window class once per process
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = WndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = global.icons.large,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = global.icons.small,
    };
    if (0 == win32.RegisterClassExW(&wc)) fatalWin32(
        "RegisterClass for main window",
        win32.GetLastError(),
    );

    var create_args = CreateWindowArgs{ .pid = pid };
    const hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME, // Window class
        win32.L("Flow"),
        window_style,
        initial_placement.pos.x,
        initial_placement.pos.y,
        initial_placement.size.x,
        initial_placement.size.y,
        null, // Parent window
        null, // Menu
        win32.GetModuleHandleW(null),
        @ptrCast(&create_args),
    ) orelse fatalWin32("CreateWindow", win32.GetLastError());
    // NEVER DESTROY THE WINDOW!
    // This allows us to send the hwnd to other thread/parts
    // of the app and it will always be valid.
    pid.send(.{
        "RDR",
        "WindowCreated",
        @intFromPtr(hwnd),
    }) catch |e| return onexit(e);

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
    _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);

    // try some things to bring our window to the top
    const HWND_TOP: ?win32.HWND = null;
    _ = win32.SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1 });
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }

    const exit_code = std.math.cast(u32, msg.wParam) orelse 0xffffffff;
    std.log.debug("gui thread exit {} ({})", .{ exit_code, msg.wParam });
    pid.send(.{"quit"}) catch |e| onexit(e);
}

pub fn stop(hwnd: win32.HWND) void {
    std.debug.assert(WM_APP_EXIT_RESULT == win32.SendMessageW(hwnd, WM_APP_EXIT, 0, 0));
}

pub fn set_window_background(hwnd: win32.HWND, color: u32) void {
    std.debug.assert(WM_APP_SET_BACKGROUND_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_SET_BACKGROUND,
        color,
        0,
    ));
}

pub fn adjust_fontsize(hwnd: win32.HWND, amount: f32) void {
    std.debug.assert(WM_APP_ADJUST_FONTSIZE_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_ADJUST_FONTSIZE,
        @as(u32, @bitCast(amount)),
        0,
    ));
}

pub fn set_fontsize(hwnd: win32.HWND, fontsize: f32) void {
    std.debug.assert(WM_APP_SET_FONTSIZE_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_SET_FONTSIZE,
        @as(u32, @bitCast(fontsize)),
        0,
    ));
}

pub fn set_fontface(hwnd: win32.HWND, fontface_utf8: []const u8) void {
    const fontface = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, fontface_utf8) catch |e| {
        std.log.err("failed to convert fontface name '{s}' with {s}", .{ fontface_utf8, @errorName(e) });
        return;
    };
    std.debug.assert(WM_APP_SET_FONTFACE_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_SET_FONTFACE,
        @intFromPtr(fontface.ptr),
        @intCast(fontface.len),
    ));
}

pub fn updateScreen(screen: *const vaxis.Screen) void {
    global.shared_screen.mutex.lock();
    defer global.shared_screen.mutex.unlock();
    _ = global.shared_screen.arena.reset(.retain_capacity);

    const buf = global.shared_screen.arena.allocator().alloc(vaxis.Cell, screen.buf.len) catch |e| oom(e);
    @memcpy(buf, screen.buf);
    for (buf) |*cell| {
        cell.char.grapheme = global.shared_screen.arena.allocator().dupe(
            u8,
            cell.char.grapheme,
        ) catch |e| oom(e);
    }
    global.shared_screen.obj = .{
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
}

const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

fn updateWindowSize(
    hwnd: win32.HWND,
    edge: ?win32.WPARAM,
    bounds_ref: *?WindowBounds,
) void {
    const dpi = win32.dpiFromHwnd(hwnd);
    const text_format_editor = global.text_format_editor.getOrCreate(FontCacheParams{ .dpi = dpi, .fontsize = getFontSize() });
    const cell_size = getCellSize(text_format_editor);

    var window_rect: win32.RECT = undefined;
    if (0 == win32.GetWindowRect(hwnd, &window_rect)) fatalWin32(
        "GetWindowRect",
        win32.GetLastError(),
    );

    const restored_bounds: ?win32.RECT = blk: {
        if (bounds_ref.*) |b| {
            if (std.meta.eql(b.token, window_rect)) {
                break :blk b.rect;
            }
        }
        break :blk null;
    };
    const bounds = if (restored_bounds) |b| b else window_rect;
    const new_rect = calcWindowRect(
        dpi,
        bounds,
        edge,
        cell_size,
    );
    bounds_ref.* = .{
        .token = new_rect,
        .rect = if (restored_bounds) |b| b else new_rect,
    };
    setWindowPosRect(hwnd, new_rect);
}

// NOTE: we round the text metric up to the nearest integer which
//       means our background rectangles will be aligned. We accomodate
//       for any gap added by doing this by centering the text.
fn getCellSize(text_format: *win32.IDWriteTextFormat) XY(i32) {
    var text_layout: *win32.IDWriteTextLayout = undefined;
    {
        const hr = global.dwrite_factory.CreateTextLayout(
            win32.L("█"),
            1,
            text_format,
            std.math.floatMax(f32),
            std.math.floatMax(f32),
            &text_layout,
        );
        if (hr < 0) fatalHr("CreateTextLayout", hr);
    }
    defer _ = text_layout.IUnknown.Release();

    var metrics: win32.DWRITE_TEXT_METRICS = undefined;
    {
        const hr = text_layout.GetMetrics(&metrics);
        if (hr < 0) fatalHr("GetMetrics", hr);
    }
    return .{
        .x = @max(1, @as(i32, @intFromFloat(@floor(metrics.width)))),
        .y = @max(1, @as(i32, @intFromFloat(@floor(metrics.height)))),
    };
}

const CellPos = struct {
    cell: XY(i32),
    offset: XY(i32),
    pub fn init(cell_size: XY(i32), x: i32, y: i32) CellPos {
        return .{
            .cell = .{
                .x = @divTrunc(x, cell_size.x),
                .y = @divTrunc(y, cell_size.y),
            },
            .offset = .{
                .x = @mod(x, cell_size.x),
                .y = @mod(y, cell_size.y),
            },
        };
    }
};

pub fn fmtmsg(buf: []u8, value: anytype) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    cbor.writeValue(fbs.writer(), value) catch |e| switch (e) {
        error.NoSpaceLeft => std.debug.panic("buffer of size {} not big enough", .{buf.len}),
    };
    return buf[0..fbs.pos];
}

const MouseFlags = packed struct(u8) {
    left_down: bool,
    right_down: bool,
    shift_down: bool,
    control_down: bool,
    middle_down: bool,
    xbutton1_down: bool,
    xbutton2_down: bool,
    _: bool,
};
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
    const cell_size = state.currently_rendered_cell_size orelse return;
    const cell = CellPos.init(cell_size, point.x, point.y);
    switch (kind) {
        .move => {
            const flags: MouseFlags = @bitCast(@as(u8, @intCast(0xff & wparam)));
            if (flags.left_down) state.pid.send(.{
                "RDR",
                "D",
                @intFromEnum(input.mouse.BUTTON1),
                cell.cell.x,
                cell.cell.y,
                cell.offset.x,
                cell.offset.y,
            }) catch |e| onexit(e) else state.pid.send(.{
                "RDR",
                "M",
                cell.cell.x,
                cell.cell.y,
                cell.offset.x,
                cell.offset.y,
            }) catch |e| onexit(e);
        },
        else => |b| state.pid.send(.{
            "RDR",
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
            cell.cell.x,
            cell.cell.y,
            cell.offset.x,
            cell.offset.y,
        }) catch |e| onexit(e),
    }
}

fn sendMouseWheel(
    hwnd: win32.HWND,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    const point = ddui.pointFromLparam(lparam);
    const state = stateFromHwnd(hwnd);
    const cell_size = state.currently_rendered_cell_size orelse return;
    const cell = CellPos.init(cell_size, point.x, point.y);
    // const fwKeys = win32.loword(wparam);
    state.scroll_delta += @as(i16, @bitCast(win32.hiword(wparam)));
    while (@abs(state.scroll_delta) > win32.WHEEL_DELTA) {
        const button = blk: {
            if (state.scroll_delta > 0) {
                state.scroll_delta -= win32.WHEEL_DELTA;
                break :blk @intFromEnum(input.mouse.BUTTON4);
            }
            state.scroll_delta += win32.WHEEL_DELTA;
            break :blk @intFromEnum(input.mouse.BUTTON5);
        };

        state.pid.send(.{
            "RDR",
            "B",
            input.event.press,
            button,
            cell.cell.x,
            cell.cell.y,
            cell.offset.x,
            cell.offset.y,
        }) catch |e| onexit(e);
    }
}

const WinKeyFlags = packed struct(u32) {
    repeat_count: u16,
    scan_code: u8,
    extended: bool,
    reserved: u4,
    context: bool,
    previous: bool,
    transition: bool,
};

fn sendKey(
    hwnd: win32.HWND,
    kind: enum {
        press,
        release,
    },
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    const state = stateFromHwnd(hwnd);

    var keyboard_state: [256]u8 = undefined;
    if (0 == win32.GetKeyboardState(&keyboard_state)) fatalWin32(
        "GetKeyboardState",
        win32.GetLastError(),
    );

    const mods: vaxis.Key.Modifiers = .{
        .shift = (0 != (keyboard_state[@intFromEnum(win32.VK_SHIFT)] & 0x80)),
        .alt = (0 != (keyboard_state[@intFromEnum(win32.VK_MENU)] & 0x80)),
        .ctrl = (0 != (keyboard_state[@intFromEnum(win32.VK_CONTROL)] & 0x80)),
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = (0 != (keyboard_state[@intFromEnum(win32.VK_CAPITAL)] & 1)),
        .num_lock = false,
    };
    // if ((keyboard_state[VK_LWIN] & 0x80) || (keyboard_state[VK_RWIN] & 0x80)) mod_flags_u32 |= tn::ModifierFlags::Super;
    // if (m_winkey_down) mod_flags_u32 |= tn::ModifierFlags::Super;
    // // TODO: Numpad?
    // // TODO: Help?
    // // TODO: Fn?

    const event = switch (kind) {
        .press => input.event.press,
        .release => input.event.release,
    };

    const win_key_flags: WinKeyFlags = @bitCast(@as(u32, @intCast(0xffffffff & lparam)));
    const winkey: WinKey = .{
        .vk = @intCast(0xffff & wparam),
        .extended = win_key_flags.extended,
    };
    if (winkey.skipToUnicode()) |codepoint| {
        state.pid.send(.{
            "RDR",
            "I",
            event,
            @as(u21, codepoint),
            @as(u21, codepoint),
            "",
            @as(u8, @bitCast(mods)),
        }) catch |e| onexit(e);
        return;
    }

    const max_char_count = 20;
    var char_buf: [max_char_count + 1]u16 = undefined;

    // release control key when getting the unicode character of this key
    keyboard_state[@intFromEnum(win32.VK_CONTROL)] = 0;
    const unicode_result = win32.ToUnicode(
        winkey.vk,
        win_key_flags.scan_code,
        &keyboard_state,
        @ptrCast(&char_buf),
        max_char_count,
        0,
    );
    if (unicode_result < 0) {
        // < 0 means this is a dead key
        // The ToUnicode function should remember this dead key
        // and apply it to the next call
        return;
    }
    if (unicode_result > max_char_count) {
        for (char_buf[0..@intCast(unicode_result)], 0..) |codepoint, i| {
            std.log.err("UNICODE[{}] 0x{x} {d}", .{ i, codepoint, unicode_result });
        }
        return;
    }

    if (unicode_result == 0) {
        std.log.warn("unknown virtual key {} (0x{x})", .{ winkey, winkey.vk });
        return;
    }
    for (char_buf[0..@intCast(unicode_result)]) |codepoint| {
        const mod_bits = @as(u8, @bitCast(mods));
        const is_modified = mod_bits & ~(input.mod.shift | input.mod.caps_lock) != 0; // ignore shift and caps
        var utf8_buf: [6]u8 = undefined;
        const utf8_len = if (event == input.event.press and !is_modified)
            std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                std.log.err("invalid codepoint {}", .{codepoint});
                continue;
            }
        else
            0;
        state.pid.send(.{
            "RDR",
            "I",
            event,
            @as(u21, winkey.toKKPKeyCode()),
            @as(u21, codepoint),
            utf8_buf[0..utf8_len],
            mod_bits,
        }) catch |e| onexit(e);
    }
}

// TODO: move to libvaxis
const WinKey = struct {
    vk: u16,
    extended: bool,
    pub fn eql(self: WinKey, other: WinKey) bool {
        return self.vk == other.vk and self.extended == other.extended;
    }
    pub fn format(
        self: WinKey,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const e_suffix: []const u8 = if (self.extended) "e" else "";
        try writer.print("{}{s}", .{ self.vk, e_suffix });
    }
    pub fn skipToUnicode(self: WinKey) ?u21 {
        if (self.extended) return switch (self.vk) {
            @intFromEnum(win32.VK_RETURN) => input.key.kp_enter,
            @intFromEnum(win32.VK_CONTROL) => input.key.right_control,
            @intFromEnum(win32.VK_MENU) => input.key.right_alt,
            @intFromEnum(win32.VK_LWIN) => input.key.left_super,
            @intFromEnum(win32.VK_RWIN) => input.key.right_super,
            @intFromEnum(win32.VK_PRIOR) => input.key.page_up,
            @intFromEnum(win32.VK_NEXT) => input.key.page_down,
            @intFromEnum(win32.VK_END) => input.key.end,
            @intFromEnum(win32.VK_HOME) => input.key.home,
            @intFromEnum(win32.VK_LEFT) => input.key.left,
            @intFromEnum(win32.VK_UP) => input.key.up,
            @intFromEnum(win32.VK_RIGHT) => input.key.right,
            @intFromEnum(win32.VK_DOWN) => input.key.down,
            @intFromEnum(win32.VK_INSERT) => input.key.insert,
            @intFromEnum(win32.VK_DELETE) => input.key.delete,

            @intFromEnum(win32.VK_DIVIDE) => input.key.kp_divide,

            else => null,
        };
        return switch (self.vk) {
            @intFromEnum(win32.VK_BACK) => input.key.backspace,
            @intFromEnum(win32.VK_TAB) => input.key.tab,
            @intFromEnum(win32.VK_RETURN) => input.key.enter,
            // note: this could be left or right shift
            @intFromEnum(win32.VK_SHIFT) => input.key.left_shift,
            @intFromEnum(win32.VK_CONTROL) => input.key.left_control,
            @intFromEnum(win32.VK_MENU) => input.key.left_alt,
            @intFromEnum(win32.VK_PAUSE) => input.key.pause,
            @intFromEnum(win32.VK_CAPITAL) => input.key.caps_lock,
            @intFromEnum(win32.VK_ESCAPE) => input.key.escape,
            @intFromEnum(win32.VK_SPACE) => input.key.space,
            @intFromEnum(win32.VK_PRIOR) => input.key.kp_page_up,
            @intFromEnum(win32.VK_NEXT) => input.key.kp_page_down,
            @intFromEnum(win32.VK_END) => input.key.kp_end,
            @intFromEnum(win32.VK_HOME) => input.key.kp_home,
            @intFromEnum(win32.VK_LEFT) => input.key.kp_left,
            @intFromEnum(win32.VK_UP) => input.key.kp_up,
            @intFromEnum(win32.VK_RIGHT) => input.key.kp_right,
            @intFromEnum(win32.VK_DOWN) => input.key.kp_down,
            @intFromEnum(win32.VK_SNAPSHOT) => input.key.print_screen,
            @intFromEnum(win32.VK_INSERT) => input.key.kp_insert,
            @intFromEnum(win32.VK_DELETE) => input.key.kp_delete,

            @intFromEnum(win32.VK_LWIN) => input.key.left_super,
            @intFromEnum(win32.VK_RWIN) => input.key.right_super,
            @intFromEnum(win32.VK_NUMPAD0) => input.key.kp_0,
            @intFromEnum(win32.VK_NUMPAD1) => input.key.kp_1,
            @intFromEnum(win32.VK_NUMPAD2) => input.key.kp_2,
            @intFromEnum(win32.VK_NUMPAD3) => input.key.kp_3,
            @intFromEnum(win32.VK_NUMPAD4) => input.key.kp_4,
            @intFromEnum(win32.VK_NUMPAD5) => input.key.kp_5,
            @intFromEnum(win32.VK_NUMPAD6) => input.key.kp_6,
            @intFromEnum(win32.VK_NUMPAD7) => input.key.kp_7,
            @intFromEnum(win32.VK_NUMPAD8) => input.key.kp_8,
            @intFromEnum(win32.VK_NUMPAD9) => input.key.kp_9,
            @intFromEnum(win32.VK_MULTIPLY) => input.key.kp_multiply,
            @intFromEnum(win32.VK_ADD) => input.key.kp_add,
            @intFromEnum(win32.VK_SEPARATOR) => input.key.kp_separator,
            @intFromEnum(win32.VK_SUBTRACT) => input.key.kp_subtract,
            @intFromEnum(win32.VK_DECIMAL) => input.key.kp_decimal,
            // odd, for some reason the divide key is considered extended?
            //@intFromEnum(win32.VK_DIVIDE) => input.key.kp_divide,
            @intFromEnum(win32.VK_F1) => input.key.f1,
            @intFromEnum(win32.VK_F2) => input.key.f2,
            @intFromEnum(win32.VK_F3) => input.key.f3,
            @intFromEnum(win32.VK_F4) => input.key.f4,
            @intFromEnum(win32.VK_F5) => input.key.f5,
            @intFromEnum(win32.VK_F6) => input.key.f6,
            @intFromEnum(win32.VK_F7) => input.key.f7,
            @intFromEnum(win32.VK_F8) => input.key.f8,
            @intFromEnum(win32.VK_F9) => input.key.f9,
            @intFromEnum(win32.VK_F10) => input.key.f10,
            @intFromEnum(win32.VK_F11) => input.key.f11,
            @intFromEnum(win32.VK_F12) => input.key.f12,
            @intFromEnum(win32.VK_F13) => input.key.f13,
            @intFromEnum(win32.VK_F14) => input.key.f14,
            @intFromEnum(win32.VK_F15) => input.key.f15,
            @intFromEnum(win32.VK_F16) => input.key.f16,
            @intFromEnum(win32.VK_F17) => input.key.f17,
            @intFromEnum(win32.VK_F18) => input.key.f18,
            @intFromEnum(win32.VK_F19) => input.key.f19,
            @intFromEnum(win32.VK_F20) => input.key.f20,
            @intFromEnum(win32.VK_F21) => input.key.f21,
            @intFromEnum(win32.VK_F22) => input.key.f22,
            @intFromEnum(win32.VK_F23) => input.key.f23,
            @intFromEnum(win32.VK_F24) => input.key.f24,
            @intFromEnum(win32.VK_NUMLOCK) => input.key.num_lock,
            @intFromEnum(win32.VK_SCROLL) => input.key.scroll_lock,
            @intFromEnum(win32.VK_LSHIFT) => input.key.left_shift,
            @intFromEnum(win32.VK_RSHIFT) => input.key.right_shift,
            @intFromEnum(win32.VK_LCONTROL) => input.key.left_control,
            @intFromEnum(win32.VK_RCONTROL) => input.key.right_control,
            @intFromEnum(win32.VK_LMENU) => input.key.left_alt,
            @intFromEnum(win32.VK_RMENU) => input.key.right_alt,
            @intFromEnum(win32.VK_VOLUME_MUTE) => input.key.mute_volume,
            @intFromEnum(win32.VK_VOLUME_DOWN) => input.key.lower_volume,
            @intFromEnum(win32.VK_VOLUME_UP) => input.key.raise_volume,
            @intFromEnum(win32.VK_MEDIA_NEXT_TRACK) => input.key.media_track_next,
            @intFromEnum(win32.VK_MEDIA_PREV_TRACK) => input.key.media_track_previous,
            @intFromEnum(win32.VK_MEDIA_STOP) => input.key.media_stop,
            @intFromEnum(win32.VK_MEDIA_PLAY_PAUSE) => input.key.media_play_pause,
            else => null,
        };
    }

    pub fn toKKPKeyCode(self: WinKey) u21 {
        if (self.extended) return self.vk;
        return switch (self.vk) {
            'A'...'Z' => |char| char + ('a' - 'A'),

            @intFromEnum(win32.VK_OEM_1) => ';',
            @intFromEnum(win32.VK_OEM_PLUS) => '+',
            @intFromEnum(win32.VK_OEM_COMMA) => ',',
            @intFromEnum(win32.VK_OEM_MINUS) => '-',
            @intFromEnum(win32.VK_OEM_PERIOD) => '.',
            @intFromEnum(win32.VK_OEM_2) => '/',
            @intFromEnum(win32.VK_OEM_3) => '`',
            @intFromEnum(win32.VK_OEM_4) => '[',
            @intFromEnum(win32.VK_OEM_5) => '\\',
            @intFromEnum(win32.VK_OEM_6) => ']',
            @intFromEnum(win32.VK_OEM_7) => '\'',
            @intFromEnum(win32.VK_OEM_102) => '\\',

            else => |char| char,
        };
    }
};

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
        win32.WM_MOUSEMOVE => {
            sendMouse(hwnd, .move, wparam, lparam);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            sendMouse(hwnd, .left_down, wparam, lparam);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            sendMouse(hwnd, .left_up, wparam, lparam);
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            sendMouse(hwnd, .right_down, wparam, lparam);
            return 0;
        },
        win32.WM_RBUTTONUP => {
            sendMouse(hwnd, .right_up, wparam, lparam);
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            sendMouseWheel(hwnd, wparam, lparam);
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            sendKey(hwnd, .press, wparam, lparam);
            return 0;
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            sendKey(hwnd, .release, wparam, lparam);
            return 0;
        },
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

                {
                    const size: win32.D2D_SIZE_U = .{
                        .width = @intCast(client_size.x),
                        .height = @intCast(client_size.y),
                    };
                    const hr = state.maybe_d2d.?.target.Resize(&size);
                    if (hr < 0) break :blk HResultError{ .context = "D2dResize", .hr = hr };
                }
                state.maybe_d2d.?.target.ID2D1RenderTarget.BeginDraw();

                const text_format_editor = global.text_format_editor.getOrCreate(FontCacheParams{ .dpi = dpi, .fontsize = getFontSize() });
                state.currently_rendered_cell_size = getCellSize(text_format_editor);

                {
                    global.shared_screen.mutex.lock();
                    defer global.shared_screen.mutex.unlock();
                    paint(
                        &state.maybe_d2d.?,
                        RGB.from_u24(if (state.background) |b| @intCast(0xffffff & b) else 0),
                        &global.shared_screen.obj,
                        text_format_editor,
                        state.currently_rendered_cell_size.?,
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
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            const text_format_editor = global.text_format_editor.getOrCreate(FontCacheParams{ .dpi = new_dpi, .fontsize = getFontSize() });
            const cell_size = getCellSize(text_format_editor);
            const new_rect = calcWindowRect(
                new_dpi,
                .{
                    .left = 0,
                    .top = 0,
                    .right = inout_size.cx,
                    .bottom = inout_size.cy,
                },
                win32.WMSZ_BOTTOMRIGHT,
                cell_size,
            );
            inout_size.* = .{
                .cx = new_rect.right,
                .cy = new_rect.bottom,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            if (dpi != win32.hiword(wparam)) @panic("unexpected hiword dpi");
            if (dpi != win32.loword(wparam)) @panic("unexpected loword dpi");
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            state.bounds = null;
            return 0;
        },
        win32.WM_SIZE,
        => {
            const do_sanity_check = true;
            if (do_sanity_check) {
                const client_pixel_size: XY(u16) = .{
                    .x = win32.loword(lparam),
                    .y = win32.hiword(lparam),
                };
                const client_size = getClientSize(hwnd);
                std.debug.assert(client_pixel_size.x == client_size.x);
                std.debug.assert(client_pixel_size.y == client_size.y);
            }
            sendResize(hwnd);
            return 0;
        },
        win32.WM_SIZING => {
            const state = stateFromHwnd(hwnd);
            state.last_sizing_edge = wparam;
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            const state = stateFromHwnd(hwnd);
            state.bounds = null;
            updateWindowSize(hwnd, state.last_sizing_edge, &state.bounds);
            state.last_sizing_edge = null;
            return 0;
        },
        win32.WM_DISPLAYCHANGE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
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
            const state = stateFromHwnd(hwnd);
            state.pid.send(.{ "cmd", "quit" }) catch |e| onexit(e);
            return 0;
        },
        WM_APP_EXIT => {
            win32.PostQuitMessage(0);
            return WM_APP_EXIT_RESULT;
        },
        WM_APP_SET_BACKGROUND => {
            const state = stateFromHwnd(hwnd);
            state.background = @intCast(wparam);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_BACKGROUND_RESULT;
        },
        WM_APP_ADJUST_FONTSIZE => {
            const state = stateFromHwnd(hwnd);
            const amount: f32 = @bitCast(@as(u32, @intCast(0xFFFFFFFFF & wparam)));
            global.fontsize = @max(getFontSize() + amount, 1.0);
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_ADJUST_FONTSIZE_RESULT;
        },
        WM_APP_SET_FONTSIZE => {
            const state = stateFromHwnd(hwnd);
            const fontsize: f32 = @bitCast(@as(u32, @intCast(0xFFFFFFFFF & wparam)));
            global.fontsize = @max(fontsize, 1.0);
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_FONTSIZE_RESULT;
        },
        WM_APP_SET_FONTFACE => {
            const state = stateFromHwnd(hwnd);
            var fontface: [:0]const u16 = undefined;
            fontface.ptr = @ptrFromInt(wparam);
            fontface.len = @intCast(lparam);
            if (global.fontface) |old_fontface| std.heap.c_allocator.free(old_fontface);
            global.fontface = fontface;
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_FONTFACE_RESULT;
        },
        win32.WM_CREATE => {
            std.debug.assert(global.state == null);
            const create_struct: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const create_args: *CreateWindowArgs = @alignCast(@ptrCast(create_struct.lpCreateParams));
            global.state = .{
                .hwnd = hwnd,
                .pid = create_args.pid,
            };
            std.debug.assert(&(global.state.?) == stateFromHwnd(hwnd));
            sendResize(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            // the window should never be destroyed so as to not to invalidate
            // hwnd reference
            @panic("gui window erroneously destroyed");
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn sendResize(
    hwnd: win32.HWND,
) void {
    const dpi = win32.dpiFromHwnd(hwnd);
    const state = stateFromHwnd(hwnd);
    if (state.maybe_d2d == null) {
        var err: HResultError = undefined;
        state.maybe_d2d = D2d.init(hwnd, &err) catch std.debug.panic(
            "D2d.init failed with {}",
            .{err},
        );
    }
    const single_cell_size = getCellSize(
        global.text_format_editor.getOrCreate(FontCacheParams{ .dpi = @intCast(dpi), .fontsize = getFontSize() }),
    );
    const client_pixel_size = getClientSize(hwnd);
    const client_cell_size: XY(u16) = .{
        .x = @intCast(@divTrunc(client_pixel_size.x, single_cell_size.x)),
        .y = @intCast(@divTrunc(client_pixel_size.y, single_cell_size.y)),
    };
    std.log.debug(
        "Resize Px={}x{} Cells={}x{}",
        .{ client_pixel_size.x, client_pixel_size.y, client_cell_size.x, client_cell_size.y },
    );
    state.pid.send(.{
        "RDR",
        "Resize",
        client_cell_size.x,
        client_cell_size.y,
        client_pixel_size.x,
        client_pixel_size.y,
    }) catch @panic("pid send failed");
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
fn getClientSize(hwnd: win32.HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = rect.right, .y = rect.bottom };
}

fn calcWindowRect(
    dpi: u32,
    bouding_rect: win32.RECT,
    maybe_edge: ?win32.WPARAM,
    cell_size: XY(i32),
) win32.RECT {
    const window_size: XY(i32) = .{
        .x = bouding_rect.right - bouding_rect.left,
        .y = bouding_rect.bottom - bouding_rect.top,
    };
    const client_inset = getClientInset(dpi);
    const client_size: XY(i32) = .{
        .x = window_size.x - client_inset.x,
        .y = window_size.y - client_inset.y,
    };

    const diff: XY(i32) = .{
        .x = -@mod(client_size.x, cell_size.x),
        .y = -@mod(client_size.y, cell_size.y),
    };

    const Adjustment = enum { low, high, both };
    const adjustments: XY(Adjustment) = if (maybe_edge) |edge| switch (edge) {
        win32.WMSZ_LEFT => .{ .x = .low, .y = .both },
        win32.WMSZ_RIGHT => .{ .x = .high, .y = .both },
        win32.WMSZ_TOP => .{ .x = .both, .y = .low },
        win32.WMSZ_TOPLEFT => .{ .x = .low, .y = .low },
        win32.WMSZ_TOPRIGHT => .{ .x = .high, .y = .low },
        win32.WMSZ_BOTTOM => .{ .x = .both, .y = .high },
        win32.WMSZ_BOTTOMLEFT => .{ .x = .low, .y = .high },
        win32.WMSZ_BOTTOMRIGHT => .{ .x = .high, .y = .high },
        else => .{ .x = .both, .y = .both },
    } else .{ .x = .both, .y = .both };

    return .{
        .left = bouding_rect.left - switch (adjustments.x) {
            .low => diff.x,
            .high => 0,
            .both => @divTrunc(diff.x, 2),
        },
        .top = bouding_rect.top - switch (adjustments.y) {
            .low => diff.y,
            .high => 0,
            .both => @divTrunc(diff.y, 2),
        },
        .right = bouding_rect.right + switch (adjustments.x) {
            .low => 0,
            .high => diff.x,
            .both => @divTrunc(diff.x + 1, 2),
        },
        .bottom = bouding_rect.bottom + switch (adjustments.y) {
            .low => 0,
            .high => diff.y,
            .both => @divTrunc(diff.y + 1, 2),
        },
    };
}

fn getClientInset(dpi: u32) XY(i32) {
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
    };
    if (0 == win32.AdjustWindowRectExForDpi(
        &rect,
        window_style,
        0,
        window_style_ex,
        dpi,
    )) fatalWin32(
        "AdjustWindowRect",
        win32.GetLastError(),
    );
    return .{
        .x = rect.right - rect.left,
        .y = rect.bottom - rect.top,
    };
}

fn setWindowPosRect(hwnd: win32.HWND, rect: win32.RECT) void {
    if (0 == win32.SetWindowPos(
        hwnd,
        null, // ignored via NOZORDER
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1 },
    )) fatalWin32("SetWindowPos", win32.GetLastError());
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

const xterm_colors: [256]u24 = .{
    0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0,
    0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,

    0x000000, 0x00005f, 0x000087, 0x0000af, 0x0000d7, 0x0000ff, 0x005f00, 0x005f5f,
    0x005f87, 0x005faf, 0x005fd7, 0x005fff, 0x008700, 0x00875f, 0x008787, 0x0087af,
    0x0087d7, 0x0087ff, 0x00af00, 0x00af5f, 0x00af87, 0x00afaf, 0x00afd7, 0x00afff,
    0x00d700, 0x00d75f, 0x00d787, 0x00d7af, 0x00d7d7, 0x00d7ff, 0x00ff00, 0x00ff5f,
    0x00ff87, 0x00ffaf, 0x00ffd7, 0x00ffff, 0x5f0000, 0x5f005f, 0x5f0087, 0x5f00af,
    0x5f00d7, 0x5f00ff, 0x5f5f00, 0x5f5f5f, 0x5f5f87, 0x5f5faf, 0x5f5fd7, 0x5f5fff,
    0x5f8700, 0x5f875f, 0x5f8787, 0x5f87af, 0x5f87d7, 0x5f87ff, 0x5faf00, 0x5faf5f,
    0x5faf87, 0x5fafaf, 0x5fafd7, 0x5fafff, 0x5fd700, 0x5fd75f, 0x5fd787, 0x5fd7af,
    0x5fd7d7, 0x5fd7ff, 0x5fff00, 0x5fff5f, 0x5fff87, 0x5fffaf, 0x5fffd7, 0x5fffff,
    0x870000, 0x87005f, 0x870087, 0x8700af, 0x8700d7, 0x8700ff, 0x875f00, 0x875f5f,
    0x875f87, 0x875faf, 0x875fd7, 0x875fff, 0x878700, 0x87875f, 0x878787, 0x8787af,
    0x8787d7, 0x8787ff, 0x87af00, 0x87af5f, 0x87af87, 0x87afaf, 0x87afd7, 0x87afff,
    0x87d700, 0x87d75f, 0x87d787, 0x87d7af, 0x87d7d7, 0x87d7ff, 0x87ff00, 0x87ff5f,
    0x87ff87, 0x87ffaf, 0x87ffd7, 0x87ffff, 0xaf0000, 0xaf005f, 0xaf0087, 0xaf00af,
    0xaf00d7, 0xaf00ff, 0xaf5f00, 0xaf5f5f, 0xaf5f87, 0xaf5faf, 0xaf5fd7, 0xaf5fff,
    0xaf8700, 0xaf875f, 0xaf8787, 0xaf87af, 0xaf87d7, 0xaf87ff, 0xafaf00, 0xafaf5f,
    0xafaf87, 0xafafaf, 0xafafd7, 0xafafff, 0xafd700, 0xafd75f, 0xafd787, 0xafd7af,
    0xafd7d7, 0xafd7ff, 0xafff00, 0xafff5f, 0xafff87, 0xafffaf, 0xafffd7, 0xafffff,
    0xd70000, 0xd7005f, 0xd70087, 0xd700af, 0xd700d7, 0xd700ff, 0xd75f00, 0xd75f5f,
    0xd75f87, 0xd75faf, 0xd75fd7, 0xd75fff, 0xd78700, 0xd7875f, 0xd78787, 0xd787af,
    0xd787d7, 0xd787ff, 0xd7af00, 0xd7af5f, 0xd7af87, 0xd7afaf, 0xd7afd7, 0xd7afff,
    0xd7d700, 0xd7d75f, 0xd7d787, 0xd7d7af, 0xd7d7d7, 0xd7d7ff, 0xd7ff00, 0xd7ff5f,
    0xd7ff87, 0xd7ffaf, 0xd7ffd7, 0xd7ffff, 0xff0000, 0xff005f, 0xff0087, 0xff00af,
    0xff00d7, 0xff00ff, 0xff5f00, 0xff5f5f, 0xff5f87, 0xff5faf, 0xff5fd7, 0xff5fff,
    0xff8700, 0xff875f, 0xff8787, 0xff87af, 0xff87d7, 0xff87ff, 0xffaf00, 0xffaf5f,
    0xffaf87, 0xffafaf, 0xffafd7, 0xffafff, 0xffd700, 0xffd75f, 0xffd787, 0xffd7af,
    0xffd7d7, 0xffd7ff, 0xffff00, 0xffff5f, 0xffff87, 0xffffaf, 0xffffd7, 0xffffff,

    0x080808, 0x121212, 0x1c1c1c, 0x262626, 0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e,
    0x585858, 0x606060, 0x666666, 0x767676, 0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e,
    0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6, 0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee,
};
