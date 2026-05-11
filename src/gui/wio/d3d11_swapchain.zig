/// D3D11 device + DXGI flip-discard swapchain
///
const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_swapchain);

const Self = @This();

device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,
swap: *win32.IDXGISwapChain1,
rtv: *win32.ID3D11RenderTargetView,
width: u32,
height: u32,

pub fn init(hwnd: win32.HWND, width: u32, height: u32) !Self {
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;

    const feature_levels = [_]win32.D3D_FEATURE_LEVEL{
        .@"11_1",
        .@"11_0",
        .@"10_1",
        .@"10_0",
    };

    const create_flags: win32.D3D11_CREATE_DEVICE_FLAG = .{
        .BGRA_SUPPORT = 1,
        .SINGLETHREADED = 1,
    };

    var hr = win32.D3D11CreateDevice(
        null,
        .HARDWARE,
        null,
        create_flags,
        &feature_levels,
        feature_levels.len,
        win32.D3D11_SDK_VERSION,
        &device,
        null,
        &context,
    );
    if (hr < 0) {
        // fall back to WARP for software path
        hr = win32.D3D11CreateDevice(
            null,
            .WARP,
            null,
            create_flags,
            &feature_levels,
            feature_levels.len,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        );
        if (hr < 0) {
            log.err("D3D11CreateDevice failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.D3D11CreateDeviceFailed;
        }
    }
    errdefer _ = device.IUnknown.Release();
    errdefer _ = context.IUnknown.Release();

    const factory = try getDxgiFactory(device);
    defer _ = factory.IUnknown.Release();

    const desc = win32.DXGI_SWAP_CHAIN_DESC1{
        .Width = width,
        .Height = height,
        .Format = .R8G8B8A8_UNORM,
        .Stereo = 0,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = .NONE,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = .IGNORE,
        .Flags = 0,
    };

    var swap: *win32.IDXGISwapChain1 = undefined;
    const hr_swap = factory.CreateSwapChainForHwnd(
        &device.IUnknown,
        hwnd,
        &desc,
        null,
        null,
        &swap,
    );
    if (hr_swap < 0) {
        log.err("CreateSwapChainForHwnd failed, hr=0x{x}", .{@as(u32, @bitCast(hr_swap))});
        return error.CreateSwapChainFailed;
    }
    errdefer _ = swap.IUnknown.Release();

    const rtv = try createBackBufferRTV(device, swap);

    return .{
        .device = device,
        .context = context,
        .swap = swap,
        .rtv = rtv,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Self) void {
    _ = self.rtv.IUnknown.Release();
    _ = self.swap.IUnknown.Release();
    _ = self.context.IUnknown.Release();
    _ = self.device.IUnknown.Release();
    self.* = undefined;
}

pub fn resize(self: *Self, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return;
    if (width == self.width and height == self.height) return;

    // the RTV holds a reference to the back buffer so drop it before ResizeBuffers
    _ = self.rtv.IUnknown.Release();

    const hr = self.swap.IDXGISwapChain.ResizeBuffers(0, width, height, .UNKNOWN, 0);
    if (hr < 0) {
        log.err("ResizeBuffers failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.ResizeBuffersFailed;
    }

    self.rtv = try createBackBufferRTV(self.device, self.swap);
    self.width = width;
    self.height = height;
}

pub fn present(self: *Self) void {
    _ = self.swap.IDXGISwapChain.Present(0, 0);
}

fn getDxgiFactory(device: *win32.ID3D11Device) !*win32.IDXGIFactory2 {
    var dxgi_device: *win32.IDXGIDevice = undefined;
    if (device.IUnknown.QueryInterface(win32.IID_IDXGIDevice, @ptrCast(&dxgi_device)) < 0)
        return error.NoDxgiDevice;
    defer _ = dxgi_device.IUnknown.Release();

    var adapter: *win32.IDXGIAdapter = undefined;
    if (dxgi_device.GetAdapter(&adapter) < 0) return error.NoDxgiAdapter;
    defer _ = adapter.IUnknown.Release();

    var factory: *win32.IDXGIFactory2 = undefined;
    if (adapter.IDXGIObject.GetParent(win32.IID_IDXGIFactory2, @ptrCast(&factory)) < 0)
        return error.NoDxgiFactory;
    return factory;
}

fn createBackBufferRTV(
    device: *win32.ID3D11Device,
    swap: *win32.IDXGISwapChain1,
) !*win32.ID3D11RenderTargetView {
    var back_buffer: *win32.ID3D11Texture2D = undefined;
    if (swap.IDXGISwapChain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer)) < 0)
        return error.GetBackBufferFailed;
    defer _ = back_buffer.IUnknown.Release();

    var rtv: *win32.ID3D11RenderTargetView = undefined;
    if (device.CreateRenderTargetView(&back_buffer.ID3D11Resource, null, &rtv) < 0)
        return error.CreateRenderTargetViewFailed;
    return rtv;
}
