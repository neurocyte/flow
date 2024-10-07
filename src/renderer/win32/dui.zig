const std = @import("std");
const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.direct2d.common;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.direct2d;
};

pub fn scale_dpi_i32(value: i32, dpi: u32) @TypeOf(value) {
    return @intFromFloat(
        @as(f32, @floatFromInt(value)) * (@as(f32, @floatFromInt(dpi)) / 96.0)
    );
}

const ErrorContext = enum {
    CreateFactory,
    CreateRenderTarget,
    BindDC,
    EndDraw,
    CreatePathGeometry,
    PathGeometryOpen,
    ResizeRenderTarget,
};

pub const Error = struct {
    /// a win32 HRESULT
    hr: u32 = 0,
    context: ErrorContext = undefined,
    pub fn set(
        self: *Error,
        hr: win32.HRESULT,
        context: ErrorContext,
    ) DuiError {
        self.* = .{ .hr = @bitCast(hr), .context = context };
        return error.Dui;
    }
};

// a special error code that if ever returns should
// have populated a context and hresult
pub const DuiError = error {Dui};

fn createFactory(debug_level: win32.D2D1_DEBUG_LEVEL, err: *Error) DuiError!*win32.ID2D1Factory {
    var factory: *win32.ID2D1Factory = undefined;
    const options: win32.D2D1_FACTORY_OPTIONS = .{
        .debugLevel = debug_level,
    };
    const hr = win32.D2D1CreateFactory(
        .SINGLE_THREADED,
        win32.IID_ID2D1Factory,
        &options,
        @ptrCast(&factory),
    );
    if (hr != win32.S_OK) return err.set(hr, .CreateFactory);
    return factory;
}

pub const InitOptions = struct {
    debug_level: win32.D2D1_DEBUG_LEVEL = .NONE,
};

pub fn initHwnd(hwnd: win32.HWND, err: *Error, options: InitOptions) DuiError!Ui {
    const factory = try createFactory(options.debug_level, err);
    errdefer _ = factory.IUnknown.Release();

    var render: *win32.ID2D1HwndRenderTarget = undefined;
    const render_props = win32.D2D1_RENDER_TARGET_PROPERTIES{
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
    const hwnd_render_props = win32.D2D1_HWND_RENDER_TARGET_PROPERTIES{
        .hwnd = hwnd,
        .pixelSize = .{ .width = 0, .height = 0 },
        .presentOptions = .{},
    };

    {
        const hr = factory.CreateHwndRenderTarget(
            &render_props,
            &hwnd_render_props,
            @ptrCast(&render),
        );
        if (hr != win32.S_OK)
            return err.set(hr, .CreateRenderTarget);
    }

    // just make everything DPI aware, all applications should just do this
    //get_device_context_raw(render_target.get())->SetUnitMode(D2D1_UNIT_MODE_PIXELS);
    return .{
        .factory = factory,
        .render = @ptrCast(render),
        .kind = .{ .hwnd = hwnd },
    };
}


pub const Ui = struct {
    factory: *win32.ID2D1Factory,
    render: *win32.ID2D1RenderTarget,
    kind: union(enum) {
        hwnd: win32.HWND,
    },

    pub fn deinit(self: *Ui) void {
        _ = self.render.IUnknown.Release();
        _ = self.factory.IUnknown.Release();
        self.* = undefined;
    }

    pub fn beginPaintHwnd(
        self: Ui,
        paint: *win32.PAINTSTRUCT,
        dpi: u32,
        size: win32.D2D_SIZE_U,
        err: *Error,
    ) DuiError!void {
        std.debug.assert(self.kind == .hwnd);
        _ = win32.BeginPaint(self.kind.hwnd, paint) orelse std.debug.panic(
            "BeginPaint failed, error={}", .{win32.GetLastError()}
        );
        self.render.SetDpi(@floatFromInt(dpi), @floatFromInt(dpi));

        {
            const hr = (
                @as(*win32.ID2D1HwndRenderTarget, @ptrCast(self.render))
            ).Resize(&size);
            if (hr != win32.S_OK)
                return err.set(hr, .ResizeRenderTarget);
        }
        self.render.BeginDraw();
    }

    pub fn endPaintHwnd(self: Ui, paint: *win32.PAINTSTRUCT, err: *Error) DuiError!void {
        std.debug.assert(self.kind == .hwnd);
        {
            const hr = self.render.EndDraw(null, null);
            if (hr != win32.S_OK)
                return err.set(hr, .EndDraw);
        }
        if (0 == win32.EndPaint(self.kind.hwnd, paint)) std.debug.panic(
            "EndPaint failed, error={}", .{win32.GetLastError()}
        );
    }

};
