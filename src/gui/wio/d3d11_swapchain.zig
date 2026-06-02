/// D3D11 device + DXGI flip-discard swapchain
///
const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_swapchain);

const Self = @This();

// Undocumented API
const ACCENT_STATE = enum(u32) {
    DISABLED = 0,
    ENABLE_GRADIENT = 1,
    ENABLE_TRANSPARENTGRADIENT = 2,
    ENABLE_BLURBEHIND = 3,
    ENABLE_ACRYLICBLURBEHIND = 4,
};

const ACCENT_POLICY = extern struct {
    AccentState: ACCENT_STATE,
    AccentFlags: u32,
    GradientColor: u32,
    AnimationId: u32,
};

const WINDOWCOMPOSITIONATTRIBDATA = extern struct {
    Attrib: u32,
    pvData: ?*anyopaque,
    cbData: usize,
};

const WCA_ACCENT_POLICY: u32 = 19;

extern "user32" fn SetWindowCompositionAttribute(
    hwnd: ?win32.HWND,
    data: *WINDOWCOMPOSITIONATTRIBDATA,
) callconv(.winapi) win32.BOOL;

const tint_alpha: u8 = 0xB0;

const DWMWA_SYSTEMBACKDROP_TYPE: win32.DWMWINDOWATTRIBUTE = @enumFromInt(38);
const DWMSBT_TRANSIENTWINDOW: i32 = 3;

device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,
swap: *win32.IDXGISwapChain1,
rtv: *win32.ID3D11RenderTargetView,
dcomp_device: ?*win32.IDCompositionDevice,
dcomp_target: ?*win32.IDCompositionTarget,
dcomp_visual: ?*win32.IDCompositionVisual,
hwnd: win32.HWND,
transparent: bool,
width: u32,
height: u32,

pub fn init(hwnd: win32.HWND, width: u32, height: u32, transparent: bool) !Self {
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
        .Scaling = if (transparent) .STRETCH else .NONE,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = if (transparent) .PREMULTIPLIED else .IGNORE,
        .Flags = 0,
    };

    var swap: *win32.IDXGISwapChain1 = undefined;
    if (transparent) {
        const hr_swap = factory.CreateSwapChainForComposition(
            &device.IUnknown,
            &desc,
            null,
            &swap,
        );
        if (hr_swap < 0) {
            log.err("CreateSwapChainForComposition failed, hr=0x{x}", .{@as(u32, @bitCast(hr_swap))});
            return error.CreateSwapChainFailed;
        }
    } else {
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
    }
    errdefer _ = swap.IUnknown.Release();

    var dcomp_device: ?*win32.IDCompositionDevice = null;
    var dcomp_target: ?*win32.IDCompositionTarget = null;
    var dcomp_visual: ?*win32.IDCompositionVisual = null;
    errdefer {
        if (dcomp_visual) |v| _ = v.IUnknown.Release();
        if (dcomp_target) |t| _ = t.IUnknown.Release();
        if (dcomp_device) |d| _ = d.IUnknown.Release();
    }

    if (transparent) {
        var dxgi_device: *win32.IDXGIDevice = undefined;
        if (device.IUnknown.QueryInterface(win32.IID_IDXGIDevice, @ptrCast(&dxgi_device)) < 0)
            return error.NoDxgiDevice;
        defer _ = dxgi_device.IUnknown.Release();

        var dcomp_any: ?*anyopaque = null;
        const hr_dc = win32.DCompositionCreateDevice(dxgi_device, win32.IID_IDCompositionDevice, &dcomp_any);
        if (hr_dc < 0 or dcomp_any == null) {
            log.err("DCompositionCreateDevice failed, hr=0x{x}", .{@as(u32, @bitCast(hr_dc))});
            return error.DCompositionCreateDeviceFailed;
        }
        dcomp_device = @ptrCast(@alignCast(dcomp_any));

        var target_opt: ?*win32.IDCompositionTarget = null;
        if (dcomp_device.?.CreateTargetForHwnd(hwnd, win32.TRUE, &target_opt) < 0 or target_opt == null) {
            log.err("CreateTargetForHwnd failed", .{});
            return error.DCompositionCreateTargetFailed;
        }
        dcomp_target = target_opt;

        var visual_opt: ?*win32.IDCompositionVisual = null;
        if (dcomp_device.?.CreateVisual(&visual_opt) < 0 or visual_opt == null) {
            log.err("DComp CreateVisual failed", .{});
            return error.DCompositionCreateVisualFailed;
        }
        dcomp_visual = visual_opt;

        if (dcomp_visual.?.SetContent(&swap.IUnknown) < 0)
            return error.DCompositionSetContentFailed;
        if (dcomp_target.?.SetRoot(dcomp_visual.?) < 0)
            return error.DCompositionSetRootFailed;
        if (dcomp_device.?.Commit() < 0)
            return error.DCompositionCommitFailed;

        var backdrop: i32 = DWMSBT_TRANSIENTWINDOW;
        _ = win32.DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            &backdrop,
            @sizeOf(i32),
        );
    }

    const rtv = try createBackBufferRTV(device, swap);

    return .{
        .device = device,
        .context = context,
        .swap = swap,
        .rtv = rtv,
        .dcomp_device = dcomp_device,
        .dcomp_target = dcomp_target,
        .dcomp_visual = dcomp_visual,
        .hwnd = hwnd,
        .transparent = transparent,
        .width = width,
        .height = height,
    };
}

pub fn setChromeColor(self: *Self, r: u8, g: u8, b: u8) void {
    if (!self.transparent) return;

    var accent = ACCENT_POLICY{
        .AccentState = .ENABLE_ACRYLICBLURBEHIND,
        .AccentFlags = 0,
        .GradientColor = (@as(u32, tint_alpha) << 24) |
            (@as(u32, b) << 16) |
            (@as(u32, g) << 8) |
            @as(u32, r),
        .AnimationId = 0,
    };
    var data = WINDOWCOMPOSITIONATTRIBDATA{
        .Attrib = WCA_ACCENT_POLICY,
        .pvData = &accent,
        .cbData = @sizeOf(ACCENT_POLICY),
    };
    _ = SetWindowCompositionAttribute(self.hwnd, &data);

    var caption: u32 = (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
    _ = win32.DwmSetWindowAttribute(
        self.hwnd,
        win32.DWMWA_CAPTION_COLOR,
        &caption,
        @sizeOf(u32),
    );

    var dark: c_int = 1;
    _ = win32.DwmSetWindowAttribute(
        self.hwnd,
        win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(@TypeOf(dark)),
    );
}

pub fn deinit(self: *Self) void {
    _ = self.rtv.IUnknown.Release();
    _ = self.swap.IUnknown.Release();
    if (self.dcomp_visual) |v| _ = v.IUnknown.Release();
    if (self.dcomp_target) |t| _ = t.IUnknown.Release();
    if (self.dcomp_device) |d| _ = d.IUnknown.Release();
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
