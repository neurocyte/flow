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
    text_format_single: *win32.IDWriteTextFormat,
    text_format_double: *win32.IDWriteTextFormat,
    cell_size: XY(u16),

    pub fn init(dpi: u32, size: f32, face: *const FontFace) Font {
        var text_format_single: *win32.IDWriteTextFormat = undefined;

        {
            const hr = global.dwrite_factory.CreateTextFormat(
                face.ptr(),
                null,
                .NORMAL, //weight
                .NORMAL, // style
                .NORMAL, // stretch
                win32.scaleDpi(f32, size, dpi),
                win32.L(""), // locale
                &text_format_single,
            );
            if (hr < 0) std.debug.panic(
                "CreateTextFormat '{f}' height {d} failed, hresult=0x{x}",
                .{ std.unicode.fmtUtf16Le(face.slice()), size, @as(u32, @bitCast(hr)) },
            );
        }
        errdefer _ = text_format_single.IUnknown.Release();

        var text_format_double: *win32.IDWriteTextFormat = undefined;
        {
            const hr = global.dwrite_factory.CreateTextFormat(
                face.ptr(),
                null,
                .NORMAL, //weight
                .NORMAL, // style
                .NORMAL, // stretch
                win32.scaleDpi(f32, size, dpi),
                win32.L(""), // locale
                &text_format_double,
            );
            if (hr < 0) std.debug.panic(
                "CreateTextFormat '{f}' height {d} failed, hresult=0x{x}",
                .{ std.unicode.fmtUtf16Le(face.slice()), size, @as(u32, @bitCast(hr)) },
            );
        }
        errdefer _ = text_format_double.IUnknown.Release();

        {
            const hr = text_format_double.SetTextAlignment(win32.DWRITE_TEXT_ALIGNMENT_CENTER);
            if (hr < 0) fatalHr("SetTextAlignment", hr);
        }

        {
            const hr = text_format_double.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
            if (hr < 0) fatalHr("SetParagraphAlignment", hr);
        }

        const cell_size: XY(u16) = blk: {
            var text_layout: *win32.IDWriteTextLayout = undefined;
            {
                const hr = global.dwrite_factory.CreateTextLayout(
                    win32.L("█"),
                    1,
                    text_format_single,
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
            .text_format_single = text_format_single,
            .text_format_double = text_format_double,
            .cell_size = cell_size,
        };
    }

    pub fn deinit(self: *Font) void {
        _ = self.text_format_single.IUnknown.Release();
        _ = self.text_format_double.IUnknown.Release();
        self.* = undefined;
    }

    pub fn getCellSize(self: Font, comptime T: type) XY(T) {
        return .{
            .x = @intCast(self.cell_size.x),
            .y = @intCast(self.cell_size.y),
        };
    }
};

pub const Fonts = struct {
    collection: *win32.IDWriteFontCollection,
    pub fn init() Fonts {
        var collection: *win32.IDWriteFontCollection = undefined;
        const hr = global.dwrite_factory.GetSystemFontCollection(
            &collection,
            1, // check for updates (not sure why this is even an option)
        );
        if (hr < 0) fatalHr("GetSystemFontCollection", hr);
        return .{ .collection = collection };
    }
    pub fn deinit(self: Fonts) void {
        _ = self.collection.IUnknown.Release();
    }
    pub fn count(self: Fonts) usize {
        return @intCast(self.collection.GetFontFamilyCount());
    }

    pub fn getName(self: Fonts, index: usize) FontFace {
        var family: *win32.IDWriteFontFamily = undefined;
        {
            const hr = self.collection.GetFontFamily(@intCast(index), &family);
            if (hr < 0) fatalHr("GetFontFamily", hr);
        }
        defer _ = family.IUnknown.Release();

        var names: *win32.IDWriteLocalizedStrings = undefined;
        {
            const hr = family.GetFamilyNames(&names);
            if (hr < 0) fatalHr("GetFamilyNames", hr);
        }
        defer _ = names.IUnknown.Release();

        // code currently assumes this is always true
        std.debug.assert(names.GetCount() >= 1);

        // leaving this code in in case we ever want to implement
        // some sort logic to pick a string based on locale
        if (false) {
            const locale_count = names.GetCount();
            std.log.info("Font {} has {} string locales", .{ index, locale_count });
            for (0..locale_count) |i| {
                var locale_name_len: u32 = undefined;
                {
                    const hr = names.GetLocaleNameLength(@intCast(i), &locale_name_len);
                    if (hr < 0) fatalHr("GetLocaleNameLength", hr);
                }
                std.debug.assert(locale_name_len <= win32.LOCALE_NAME_MAX_LENGTH);
                var locale_name_buf: [win32.LOCALE_NAME_MAX_LENGTH + 1]u16 = undefined;
                {
                    const hr = names.GetLocaleName(@intCast(i), @ptrCast(&locale_name_buf), locale_name_buf.len);
                    if (hr < 0) fatalHr("GetLocaleName", hr);
                }
                const locale_name = locale_name_buf[0..locale_name_len];
                std.log.info("  {} '{}'", .{ i, std.unicode.fmtUtf16Le(locale_name) });
            }
        }

        var name_length: u32 = undefined;
        {
            const hr = names.GetStringLength(0, &name_length);
            if (hr < 0) fatalHr("GetStringLength", hr);
        }

        if (name_length > FontFace.max) std.debug.panic(
            "font name length {} too long (max is {}, we either need to increase max or use allocation)",
            .{ name_length, FontFace.max },
        );

        var result: FontFace = .{ .buf = undefined, .len = @intCast(name_length) };

        {
            // note: we're just asking for the first one, whatever locale it is
            const hr = names.GetString(0, @ptrCast(&result.buf), name_length + 1);
            if (hr < 0) fatalHr("GetString", hr);
        }

        return result;
    }
};

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
