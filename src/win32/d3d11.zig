const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");
const vaxis = @import("vaxis");

const dwrite = @import("dwrite.zig");
const GlyphIndexCache = @import("GlyphIndexCache.zig");
const TextRenderer = @import("DwriteRenderer.zig");

const RGB = @import("color").RGB;
const xterm = @import("xterm.zig");
const XY = @import("xy.zig").XY;

pub const Font = dwrite.Font;

const log = std.log.scoped(.d3d);

// the redirection bitmap is unnecessary for a d3d window and causes
// bad artifacts when the window is resized
pub const NOREDIRECTIONBITMAP = 1;

const global = struct {
    var init_called: bool = false;
    var d3d: D3d = undefined;
    var shaders: Shaders = undefined;
    var const_buf: *win32.ID3D11Buffer = undefined;
    var d2d_factory: *win32.ID2D1Factory = undefined;
    var glyph_cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var text_renderer: TextRenderer = undefined;
    var background: Rgba8 = .{ .r = 19, .g = 19, .b = 19, .a = 255 };
};

pub const Color = Rgba8;
const Rgba8 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,
    pub fn initRgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
};

// types shared with the shader
const shader = struct {
    const GridConfig = extern struct {
        cell_size: [2]u32,
        col_count: u32,
        row_count: u32,
    };
    const Cell = extern struct {
        glyph_index: u32,
        background: Rgba8,
        foreground: Rgba8,
    };
};

const swap_chain_flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);

