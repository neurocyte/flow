const DwriteRenderer = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");

const dwrite = @import("dwrite.zig");
const XY = @import("xy.zig").XY;

staging_texture: StagingTexture = .{},

const StagingTexture = struct {
    const Cached = struct {
        size: XY(u16),
        texture: *win32.ID3D11Texture2D,
        render_target: *win32.ID2D1RenderTarget,
        white_brush: *win32.ID2D1SolidColorBrush,
    };
    cached: ?Cached = null,
    pub fn update(
        self: *StagingTexture,
        d3d_device: *win32.ID3D11Device,
        d2d_factory: *win32.ID2D1Factory,
        size: XY(u16),
    ) struct {
        texture: *win32.ID3D11Texture2D,
        render_target: *win32.ID2D1RenderTarget,
        white_brush: *win32.ID2D1SolidColorBrush,
    } {
        if (self.cached) |cached| {
            if (cached.size.eql(size)) return .{
                .texture = cached.texture,
                .render_target = cached.render_target,
                .white_brush = cached.white_brush,
            };
            std.log.debug(
                "resizing staging texture from {}x{} to {}x{}",
                .{ cached.size.x, cached.size.y, size.x, size.y },
            );
            _ = cached.white_brush.IUnknown.Release();
            _ = cached.render_target.IUnknown.Release();
            _ = cached.texture.IUnknown.Release();
            self.cached = null;
        }

        var texture: *win32.ID3D11Texture2D = undefined;
        const desc: win32.D3D11_TEXTURE2D_DESC = .{
            .Width = size.x,
            .Height = size.y,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = .A8_UNORM,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = .{ .RENDER_TARGET = 1 },
            .CPUAccessFlags = .{},
            .MiscFlags = .{},
        };
        {
            const hr = d3d_device.CreateTexture2D(&desc, null, &texture);
            if (hr < 0) fatalHr("CreateStagingTexture", hr);
        }
        errdefer _ = texture.IUnknown.Release();

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

        self.cached = .{
            .size = size,
            .texture = texture,
            .render_target = render_target,
            .white_brush = white_brush,
        };
        return .{
            .texture = self.cached.?.texture,
            .render_target = self.cached.?.render_target,
            .white_brush = self.cached.?.white_brush,
        };
    }
};

pub fn render(
    self: *DwriteRenderer,
    d3d_device: *win32.ID3D11Device,
    d3d_context: *win32.ID3D11DeviceContext,
    d2d_factory: *win32.ID2D1Factory,
    font: dwrite.Font,
    texture: *win32.ID3D11Texture2D,
    codepoint: u21,
    coord: XY(u16),
) void {
    const staging = self.staging_texture.update(
        d3d_device,
        d2d_factory,
        font.cell_size,
    );

    var utf16_buf: [10]u16 = undefined;

    const utf16_len = blk: {
        var utf8_buf: [7]u8 = undefined;
        const utf8_len: u3 = std.unicode.utf8Encode(codepoint, &utf8_buf) catch |e| std.debug.panic(
            "todo: handle invalid codepoint {} (0x{0x}) ({s})",
            .{ codepoint, @errorName(e) },
        );
        const utf8 = utf8_buf[0..utf8_len];
        break :blk std.unicode.utf8ToUtf16Le(&utf16_buf, utf8) catch unreachable;
    };

    const utf16 = utf16_buf[0..utf16_len];
    std.debug.assert(utf16.len <= 2);

    {
        const rect: win32.D2D_RECT_F = .{
            .left = 0,
            .top = 0,
            .right = @floatFromInt(font.cell_size.x),
            .bottom = @floatFromInt(font.cell_size.y),
        };
        staging.render_target.BeginDraw();
        {
            const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            staging.render_target.Clear(&color);
        }
        staging.render_target.DrawText(
            @ptrCast(utf16.ptr),
            @intCast(utf16.len),
            font.text_format,
            &rect,
            &staging.white_brush.ID2D1Brush,
            .{},
            .NATURAL,
        );
        var tag1: u64 = undefined;
        var tag2: u64 = undefined;
        const hr = staging.render_target.EndDraw(&tag1, &tag2);
        if (hr < 0) std.debug.panic(
            "D2D DrawText failed, hresult=0x{x}, tag1={}, tag2={}",
            .{ @as(u32, @bitCast(hr)), tag1, tag2 },
        );
    }

    const box: win32.D3D11_BOX = .{
        .left = 0,
        .top = 0,
        .front = 0,
        .right = font.cell_size.x,
        .bottom = font.cell_size.y,
        .back = 1,
    };

    d3d_context.CopySubresourceRegion(
        &texture.ID3D11Resource,
        0, // subresource
        coord.x,
        coord.y,
        0, // z
        &staging.texture.ID3D11Resource,
        0, // subresource
        &box,
    );
}

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
