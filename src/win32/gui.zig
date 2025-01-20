const std = @import("std");
const tracy = @import("tracy");
const build_options = @import("build_options");
const root = @import("root");

const c = @cImport({
    @cInclude("ResourceNames.h");
});

const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");

const cbor = @import("cbor");
const thespian = @import("thespian");
const vaxis = @import("vaxis");
const gui_config = @import("gui_config");

const RGB = @import("color").RGB;
const input = @import("input");
const windowmsg = @import("windowmsg.zig");

const render = @import("d3d11.zig");
const xterm = @import("xterm.zig");

const FontFace = @import("FontFace.zig");
const XY = @import("xy.zig").XY;

const WM_APP_EXIT = win32.WM_APP + 1;
const WM_APP_SET_BACKGROUND = win32.WM_APP + 2;
const WM_APP_ADJUST_FONTSIZE = win32.WM_APP + 3;
const WM_APP_SET_FONTSIZE = win32.WM_APP + 4;
const WM_APP_SET_FONTFACE = win32.WM_APP + 5;
const WM_APP_RESET_FONTSIZE = win32.WM_APP + 6;
const WM_APP_RESET_FONTFACE = win32.WM_APP + 7;
const WM_APP_GET_FONTFACES = win32.WM_APP + 8;
const WM_APP_UPDATE_SCREEN = win32.WM_APP + 9;

const WM_APP_EXIT_RESULT = 0x45feaa11;
const WM_APP_SET_BACKGROUND_RESULT = 0x369a26cd;
const WM_APP_ADJUST_FONTSIZE_RESULT = 0x79aba9ef;
const WM_APP_SET_FONTSIZE_RESULT = 0x72fa44bc;
const WM_APP_SET_FONTFACE_RESULT = 0x1a49ffa8;
const WM_APP_RESET_FONTSIZE_RESULT = 0x082c4c0c;
const WM_APP_RESET_FONTFACE_RESULT = 0x0101f996;
const WM_APP_GET_FONTFACES_RESULT = 0x07e228f5;
const WM_APP_UPDATE_SCREEN_RESULT = 0x3add213b;

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

    var state: ?State = null;
    var conf: ?gui_config = null;
    var fontface: ?FontFace = null;
    var fontsize: ?f32 = null;
    var font: ?Font = null;

    var screen_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var screen: vaxis.Screen = .{};

    var render_cells_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var render_cells: std.ArrayListUnmanaged(render.Cell) = .{};
};
const window_style_ex = win32.WINDOW_EX_STYLE{
    .APPWINDOW = 1,
    //.ACCEPTFILES = 1,
    .NOREDIRECTIONBITMAP = render.NOREDIRECTIONBITMAP,
};
const window_style = win32.WS_OVERLAPPEDWINDOW;

pub fn init() void {
    const frame = tracy.initZone(@src(), .{ .name = "gui init" });
    defer frame.deinit();
    std.debug.assert(!global.init_called);
    global.init_called = true;
    render.init(.{});
}