pub fn init() void {
    std.debug.assert(!global.init_called);
    global.init_called = true;
    dwrite.init();

    const debug_d3d = switch (builtin.mode) {
        .Debug => true,
        else => false,
    };
    global.d3d = D3d.init(.{ .debug = debug_d3d });

    if (debug_d3d) {
        const info = win32ext.queryInterface(global.d3d.device, win32.ID3D11InfoQueue);
        defer _ = info.IUnknown.Release();
        {
            const hr = info.SetBreakOnSeverity(.CORRUPTION, 1);
            if (hr < 0) fatalHr("SetBreakOnCorruption", hr);
        }
        {
            const hr = info.SetBreakOnSeverity(.ERROR, 1);
            if (hr < 0) fatalHr("SetBreakOnError", hr);
        }
        {
            const hr = info.SetBreakOnSeverity(.WARNING, 1);
            if (hr < 0) fatalHr("SetBreakOnWarning", hr);
        }
    }

    global.shaders = Shaders.init();

    {
        const desc: win32.D3D11_BUFFER_DESC = .{
            // d3d requires constants be sized in multiples of 16
            .ByteWidth = std.mem.alignForward(u32, @sizeOf(shader.GridConfig), 16),
            .Usage = .DYNAMIC,
            .BindFlags = .{ .CONSTANT_BUFFER = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{},
            .StructureByteStride = 0,
        };
        const hr = global.d3d.device.CreateBuffer(&desc, null, &global.const_buf);
        if (hr < 0) fatalHr("CreateBuffer for grid config", hr);
    }

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
    global.background = .{ .r = rgb.r, .g = rgb.b, .b = rgb.b, .a = 255 };
    const color: win32.DXGI_RGBA = .{
        .r = @as(f32, @floatFromInt(rgb.r)) / 255,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255,
        .a = 1.0,
    };
    const hr = state.swap_chain.IDXGISwapChain1.SetBackgroundColor(&color);
    if (hr < 0) fatalHr("SetBackgroundColor", hr);
}

pub const WindowState = struct {
    swap_chain: *win32.IDXGISwapChain2,
    maybe_target_view: ?*win32.ID3D11RenderTargetView = null,
    shader_cells: ShaderCells = .{},

    glyph_texture: GlyphTexture = .{},
    glyph_cache_cell_size: ?XY(u16) = null,
    glyph_index_cache: ?GlyphIndexCache = null,

    pub fn init(hwnd: win32.HWND) WindowState {
        std.debug.assert(global.init_called);
        const swap_chain = initSwapChain(global.d3d.device, hwnd);
        return .{ .swap_chain = swap_chain };
    }
};

pub fn paint(
    hwnd: win32.HWND,
    state: *WindowState,
    font: Font,
    screen: *const vaxis.Screen,
) void {
    var ps: win32.PAINTSTRUCT = undefined;
    _ = win32.BeginPaint(hwnd, &ps) orelse fatalWin32("BeginPaint", win32.GetLastError());
    defer if (0 == win32.EndPaint(hwnd, &ps)) fatalWin32("EndPaint", win32.GetLastError());

    const client_size = getClientSize(u32, hwnd);

    {
        const swap_chain_size = getSwapChainSize(state.swap_chain);
        if (swap_chain_size.x != client_size.x or swap_chain_size.y != client_size.y) {
            log.debug(
                "SwapChain Buffer Resize from {}x{} to {}x{}",
                .{ swap_chain_size.x, swap_chain_size.y, client_size.x, client_size.y },
            );
            global.d3d.context.ClearState();
            if (state.maybe_target_view) |target_view| {
                _ = target_view.IUnknown.Release();
                state.maybe_target_view = null;
            }
            global.d3d.context.Flush();
            if (swap_chain_size.x == 0) @panic("possible? no need to resize?");
            if (swap_chain_size.y == 0) @panic("possible? no need to resize?");

            {
                const hr = state.swap_chain.IDXGISwapChain.ResizeBuffers(
                    0,
                    @intCast(client_size.x),
                    @intCast(client_size.y),
                    .UNKNOWN,
                    swap_chain_flags,
                );
                if (hr < 0) fatalHr("ResizeBuffers", hr);
            }
        }
    }

    // for now we'll just use 1 texture and leverage the entire thing
    const texture_cell_count: XY(u16) = getD3d11TextureMaxCellCount(font.cell_size);
    const texture_cell_count_total: u32 =
        @as(u32, texture_cell_count.x) * @as(u32, texture_cell_count.y);

    const texture_pixel_size: XY(u16) = .{
        .x = texture_cell_count.x * font.cell_size.x,
        .y = texture_cell_count.y * font.cell_size.y,
    };
    const texture_retained = switch (state.glyph_texture.updateSize(texture_pixel_size)) {
        .retained => true,
        .newly_created => false,
    };

    const cache_cell_size_valid = if (state.glyph_cache_cell_size) |size| size.eql(font.cell_size) else false;
    state.glyph_cache_cell_size = font.cell_size;

    if (!texture_retained or !cache_cell_size_valid) {
        if (state.glyph_index_cache) |*c| {
            c.deinit(global.glyph_cache_arena.allocator());
            _ = global.glyph_cache_arena.reset(.retain_capacity);
            state.glyph_index_cache = null;
        }
    }

    const glyph_index_cache = blk: {
        if (state.glyph_index_cache) |*c| break :blk c;
        state.glyph_index_cache = GlyphIndexCache.init(
            global.glyph_cache_arena.allocator(),
            texture_cell_count_total,
        ) catch |e| oom(e);
        break :blk &(state.glyph_index_cache.?);
    };

    const shader_col_count: u16 = @intCast(@divTrunc(client_size.x + font.cell_size.x - 1, font.cell_size.x));
    const shader_row_count: u16 = @intCast(@divTrunc(client_size.y + font.cell_size.y - 1, font.cell_size.y));

    {
        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = global.d3d.context.Map(
            &global.const_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) fatalHr("MapConstBuffer", hr);
        defer global.d3d.context.Unmap(&global.const_buf.ID3D11Resource, 0);
        const config: *shader.GridConfig = @ptrCast(@alignCast(mapped.pData));
        config.cell_size[0] = font.cell_size.x;
        config.cell_size[1] = font.cell_size.y;
        config.col_count = shader_col_count;
        config.row_count = shader_row_count;
    }

    const space_glyph = generateGlyph(
        font,
        glyph_index_cache,
        texture_cell_count.x,
        " ",
        state.glyph_texture.obj,
    );
    const populate_col_count: u16 = @min(screen.width, shader_col_count);
    const populate_row_count: u16 = @min(screen.height, shader_row_count);
    // we loop through and cache all the glyphs before mapping the cell buffer and potentially
    // blocking the gpu while we're doing expensive text rendering
    for (0..populate_row_count) |row| {
        const row_offset = row * screen.width;
        for (0..populate_col_count) |col| {
            const screen_cell = &screen.buf[row_offset + col];
            _ = generateGlyph(
                font,
                glyph_index_cache,
                texture_cell_count.x,
                screen_cell.char.grapheme,
                state.glyph_texture.obj,
            );
        }
    }

    const cell_count: u32 = @as(u32, shader_col_count) * @as(u32, shader_row_count);
    state.shader_cells.updateCount(cell_count);
    if (state.shader_cells.count > 0) {
        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = global.d3d.context.Map(
            &state.shader_cells.cell_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) fatalHr("MapCellBuffer", hr);
        defer global.d3d.context.Unmap(&state.shader_cells.cell_buf.ID3D11Resource, 0);

        const cells_shader: [*]shader.Cell = @ptrCast(@alignCast(mapped.pData));
        for (0..shader_row_count) |row| {
            const src_row_offset = row * screen.width;
            const dst_row_offset = row * @as(usize, shader_col_count);
            const src_col_count = if (row < screen.height) populate_col_count else 0;
            for (0..src_col_count) |col| {
                const screen_cell = &screen.buf[src_row_offset + col];
                const codepoint = std.unicode.wtf8Decode(screen_cell.char.grapheme) catch std.unicode.replacement_character;
                const glyph_index = blk: {
                    switch (glyph_index_cache.reserve(global.glyph_cache_arena.allocator(), codepoint) catch |e| oom(e)) {
                        .newly_reserved => |reserved| {
                            // should never happen unless there' more characters than the cache can hold
                            // var render_success = false;
                            // defer if (!render_success) state.glyph_index_cache.remove(reserved.index);
                            const pos: XY(u16) = cellPosFromIndex(reserved.index, texture_cell_count.x);
                            const coord = coordFromCellPos(font.cell_size, pos);
                            global.text_renderer.render(
                                global.d3d.device,
                                global.d3d.context,
                                global.d2d_factory,
                                font,
                                state.glyph_texture.obj,
                                codepoint,
                                coord,
                            );
                            break :blk reserved.index;
                        },
                        .already_reserved => |i| break :blk i,
                    }
                };
                cells_shader[dst_row_offset + col] = .{
                    .glyph_index = glyph_index,
                    .background = shaderColorFromVaxis(screen_cell.style.bg),
                    .foreground = shaderColorFromVaxis(screen_cell.style.fg),
                };
            }
            for (src_col_count..shader_col_count) |col| {
                cells_shader[dst_row_offset + col] = .{
                    .glyph_index = space_glyph,
                    .background = global.background,
                    .foreground = global.background,
                };
            }
        }
    }

    if (state.maybe_target_view == null) {
        state.maybe_target_view = createRenderTargetView(
            global.d3d.device,
            &state.swap_chain.IDXGISwapChain,
            client_size,
        );
    }
    {
        var target_views = [_]?*win32.ID3D11RenderTargetView{state.maybe_target_view.?};
        global.d3d.context.OMSetRenderTargets(target_views.len, &target_views, null);
    }

    global.d3d.context.PSSetConstantBuffers(0, 1, @constCast(@ptrCast(&global.const_buf)));
    var resources = [_]?*win32.ID3D11ShaderResourceView{
        if (state.shader_cells.count > 0) state.shader_cells.cell_view else null,
        state.glyph_texture.view,
    };
    global.d3d.context.PSSetShaderResources(0, resources.len, &resources);
    global.d3d.context.VSSetShader(global.shaders.vertex, null, 0);
    global.d3d.context.PSSetShader(global.shaders.pixel, null, 0);
    global.d3d.context.Draw(4, 0);

    // NOTE: don't enable vsync, it causes the gpu to lag behind horribly
    //       if we flood it with resize events
    {
        const hr = state.swap_chain.IDXGISwapChain.Present(0, 0);
        if (hr < 0) fatalHr("SwapChainPresent", hr);
    }
}

fn generateGlyph(
    font: Font,
    glyph_index_cache: *GlyphIndexCache,
    texture_column_count: u16,
    grapheme_utf8: []const u8,
    texture: *win32.ID3D11Texture2D,
) u32 {
    const codepoint = std.unicode.wtf8Decode(grapheme_utf8) catch std.unicode.replacement_character;
    switch (glyph_index_cache.reserve(
        global.glyph_cache_arena.allocator(),
        codepoint,
    ) catch |e| oom(e)) {
        .newly_reserved => |reserved| {
            // var render_success = false;
            // defer if (!render_success) state.glyph_index_cache.remove(reserved.index);
            const pos: XY(u16) = cellPosFromIndex(reserved.index, texture_column_count);
            const coord = coordFromCellPos(font.cell_size, pos);
            global.text_renderer.render(
                global.d3d.device,
                global.d3d.context,
                global.d2d_factory,
                font,
                texture,
                codepoint,
                coord,
            );
            return reserved.index;
        },
        .already_reserved => |index| return index,
    }
}

fn shaderColorFromVaxis(color: vaxis.Color) Rgba8 {
    return switch (color) {
        .default => .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .index => |idx| return @bitCast(@as(u32, xterm.colors[idx]) << 8 | 0xff),
        .rgb => |rgb| .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 },
    };
}

