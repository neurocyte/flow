/// DirectWrite glyph rasterizer
///
const std = @import("std");
const XY = @import("xy").XY;

const Self = @This();

pub const GlyphSplit = enum { single, left, right };
pub const Hinting = @import("gui_config").Hinting;

pub const RasterFormat = enum(u2) {
    alpha = 0,
    subpixel = 1,
    color = 2,
};

pub const RenderResult = struct { format: RasterFormat };

pub const Fonts = struct {};

pub const SynthFlags = packed struct(u8) {
    italic: bool = false,
    bold: bool = false,
    _pad: u6 = 0,
};

pub const Font = struct {
    cell_size: XY(u16) = .{ .x = 8, .y = 16 },
    ascent_px: i32 = 0,
    underline_position: i32 = 0,
    underline_thickness: u16 = 1,
    synth: SynthFlags = .{},
};

pub const FaceRequest = struct {
    family: []const u8,
    css_weight: u16,
    italic: bool,
    size_px: u16,
    is_baseline: bool,
};

pub const FaceResolution = struct {
    font: Font,
    is_real_match: bool,
};

pub const font_finder = struct {
    pub const FontFinderError = error{ FontFinderNotSupported, OutOfMemory };
    pub fn findFont(_: std.mem.Allocator, _: []const u8) FontFinderError![]u8 {
        return error.FontFinderNotSupported;
    }
    pub fn listFonts(allocator: std.mem.Allocator) FontFinderError![][]u8 {
        return allocator.alloc([]u8, 0);
    }
};

allocator: std.mem.Allocator,
hinting: Hinting = .normal,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator };
}

pub fn deinit(_: *Self) void {}

pub fn loadFont(_: *Self, _: []const u8, _: u16) !Font {
    return error.DWriteNotImplemented;
}

pub fn loadFontFromPath(_: *Self, _: []const u8, _: u16) !Font {
    return error.DWriteNotImplemented;
}

pub fn resolveFace(_: *Self, _: FaceRequest) !FaceResolution {
    return error.DWriteNotImplemented;
}

pub fn render(_: *const Self, _: Font, _: u21, _: GlyphSplit, _: []u8) RenderResult {
    return .{ .format = .alpha };
}