const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};
fn getIcons(dpi: XY(u32)) Icons {
    const frame = tracy.initZone(@src(), .{ .name = "gui getIcons" });
    defer frame.deinit();
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

fn getConfig() *gui_config {
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

fn getDefaultFontFace() FontFace {
    const default = comptime getFieldDefault(
        std.meta.fieldInfo(gui_config, .fontface),
    ) orelse @compileError("gui_config fontface is missing default");
    const default_wide = win32.L(default.*);
    var result: FontFace = .{ .buf = undefined, .len = default_wide.len };
    @memcpy(result.buf[0..default_wide.len], default_wide);
    result.buf[default_wide.len] = 0;
    return result;
}

fn getFontFace() *const FontFace {
    if (global.fontface == null) {
        const conf = getConfig();
        global.fontface = blk: {
            break :blk FontFace.initUtf8(conf.fontface) catch |e| switch (e) {
                error.TooLong => {
                    std.log.err("fontface '{s}' is too long", .{conf.fontface});
                    break :blk getDefaultFontFace();
                },
                error.InvalidUtf8 => {
                    std.log.err("fontface '{s}' is invalid utf8", .{conf.fontface});
                    break :blk getDefaultFontFace();
                },
            };
        };
    }
    return &(global.fontface.?);
}

fn setFontFace(fontface: *const FontFace) void {
    global.fontface = fontface.*;
    const conf = getConfig();
    var buf: [FontFace.max * 2]u8 = undefined;
    conf.fontface = buf[0 .. std.unicode.utf16LeToUtf8(&buf, fontface.slice()) catch return];
    root.write_config(conf.*, global.arena) catch
        std.log.err("failed to write gui config file", .{});
}

fn getFontSize() f32 {
    if (global.fontsize == null) {
        global.fontsize = @floatFromInt(getConfig().fontsize);
    }
    return global.fontsize.?;
}

fn getFont(dpi: u32, size: f32, face: *const FontFace) render.Font {
    const frame = tracy.initZone(@src(), .{ .name = "gui getFont" });
    defer frame.deinit();
    if (global.font) |*font| {
        if (font.dpi == dpi and font.size == size and font.face.eql(face))
            return font.render_object;
        font.render_object.deinit();
        global.font = null;
    }
    global.font = .{
        .dpi = dpi,
        .size = size,
        .face = face.*,
        .render_object = render.Font.init(dpi, size, face),
    };
    return global.font.?.render_object;
}

const Font = struct {
    dpi: u32,
    size: f32,
    face: FontFace,
    render_object: render.Font,
};

const State = struct {
    hwnd: win32.HWND,
    pid: thespian.pid,
    render_state: render.WindowState,
    scroll_delta: isize = 0,
    bounds: ?WindowBounds = null,
};
fn stateFromHwnd(hwnd: win32.HWND) *State {
    std.debug.assert(hwnd == global.state.?.hwnd);
    return &global.state.?;
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
    const frame = tracy.initZone(@src(), .{ .name = "gui calcWindowPlacement" });
    defer frame.deinit();
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
    const bouding_rect: win32.RECT = rectIntFromSize(.{
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
    std.debug.assert(global.init_called);
    std.debug.assert(global.start_called);

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

    const cell_size = getFont(@max(dpi.x, dpi.y), getFontSize(), getFontFace()).getCellSize(i32);
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

pub fn reset_fontsize(hwnd: win32.HWND) void {
    std.debug.assert(WM_APP_RESET_FONTSIZE_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_RESET_FONTSIZE,
        0,
        0,
    ));
}

pub fn set_fontface(hwnd: win32.HWND, fontface_utf8: []const u8) void {
    const fontface = FontFace.initUtf8(fontface_utf8) catch |e| {
        std.log.err("failed to set fontface '{s}' with {s}", .{ fontface_utf8, @errorName(e) });
        return;
    };
    std.debug.assert(WM_APP_SET_FONTFACE_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_SET_FONTFACE,
        @intFromPtr(&fontface),
        0,
    ));
}

pub fn reset_fontface(hwnd: win32.HWND) void {
    std.debug.assert(WM_APP_RESET_FONTFACE_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_RESET_FONTFACE,
        0,
        0,
    ));
}

pub fn get_fontfaces(hwnd: win32.HWND) void {
    std.debug.assert(WM_APP_GET_FONTFACES_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_GET_FONTFACES,
        0,
        0,
    ));
}

pub fn updateScreen(hwnd: win32.HWND, screen: *const vaxis.Screen) void {
    std.debug.assert(WM_APP_UPDATE_SCREEN_RESULT == win32.SendMessageW(
        hwnd,
        WM_APP_UPDATE_SCREEN,
        @intFromPtr(screen),
        0,
    ));
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
    const frame = tracy.initZone(@src(), .{ .name = "gui updateWindowSize" });
    defer frame.deinit();
    const dpi = win32.dpiFromHwnd(hwnd);
    const font = getFont(dpi, getFontSize(), getFontFace());
    const cell_size = font.getCellSize(i32);

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

fn getFontFaces(state: *State) void {
    const frame = tracy.initZone(@src(), .{ .name = "gui getFontFaces" });
    defer frame.deinit();
    const fonts = render.Fonts.init();
    defer fonts.deinit();
    var buf: [FontFace.max * 2]u8 = undefined;

    if (global.fontface) |fontface|
        state.pid.send(.{
            "fontface",
            "current",
            buf[0 .. std.unicode.utf16LeToUtf8(&buf, fontface.slice()) catch 0],
        }) catch {};

    for (0..fonts.count()) |font_index|
        state.pid.send(.{
            "fontface",
            buf[0 .. std.unicode.utf16LeToUtf8(&buf, fonts.getName(font_index).slice()) catch 0],
        }) catch {};

    state.pid.send(.{ "fontface", "done" }) catch {};
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
    const frame = tracy.initZone(@src(), .{ .name = "gui sendMouse" });
    defer frame.deinit();
    const point = win32ext.pointFromLparam(lparam);
    const state = stateFromHwnd(hwnd);
    const dpi = win32.dpiFromHwnd(hwnd);
    const cell_size = getFont(dpi, getFontSize(), getFontFace()).getCellSize(i32);
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
    const frame = tracy.initZone(@src(), .{ .name = "gui sendMouseWheel" });
    defer frame.deinit();
    var point = win32ext.pointFromLparam(lparam);
    _ = win32.ScreenToClient(hwnd, &point);
    const state = stateFromHwnd(hwnd);
    const dpi = win32.dpiFromHwnd(hwnd);
    const cell_size = getFont(dpi, getFontSize(), getFontFace()).getCellSize(i32);
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
    const frame = tracy.initZone(@src(), .{ .name = "gui sendKey" });
    defer frame.deinit();
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
    const frame = tracy.initZone(@src(), .{ .name = "gui WndProc" });
    defer frame.deinit();
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
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_PAINT" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            const font = getFont(dpi, getFontSize(), getFontFace());
            const client_size = getClientSize(u32, hwnd);

            var ps: win32.PAINTSTRUCT = undefined;
            _ = win32.BeginPaint(hwnd, &ps) orelse return fatalWin32("BeginPaint", win32.GetLastError());
            defer if (0 == win32.EndPaint(hwnd, &ps)) fatalWin32("EndPaint", win32.GetLastError());

            global.render_cells.resize(
                global.render_cells_arena.allocator(),
                global.screen.buf.len,
            ) catch |e| oom(e);
            for (global.screen.buf, global.render_cells.items) |*screen_cell, *render_cell| {
                const codepoint = if (std.unicode.utf8ValidateSlice(screen_cell.char.grapheme))
                    std.unicode.wtf8Decode(screen_cell.char.grapheme) catch std.unicode.replacement_character
                else
                    std.unicode.replacement_character;
                render_cell.* = .{
                    .glyph_index = state.render_state.generateGlyph(
                        font,
                        codepoint,
                    ),
                    .background = renderColorFromVaxis(screen_cell.style.bg),
                    .foreground = renderColorFromVaxis(screen_cell.style.fg),
                };
            }
            render.paint(
                &state.render_state,
                client_size,
                font,
                global.screen.height,
                global.screen.width,
                0,
                global.render_cells.items,
            );
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_GETDPISCALEDSIZE" });
            defer frame_.deinit();
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            // we don't want to update the font with the new dpi until after
            // the dpi change is effective, so, we get the cell size from the current font/dpi
            // and re-scale it based on the new dpi ourselves
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const font = getFont(current_dpi, getFontSize(), getFontFace());
            const current_cell_size_i32 = font.getCellSize(i32);
            const current_cell_size: XY(f32) = .{
                .x = @floatFromInt(current_cell_size_i32.x),
                .y = @floatFromInt(current_cell_size_i32.y),
            };
            const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / @as(f32, @floatFromInt(current_dpi));
            const rescaled_cell_size: XY(i32) = .{
                .x = @intFromFloat(@round(current_cell_size.x * scale)),
                .y = @intFromFloat(@round(current_cell_size.y * scale)),
            };
            const new_rect = calcWindowRect(
                new_dpi,
                .{
                    .left = 0,
                    .top = 0,
                    .right = inout_size.cx,
                    .bottom = inout_size.cy,
                },
                win32.WMSZ_BOTTOMRIGHT,
                rescaled_cell_size,
            );
            inout_size.* = .{
                .cx = new_rect.right,
                .cy = new_rect.bottom,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_DPICHANGED" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            if (dpi != win32.hiword(wparam)) @panic("unexpected hiword dpi");
            if (dpi != win32.loword(wparam)) @panic("unexpected loword dpi");
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            state.bounds = null;
            return 0;
        },
        win32.WM_WINDOWPOSCHANGED => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_WINDOWPOSCHANGED" });
            defer frame_.deinit();
            sendResize(hwnd);
            return 0;
        },
        win32.WM_SIZING => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_SIZING" });
            defer frame_.deinit();
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = win32.dpiFromHwnd(hwnd);
            const font = getFont(dpi, getFontSize(), getFontFace());
            const cell_size = font.getCellSize(i32);
            const new_rect = calcWindowRect(dpi, rect.*, wparam, cell_size);
            const state = stateFromHwnd(hwnd);
            state.bounds = .{
                .token = new_rect,
                .rect = rect.*,
            };
            rect.* = new_rect;
            return 0;
        },
        win32.WM_DISPLAYCHANGE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_DISPLAYCHANGE" });
            defer frame_.deinit();
            win32.invalidateHwnd(hwnd);
            return 0;
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
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_SET_BACKGROUND" });
            defer frame_.deinit();
            const rgb = RGB.from_u24(@intCast(0xffffff & wparam));
            render.setBackground(
                &stateFromHwnd(hwnd).render_state,
                render.Color.initRgb(rgb.r, rgb.g, rgb.b),
            );
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_BACKGROUND_RESULT;
        },
        WM_APP_ADJUST_FONTSIZE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_ADJUST_FONTSIZE" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            const amount: f32 = @bitCast(@as(u32, @intCast(0xFFFFFFFFF & wparam)));
            global.fontsize = @max(getFontSize() + amount, 1.0);
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_ADJUST_FONTSIZE_RESULT;
        },
        WM_APP_SET_FONTSIZE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_SET_FONTSIZE" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            const fontsize: f32 = @bitCast(@as(u32, @intCast(0xFFFFFFFFF & wparam)));
            global.fontsize = @max(fontsize, 1.0);
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_FONTSIZE_RESULT;
        },
        WM_APP_RESET_FONTSIZE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_RESET_FONTSIZE" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            global.fontsize = null;
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_FONTSIZE_RESULT;
        },
        WM_APP_SET_FONTFACE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_SET_FONTFACE" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            setFontFace(@ptrFromInt(wparam));
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_FONTFACE_RESULT;
        },
        WM_APP_RESET_FONTFACE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_RESET_FONTFACE" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            global.fontface = null;
            updateWindowSize(hwnd, win32.WMSZ_BOTTOMRIGHT, &state.bounds);
            win32.invalidateHwnd(hwnd);
            return WM_APP_SET_FONTFACE_RESULT;
        },
        WM_APP_GET_FONTFACES => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_GET_FONTFACES" });
            defer frame_.deinit();
            const state = stateFromHwnd(hwnd);
            getFontFaces(state);
            return WM_APP_GET_FONTFACES_RESULT;
        },
        WM_APP_UPDATE_SCREEN => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_APP_UPDATE_SCREEN" });
            defer frame_.deinit();
            const screen: *const vaxis.Screen = @ptrFromInt(wparam);
            _ = global.screen_arena.reset(.retain_capacity);
            const buf = global.screen_arena.allocator().alloc(vaxis.Cell, screen.buf.len) catch |e| oom(e);
            @memcpy(buf, screen.buf);
            for (buf) |*cell| {
                cell.char.grapheme = global.screen_arena.allocator().dupe(
                    u8,
                    cell.char.grapheme,
                ) catch |e| oom(e);
            }
            global.screen = .{
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
            return WM_APP_UPDATE_SCREEN_RESULT;
        },
        win32.WM_CREATE => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui WM_CREATE" });
            defer frame_.deinit();
            std.debug.assert(global.state == null);
            const create_struct: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const create_args: *CreateWindowArgs = @alignCast(@ptrCast(create_struct.lpCreateParams));
            global.state = .{
                .hwnd = hwnd,
                .pid = create_args.pid,
                .render_state = render.WindowState.init(hwnd),
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
        else => {
            const frame_ = tracy.initZone(@src(), .{ .name = "gui DefWindowProcW" });
            defer frame_.deinit();
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

fn sendResize(
    hwnd: win32.HWND,
) void {
    const frame = tracy.initZone(@src(), .{ .name = "gui sendResize" });
    defer frame.deinit();
    const dpi = win32.dpiFromHwnd(hwnd);
    const state = stateFromHwnd(hwnd);

    const font = getFont(dpi, getFontSize(), getFontFace());
    const cell_size = font.getCellSize(u16);
    const client_size = getClientSize(u16, hwnd);
    const client_cell_count: XY(u16) = .{
        .x = @intCast(@divTrunc(client_size.x, cell_size.x)),
        .y = @intCast(@divTrunc(client_size.y, cell_size.y)),
    };
    std.log.debug(
        "Resize Px={}x{} Cells={}x{}",
        .{ client_size.x, client_size.y, client_cell_count.x, client_cell_count.y },
    );
    state.pid.send(.{
        "RDR",
        "Resize",
        client_cell_count.x,
        client_cell_count.y,
        client_size.x,
        client_size.y,
    }) catch @panic("pid send failed");
}

fn renderColorFromVaxis(color: vaxis.Color) render.Color {
    return switch (color) {
        .default => render.Color.initRgb(0, 0, 0),
        .index => |idx| return @bitCast(@as(u32, xterm.colors[idx]) << 8 | 0xff),
        .rgb => |rgb| render.Color.initRgb(rgb[0], rgb[1], rgb[2]),
    };
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
fn getClientSize(comptime T: type, hwnd: win32.HWND) XY(T) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = @intCast(rect.right), .y = @intCast(rect.bottom) };
}

fn calcWindowRect(
    dpi: u32,
    bounding_rect: win32.RECT,
    maybe_edge: ?win32.WPARAM,
    cell_size: XY(i32),
) win32.RECT {
    const frame = tracy.initZone(@src(), .{ .name = "gui calcWindowRect" });
    defer frame.deinit();
    const client_inset = getClientInset(dpi);
    const bounding_client_size: XY(i32) = .{
        .x = (bounding_rect.right - bounding_rect.left) - client_inset.x,
        .y = (bounding_rect.bottom - bounding_rect.top) - client_inset.y,
    };
    const trim: XY(i32) = .{
        .x = @mod(bounding_client_size.x, cell_size.x),
        .y = @mod(bounding_client_size.y, cell_size.y),
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
        .left = bounding_rect.left + switch (adjustments.x) {
            .low => trim.x,
            .high => 0,
            .both => @divTrunc(trim.x, 2),
        },
        .top = bounding_rect.top + switch (adjustments.y) {
            .low => trim.y,
            .high => 0,
            .both => @divTrunc(trim.y, 2),
        },
        .right = bounding_rect.right - switch (adjustments.x) {
            .low => 0,
            .high => trim.x,
            .both => @divTrunc(trim.x + 1, 2),
        },
        .bottom = bounding_rect.bottom - switch (adjustments.y) {
            .low => 0,
            .high => trim.y,
            .both => @divTrunc(trim.y + 1, 2),
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

fn rectIntFromSize(args: struct { left: i32, top: i32, width: i32, height: i32 }) win32.RECT {
    return .{
        .left = args.left,
        .top = args.top,
        .right = args.left + args.width,
        .bottom = args.top + args.height,
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