const D3d = struct {
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
    context1: *win32.ID3D11DeviceContext1,

    pub fn init(opt: struct { debug: bool }) D3d {
        const levels = [_]win32.D3D_FEATURE_LEVEL{
            .@"11_0",
        };
        var last_hr: i32 = undefined;
        for (&[_]win32.D3D_DRIVER_TYPE{ .HARDWARE, .WARP }) |driver| {
            var device: *win32.ID3D11Device = undefined;
            var context: *win32.ID3D11DeviceContext = undefined;
            last_hr = win32.D3D11CreateDevice(
                null,
                driver,
                null,
                .{
                    .BGRA_SUPPORT = 1,
                    .SINGLETHREADED = 1,
                    .DEBUG = if (opt.debug) 1 else 0,
                },
                &levels,
                levels.len,
                win32.D3D11_SDK_VERSION,
                &device,
                null,
                &context,
            );
            if (last_hr >= 0) return .{
                .device = device,
                .context = context,
                .context1 = win32ext.queryInterface(context, win32.ID3D11DeviceContext1),
            };
            std.log.info(
                "D3D11 {s} Driver error, hresult=0x{x}",
                .{ @tagName(driver), @as(u32, @bitCast(last_hr)) },
            );
        }
        std.debug.panic("failed to initialize Direct3D11, hresult=0x{x}", .{last_hr});
    }
};

