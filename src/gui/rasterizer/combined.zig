/// Combined rasterizer — wraps TrueType and FreeType backends with runtime switching.
/// Satisfies the GlyphRasterizer interface (see GlyphRasterizer.zig).
///
/// The active backend is changed via setBackend().  Callers must reload fonts
/// after switching (the Font struct's .backend tag must match the active backend).
const std = @import("std");
const XY = @import("xy").XY;
const TT = @import("tt_rasterizer");
const FT = @import("ft_rasterizer");

const log = std.log.scoped(.rasterizer);

pub const GlyphSplit = TT.GlyphSplit;
pub const RasterFormat = TT.RasterFormat;
pub const RenderResult = TT.RenderResult;
pub const Fonts = struct {};
pub const font_finder = TT.font_finder;

pub const Backend = @import("gui_config").RasterizerBackend;
pub const Hinting = @import("gui_config").Hinting;

pub const Face = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// Backend-specific font data.
pub const BackendFont = union(Backend) {
    truetype: TT.Font,
    freetype: FT.Font,
};

/// Combined font handle.  `cell_size` is hoisted to the top level so all
/// existing callers that do `font.cell_size.x / .y` continue to work without
/// change.  Backend-specific data lives in `backend`.
pub const Font = struct {
    cell_size: XY(u16),
    /// Top edge of the underline bar, in pixels from the top of the cell.
    underline_position: i32 = 0,
    /// Thickness of the underline bar, in pixels (>= 1).
    underline_thickness: u16 = 1,
    backend: BackendFont,
};

fn applySynthFlags(font: *Font, italic: bool, bold: bool) void {
    switch (font.backend) {
        .truetype => |*f| f.synth = .{ .italic = italic, .bold = bold },
        .freetype => |*f| f.synth = .{ .italic = italic, .bold = bold },
    }
}

fn applyLineHeightToFace(font: *Font, top_pad: i32, target_h: i32) void {
    const target_h_u: u16 = @intCast(target_h);
    const ul_thk: i32 = @intCast(font.underline_thickness);
    const new_ul: i32 = @max(0, @min(target_h - ul_thk, font.underline_position + top_pad));
    font.cell_size.y = target_h_u;
    font.underline_position = new_ul;
    switch (font.backend) {
        .truetype => |*f| {
            f.cell_size.y = target_h_u;
            f.ascent_px += top_pad;
            f.underline_position = new_ul;
        },
        .freetype => |*f| {
            f.cell_size.y = target_h_u;
            f.ascent_px += top_pad;
            f.underline_position = new_ul;
        },
    }
}

pub const FontSet = struct {
    cell_size: XY(u16),
    underline_position: i32,
    underline_thickness: u16,
    /// Indexed by @intFromEnum(Face).
    faces: [4]Font,
    synth: [4]bool,
};

pub const LoadOpts = struct {
    name: []const u8,
    size_px: u16,
    weight: u16 = 400,
    bold_offset: u16 = 300,
    line_height_pct: u8 = 100,
};

const Self = @This();

active: Backend = .truetype,
tt: TT,
ft: FT,

pub fn init(allocator: std.mem.Allocator) !Self {
    const tt = try TT.init(allocator);
    const ft = try FT.init(allocator);
    return .{ .tt = tt, .ft = ft };
}

pub fn deinit(self: *Self) void {
    self.tt.deinit();
    self.ft.deinit();
}

pub fn setBackend(self: *Self, backend: Backend) void {
    self.active = backend;
}

pub fn setHinting(self: *Self, h: Hinting) void {
    self.ft.hinting = h;
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const path = try font_finder.findFont(self.tt.allocator, name);
    defer self.tt.allocator.free(path);
    return self.loadFontFromPath(path, size_px);
}

fn loadFontFromPath(self: *Self, path: []const u8, size_px: u16) !Font {
    switch (self.active) {
        .truetype => {
            const f = try self.tt.loadFontFromPath(path, size_px);
            return .{
                .cell_size = f.cell_size,
                .underline_position = f.underline_position,
                .underline_thickness = f.underline_thickness,
                .backend = .{ .truetype = f },
            };
        },
        .freetype => {
            const f = try self.ft.loadFontFromPath(path, size_px);
            return .{
                .cell_size = f.cell_size,
                .underline_position = f.underline_position,
                .underline_thickness = f.underline_thickness,
                .backend = .{ .freetype = f },
            };
        },
    }
}

fn boldCssWeight(css_regular: u16, offset: u16) u16 {
    return @min(900, css_regular + offset);
}

