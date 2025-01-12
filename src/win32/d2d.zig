const std = @import("std");
const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");
const ddui = @import("ddui");
const vaxis = @import("vaxis");
const dwrite = @import("dwrite.zig");

const RGB = @import("color").RGB;
const xterm = @import("xterm.zig");
const XY = @import("xy.zig").XY;

pub const Font = dwrite.Font;

pub const NOREDIRECTIONBITMAP = 0;

const global = struct {
    var init_called: bool = false;
    var d2d_factory: *win32.ID2D1Factory = undefined;
    var background: win32.D2D_COLOR_F = .{ .r = 0.075, .g = 0.075, .b = 0.075, .a = 1.0 };
};

pub fn init() void {
    std.debug.assert(!global.init_called);
    global.init_called = true;
    dwrite.init();
    {
        const hr = win32.D2D1CreateFactory(
            .SINGLE_THREADED,
            win32.IID_ID2D1Factory,
            null,
            @ptrCast(&global.d2d_factory),
        );
        if (hr < 0) fatalHr("D2D1CreateFactory", hr);
    }
}

pub fn setBackground(state: *const WindowState, rgb: RGB) void {
    _ = state;
    global.background = ddui.rgb8(rgb.r, rgb.g, rgb.b);
}

pub const WindowState = struct {
    maybe_d2d: ?D2d = null,
    pub fn init(hwnd: win32.HWND) WindowState {
        _ = hwnd;
        return .{};
    }
};

const D2d = struct {
    target: *win32.ID2D1HwndRenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    pub fn init(hwnd: win32.HWND, err: *ddui.HResultError) error{HResult}!D2d {
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
            const dc = win32ext.queryInterface(target, win32.ID2D1DeviceContext);
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

pub fn paint(
    hwnd: win32.HWND,
    state: *WindowState,
    font: Font,
    screen: *const vaxis.Screen,
) void {
    const client_size = getClientSize(hwnd);

    const err: ddui.HResultError = blk: {
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
            var err: ddui.HResultError = undefined;
            state.maybe_d2d = D2d.init(hwnd, &err) catch break :blk err;
        }

        {
            const size: win32.D2D_SIZE_U = .{
                .width = @intCast(client_size.x),
                .height = @intCast(client_size.y),
            };
            const hr = state.maybe_d2d.?.target.Resize(&size);
            if (hr < 0) break :blk ddui.HResultError{ .context = "D2dResize", .hr = hr };
        }

        state.maybe_d2d.?.target.ID2D1RenderTarget.BeginDraw();
        paintD2d(&state.maybe_d2d.?, screen, font);
        break :blk ddui.HResultError{
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
}

fn paintD2d(
    d2d: *const D2d,
    screen: *const vaxis.Screen,
    font: Font,
) void {
    d2d.target.ID2D1RenderTarget.Clear(&global.background);
    for (0..screen.height) |y| {
        const row_y: i32 = font.cell_size.y * @as(i32, @intCast(y));
        for (0..screen.width) |x| {
            const column_x: i32 = font.cell_size.x * @as(i32, @intCast(x));
            const cell_index = screen.width * y + x;
            const cell = &screen.buf[cell_index];

            const cell_rect: win32.RECT = .{
                .left = column_x,
                .top = row_y,
                .right = column_x + font.cell_size.x,
                .bottom = row_y + font.cell_size.y,
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
                font.text_format,
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

fn d2dColorFromVAxis(color: vaxis.Cell.Color) win32.D2D_COLOR_F {
    return switch (color) {
        .default => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .index => |idx| blk: {
            const rgb = RGB.from_u24(xterm.colors[idx]);
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

fn getClientSize(hwnd: win32.HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = rect.right, .y = rect.bottom };
}
fn fatalWin32(what: []const u8, err: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, err.fmt() });
}
fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