fn getDxgiFactory(device: *win32.ID3D11Device) *win32.IDXGIFactory2 {
    const dxgi_device = win32ext.queryInterface(device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();

    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) fatalHr("GetDxgiAdapter", hr);
    }
    defer _ = adapter.IUnknown.Release();

    var factory: *win32.IDXGIFactory2 = undefined;
    {
        const hr = adapter.IDXGIObject.GetParent(win32.IID_IDXGIFactory2, @ptrCast(&factory));
        if (hr < 0) fatalHr("GetDxgiFactory", hr);
    }
    return factory;
}

fn getSwapChainSize(swap_chain: *win32.IDXGISwapChain2) XY(u32) {
    var size: XY(u32) = undefined;
    {
        const hr = swap_chain.GetSourceSize(&size.x, &size.y);
        if (hr < 0) fatalHr("GetSwapChainSourceSize", hr);
    }
    return size;
}

fn initSwapChain(
    device: *win32.ID3D11Device,
    hwnd: win32.HWND,
) *win32.IDXGISwapChain2 {
    const factory = getDxgiFactory(device);
    defer _ = factory.IUnknown.Release();

    const swap_chain1: *win32.IDXGISwapChain1 = blk: {
        var swap_chain1: *win32.IDXGISwapChain1 = undefined;
        const desc = win32.DXGI_SWAP_CHAIN_DESC1{
            .Width = 0,
            .Height = 0,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .NONE,
            .SwapEffect = .FLIP_DISCARD,
            .AlphaMode = .IGNORE,
            .Flags = swap_chain_flags,
        };
        {
            const hr = factory.CreateSwapChainForHwnd(
                &device.IUnknown,
                hwnd,
                &desc,
                null,
                null,
                &swap_chain1,
            );
            if (hr < 0) fatalHr("CreateD3dSwapChain", hr);
        }
        break :blk swap_chain1;
    };
    defer _ = swap_chain1.IUnknown.Release();

    {
        const color: win32.DXGI_RGBA = .{ .r = 0.075, .g = 0.075, .b = 0.075, .a = 1.0 };
        const hr = swap_chain1.SetBackgroundColor(&color);
        if (hr < 0) fatalHr("SetBackgroundColor", hr);
    }

    var swap_chain2: *win32.IDXGISwapChain2 = undefined;
    {
        const hr = swap_chain1.IUnknown.QueryInterface(win32.IID_IDXGISwapChain2, @ptrCast(&swap_chain2));
        if (hr < 0) fatalHr("QuerySwapChain2", hr);
    }

    // refterm is doing this but I don't know why
    if (false) {
        const hr = factory.IDXGIFactory.MakeWindowAssociation(hwnd, 0); //DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
        if (hr < 0) fatalHr("MakeWindowAssoc", hr);
    }

    return swap_chain2;
}