const FaceResolution = struct { font: Font, is_real_match: bool };

fn resolveActive(
    self: *Self,
    family: []const u8,
    css_weight: u16,
    italic: bool,
    size_px: u16,
    is_baseline: bool,
) !FaceResolution {
    switch (self.active) {
        .truetype => {
            const r = try self.tt.resolveFace(.{
                .family = family,
                .css_weight = css_weight,
                .italic = italic,
                .size_px = size_px,
                .is_baseline = is_baseline,
            });
            return .{
                .font = .{
                    .cell_size = r.font.cell_size,
                    .underline_position = r.font.underline_position,
                    .underline_thickness = r.font.underline_thickness,
                    .backend = .{ .truetype = r.font },
                },
                .is_real_match = r.is_real_match,
            };
        },
        .freetype => {
            const r = try self.ft.resolveFace(.{
                .family = family,
                .css_weight = css_weight,
                .italic = italic,
                .size_px = size_px,
                .is_baseline = is_baseline,
            });
            return .{
                .font = .{
                    .cell_size = r.font.cell_size,
                    .underline_position = r.font.underline_position,
                    .underline_thickness = r.font.underline_thickness,
                    .backend = .{ .freetype = r.font },
                },
                .is_real_match = r.is_real_match,
            };
        },
    }
}

const FaceSpec = struct { face: Face, css_weight: u16, italic: bool };

pub fn loadFontSet(self: *Self, opts: LoadOpts) !FontSet {
    const reg_w = opts.weight;
    const bold_w = boldCssWeight(reg_w, opts.bold_offset);
    const have_bold_face = bold_w != reg_w;

    const reg_res = try resolveActive(self, opts.name, reg_w, false, opts.size_px, true);
    const regular = reg_res.font;

    var set: FontSet = .{
        .cell_size = regular.cell_size,
        .underline_position = regular.underline_position,
        .underline_thickness = regular.underline_thickness,
        .faces = .{ regular, regular, regular, regular },
        .synth = .{ false, true, true, true },
    };

    const face_specs = [_]FaceSpec{
        .{ .face = .bold, .css_weight = bold_w, .italic = false },
        .{ .face = .italic, .css_weight = reg_w, .italic = true },
        .{ .face = .bold_italic, .css_weight = bold_w, .italic = true },
    };

    inline for (face_specs) |spec| {
        const idx = @intFromEnum(spec.face);
        const wants_bold = spec.face == .bold or spec.face == .bold_italic;
        var installed = false;

        if (!(wants_bold and !have_bold_face)) {
            if (resolveActive(self, opts.name, spec.css_weight, spec.italic, opts.size_px, false)) |r| {
                if (r.is_real_match) {
                    if (r.font.cell_size.x == regular.cell_size.x and
                        r.font.cell_size.y == regular.cell_size.y)
                    {
                        set.faces[idx] = r.font;
                        set.synth[idx] = false;
                        installed = true;
                    } else {
                        log.warn("rejecting face: cell {}x{} != regular {}x{}", .{
                            r.font.cell_size.x,
                            r.font.cell_size.y,
                            regular.cell_size.x,
                            regular.cell_size.y,
                        });
                    }
                }
            } else |_| {}
        }

        if (!installed) {
            applySynthFlags(&set.faces[idx], spec.italic, wants_bold);
            set.synth[idx] = true;
        }
    }

    const pct = std.math.clamp(opts.line_height_pct, 50, 200);
    if (pct != 100) {
        const orig_h: i32 = @intCast(set.cell_size.y);
        const target_h: i32 = @max(1, @divFloor(orig_h * @as(i32, pct), 100));
        const top_pad: i32 = @divFloor(target_h - orig_h, 2);
        const ul_thk: i32 = @intCast(set.underline_thickness);
        set.cell_size.y = @intCast(target_h);
        set.underline_position = @max(0, @min(target_h - ul_thk, set.underline_position + top_pad));
        for (&set.faces) |*f| applyLineHeightToFace(f, top_pad, target_h);
    }

    return set;
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    return switch (font.backend) {
        .truetype => |f| blk: {
            const r = self.tt.render(f, codepoint, split, staging_buf);
            break :blk .{ .format = @enumFromInt(@intFromEnum(r.format)) };
        },
        .freetype => |f| blk: {
            const r = self.ft.render(f, codepoint, @enumFromInt(@intFromEnum(split)), staging_buf);
            break :blk .{ .format = @enumFromInt(@intFromEnum(r.format)) };
        },
    };
}
