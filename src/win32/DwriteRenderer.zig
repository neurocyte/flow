const DwriteRenderer = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");

const dwrite = @import("dwrite.zig");
const XY = @import("xy.zig").XY;

pub const Font = dwrite.Font;
pub const Fonts = dwrite.Fonts;

pub const needs_direct2d = true;

render_target: *win32.ID2D1RenderTarget,
white_brush: *win32.ID2D1SolidColorBrush,
pub fn init(
    d2d_factory: *win32.ID2D1Factory,
    texture: *win32.ID3D11Texture2D,
) DwriteRenderer {
    const dxgi_surface = win32ext.queryInterface(texture, win32.IDXGISurface);
    defer _ = dxgi_surface.IUnknown.Release();

    var render_target: *win32.ID2D1RenderTarget = undefined;
    {
        const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
            .type = .DEFAULT,
            .pixelFormat = .{
                .format = .A8_UNORM,
                .alphaMode = .PREMULTIPLIED,
            },
            .dpiX = 0,
            .dpiY = 0,
            .usage = .{},
            .minLevel = .DEFAULT,
        };
        const hr = d2d_factory.CreateDxgiSurfaceRenderTarget(
            dxgi_surface,
            &props,
            &render_target,
        );
        if (hr < 0) fatalHr("CreateDxgiSurfaceRenderTarget", hr);
    }
    errdefer _ = render_target.IUnknown.Release();

    {
        const dc = win32ext.queryInterface(render_target, win32.ID2D1DeviceContext);
        defer _ = dc.IUnknown.Release();
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);
    }

    var white_brush: *win32.ID2D1SolidColorBrush = undefined;
    {
        const hr = render_target.CreateSolidColorBrush(
            &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
            null,
            &white_brush,
        );
        if (hr < 0) fatalHr("CreateSolidColorBrush", hr);
    }
    errdefer _ = white_brush.IUnknown.Release();

    return .{
        .render_target = render_target,
        .white_brush = white_brush,
    };
}
pub fn deinit(self: *DwriteRenderer) void {
    _ = self.white_brush.IUnknown.Release();
    _ = self.render_target.IUnknown.Release();
    self.* = undefined;
}

pub fn render(
    self: *const DwriteRenderer,
    font: Font,
    utf8: []const u8,
    double_width: bool,
) void {
    var utf16_buf: [10]u16 = undefined;
    const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8) catch unreachable;
    const utf16 = utf16_buf[0..utf16_len];
    std.debug.assert(utf16.len <= 2);

    {
        const rect: win32.D2D_RECT_F = .{
            .left = 0,
            .top = 0,
            .right = if (double_width)
                @as(f32, @floatFromInt(font.cell_size.x)) * @as(f32, @floatFromInt(font.cell_size.x))
            else
                @as(f32, @floatFromInt(font.cell_size.x)),
            .bottom = @floatFromInt(font.cell_size.y),
        };
        self.render_target.BeginDraw();
        {
            const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            self.render_target.Clear(&color);
        }
        self.render_target.DrawText(
            @ptrCast(utf16.ptr),
            @intCast(utf16.len),
            font.text_format,
            &rect,
            &self.white_brush.ID2D1Brush,
            .{},
            .NATURAL,
        );
        var tag1: u64 = undefined;
        var tag2: u64 = undefined;
        const hr = self.render_target.EndDraw(&tag1, &tag2);
        if (hr < 0) std.debug.panic(
            "D2D DrawText failed, hresult=0x{x}, tag1={}, tag2={}",
            .{ @as(u32, @bitCast(hr)), tag1, tag2 },
        );
    }
}

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