const Shaders = struct {
    vertex: *win32.ID3D11VertexShader,
    pixel: *win32.ID3D11PixelShader,
    pub fn init() Shaders {
        const shader_source = @embedFile("terminal.hlsl");

        var vs_blob: *win32.ID3DBlob = undefined;
        var error_blob: ?*win32.ID3DBlob = null;
        {
            const hr = win32.D3DCompile(
                shader_source.ptr,
                shader_source.len,
                null,
                null,
                null,
                "VertexMain",
                "vs_5_0",
                0,
                0,
                @ptrCast(&vs_blob),
                @ptrCast(&error_blob),
            );
            reportShaderError(.vertex, error_blob);
            error_blob = null;
            if (hr < 0) {
                fatalHr("D3DCompileVertexShader", hr);
            }
        }
        defer _ = vs_blob.IUnknown.Release();
        var ps_blob: *win32.ID3DBlob = undefined;
        {
            const hr = win32.D3DCompile(
                shader_source.ptr,
                shader_source.len,
                null,
                null,
                null,
                "PixelMain",
                "ps_5_0",
                0,
                0,
                @ptrCast(&ps_blob),
                @ptrCast(&error_blob),
            );
            reportShaderError(.pixel, error_blob);
            error_blob = null;
            if (hr < 0) {
                fatalHr("D3DCompilePixelShader", hr);
            }
        }
        defer _ = ps_blob.IUnknown.Release();

        var vertex_shader: *win32.ID3D11VertexShader = undefined;
        {
            const hr = global.d3d.device.CreateVertexShader(
                @ptrCast(vs_blob.GetBufferPointer()),
                vs_blob.GetBufferSize(),
                null,
                &vertex_shader,
            );
            if (hr < 0) fatalHr("CreateVertexShader", hr);
        }
        errdefer vertex_shader.IUnknown.Release();

        var pixel_shader: *win32.ID3D11PixelShader = undefined;
        {
            const hr = global.d3d.device.CreatePixelShader(
                @ptrCast(ps_blob.GetBufferPointer()),
                ps_blob.GetBufferSize(),
                null,
                &pixel_shader,
            );
            if (hr < 0) fatalHr("CreatePixelShader", hr);
        }
        errdefer pixel_shader.IUnknown.Release();

        return .{
            .vertex = vertex_shader,
            .pixel = pixel_shader,
        };
    }
};
fn reportShaderError(kind: enum { vertex, pixel }, maybe_error_blob: ?*win32.ID3DBlob) void {
    const err = maybe_error_blob orelse return;
    defer _ = err.IUnknown.Release();
    const ptr: [*]const u8 = @ptrCast(err.GetBufferPointer() orelse return);
    const str = ptr[0..err.GetBufferSize()];
    log.err("{s} shader error:\n{s}\n", .{ @tagName(kind), str });
    std.debug.panic("{s} shader error:\n{s}\n", .{ @tagName(kind), str });
}

const ShaderCells = struct {
    count: u32 = 0,
    cell_buf: *win32.ID3D11Buffer = undefined,
    cell_view: *win32.ID3D11ShaderResourceView = undefined,
    pub fn updateCount(self: *ShaderCells, count: u32) void {
        if (count == self.count) return;

        log.debug("CellCount {} > {}", .{ self.count, count });
        if (self.count != 0) {
            _ = self.cell_view.IUnknown.Release();
            _ = self.cell_buf.IUnknown.Release();
            self.count = 0;
        }

        if (count > 0) {
            self.cell_buf = createCellBuffer(global.d3d.device, count);
            errdefer {
                self.cell_buf.IUnknown.Release();
                self.cell_buf = undefined;
            }

            {
                const desc: win32.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
                    .Format = .UNKNOWN,
                    .ViewDimension = ._SRV_DIMENSION_BUFFER,
                    .Anonymous = .{
                        .Buffer = .{
                            .Anonymous1 = .{ .FirstElement = 0 },
                            .Anonymous2 = .{ .NumElements = count },
                        },
                    },
                };
                const hr = global.d3d.device.CreateShaderResourceView(
                    &self.cell_buf.ID3D11Resource,
                    &desc,
                    &self.cell_view,
                );
                if (hr < 0) fatalHr("CreateShaderResourceView for cells", hr);
            }
        }
        self.count = count;
    }
};

