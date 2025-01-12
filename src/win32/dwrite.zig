const std = @import("std");
const win32 = @import("win32").everything;

const FontFace = @import("FontFace.zig");
const XY = @import("xy.zig").XY;

const global = struct {
    var init_called: bool = false;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
};

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
}

pub const Font = struct {
    text_format: *win32.IDWriteTextFormat,
    cell_size: XY(u16),

    pub fn init(dpi: u32, size: f32, face: *const FontFace) Font {
        var text_format: *win32.IDWriteTextFormat = undefined;
        {
            const hr = global.dwrite_factory.CreateTextFormat(
                face.ptr(),
                null,
                .NORMAL, //weight
                .NORMAL, // style
                .NORMAL, // stretch
                win32.scaleDpi(f32, size, dpi),
                win32.L(""), // locale
                &text_format,
            );
            if (hr < 0) std.debug.panic(
                "CreateTextFormat '{}' height {d} failed, hresult=0x{x}",
                .{ std.unicode.fmtUtf16le(face.slice()), size, @as(u32, @bitCast(hr)) },
            );
        }
        errdefer _ = text_format.IUnknown.Release();

        const cell_size = blk: {
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
            break :blk .{
                .x = @as(u16, @intFromFloat(@floor(metrics.width))),
                .y = @as(u16, @intFromFloat(@floor(metrics.height))),
            };
        };

        return .{
            .text_format = text_format,
            .cell_size = cell_size,
        };
    }

    pub fn deinit(self: *Font) void {
        _ = self.text_format.IUnknown.Release();
        self.* = undefined;
    }

    pub fn getCellSize(self: Font, comptime T: type) XY(T) {
        return .{
            .x = @intCast(self.cell_size.x),
            .y = @intCast(self.cell_size.y),
        };
    }
};

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