const GlyphTexture = struct {
    size: ?XY(u16) = null,
    obj: *win32.ID3D11Texture2D = undefined,
    view: *win32.ID3D11ShaderResourceView = undefined,
    pub fn updateSize(self: *GlyphTexture, size: XY(u16)) enum { retained, newly_created } {
        if (self.size) |existing_size| {
            if (existing_size.eql(size)) return .retained;

            _ = self.view.IUnknown.Release();
            self.view = undefined;
            _ = self.obj.IUnknown.Release();
            self.obj = undefined;
            self.size = null;
        }
        log.debug("GlyphTexture: init {}x{}", .{ size.x, size.y });

        {
            const desc: win32.D3D11_TEXTURE2D_DESC = .{
                .Width = size.x,
                .Height = size.y,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = .B8G8R8A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = .DEFAULT,
                .BindFlags = .{ .SHADER_RESOURCE = 1 },
                .CPUAccessFlags = .{},
                .MiscFlags = .{},
            };
            const hr = global.d3d.device.CreateTexture2D(&desc, null, &self.obj);
            if (hr < 0) fatalHr("CreateGlyphTexture", hr);
        }
        errdefer {
            self.obj.IUnknown.Release();
            self.obj = undefined;
        }

        {
            const hr = global.d3d.device.CreateShaderResourceView(
                &self.obj.ID3D11Resource,
                null,
                &self.view,
            );
            if (hr < 0) fatalHr("CreateGlyphView", hr);
        }
        self.size = size;
        return .newly_created;
    }
};

fn createRenderTargetView(
    device: *win32.ID3D11Device,
    swap_chain: *win32.IDXGISwapChain,
    size: XY(u32),
) *win32.ID3D11RenderTargetView {
    var back_buffer: *win32.ID3D11Texture2D = undefined;

    {
        const hr = swap_chain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
        if (hr < 0) fatalHr("SwapChainGetBuffer", hr);
    }
    defer _ = back_buffer.IUnknown.Release();

    var target_view: *win32.ID3D11RenderTargetView = undefined;
    {
        const hr = device.CreateRenderTargetView(&back_buffer.ID3D11Resource, null, &target_view);
        if (hr < 0) fatalHr("CreateRenderTargetView", hr);
    }

    {
        var viewport = win32.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(size.x),
            .Height = @floatFromInt(size.y),
            .MinDepth = 0.0,
            .MaxDepth = 0.0,
        };
        global.d3d.context.RSSetViewports(1, @ptrCast(&viewport));
    }
    // TODO: is this the right place to put this?
    global.d3d.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

    return target_view;
}

fn createCellBuffer(device: *win32.ID3D11Device, count: u32) *win32.ID3D11Buffer {
    var cell_buffer: *win32.ID3D11Buffer = undefined;
    const buffer_desc: win32.D3D11_BUFFER_DESC = .{
        .ByteWidth = count * @sizeOf(shader.Cell),
        .Usage = .DYNAMIC,
        .BindFlags = .{ .SHADER_RESOURCE = 1 },
        .CPUAccessFlags = .{ .WRITE = 1 },
        .MiscFlags = .{ .BUFFER_STRUCTURED = 1 },
        .StructureByteStride = @sizeOf(shader.Cell),
    };
    const hr = device.CreateBuffer(&buffer_desc, null, &cell_buffer);
    if (hr < 0) fatalHr("CreateCellBuffer", hr);
    return cell_buffer;
}

fn getD3d11TextureMaxCellCount(cell_size: XY(u16)) XY(u16) {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // small size so we can just render the whole texture for development
    //if (true) return .{ .x = 80, .y = 500 };
    comptime std.debug.assert(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION == 16384);
    return .{
        .x = @intCast(@divTrunc(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION, cell_size.x)),
        .y = @intCast(@divTrunc(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION, cell_size.y)),
    };
}

fn cellPosFromIndex(index: u32, column_count: u16) XY(u16) {
    return .{
        .x = @intCast(index % column_count),
        .y = @intCast(@divTrunc(index, column_count)),
    };
}
fn coordFromCellPos(cell_size: XY(u16), cell_pos: XY(u16)) XY(u16) {
    return .{
        .x = cell_size.x * cell_pos.x,
        .y = cell_size.y * cell_pos.y,
    };
}

fn getClientSize(comptime T: type, hwnd: win32.HWND) XY(T) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = @intCast(rect.right), .y = @intCast(rect.bottom) };
}

fn fatalWin32(what: []const u8, err: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, err.fmt() });
}
fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
