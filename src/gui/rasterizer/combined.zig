/// Runtime switchable rasterizer
///
const std = @import("std");
const builtin = @import("builtin");
const XY = @import("xy").XY;

const is_windows = builtin.os.tag == .windows;

const TT = if (is_windows) void else @import("tt_rasterizer");
const FT = if (is_windows) void else @import("ft_rasterizer");
const DW = if (is_windows) @import("dw_rasterizer") else void;

const Primary = if (is_windows) DW else TT;

const log = std.log.scoped(.rasterizer);

pub const GlyphSplit = Primary.GlyphSplit;
pub const RasterFormat = Primary.RasterFormat;
pub const RenderResult = Primary.RenderResult;
pub const glyph_constraint = @import("glyph_constraint");
pub const Constraint = glyph_constraint.Constraint;
pub const Fonts = struct {};
pub const font_finder = Primary.font_finder;

pub const Backend = @import("gui_config").RasterizerBackend;
pub const Hinting = @import("gui_config").Hinting;
pub const SymbolRasterizer = @import("gui_config").SymbolRasterizer;

pub const Face = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// rasterizer specific font data
pub const RasterizerFont = if (is_windows)
    union(Backend) {
        dwrite: DW.Font,
    }
else
    union(Backend) {
        truetype: TT.Font,
        freetype: FT.Font,
    };

/// combined font handle
pub const Font = struct {
    cell_size: XY(u16),
    /// Top edge of the underline bar, in pixels from the top of the cell.
    underline_position: i32 = 0,
    /// Thickness of the underline bar, in pixels (>= 1).
    underline_thickness: u16 = 1,
    backend: RasterizerFont,
};

fn applySynthFlags(font: *Font, italic: bool, bold: bool) void {
    if (is_windows) {
        switch (font.backend) {
            .dwrite => |*f| f.synth = .{ .italic = italic, .bold = bold },
        }
    } else {
        switch (font.backend) {
            .truetype => |*f| f.synth = .{ .italic = italic, .bold = bold },
            .freetype => |*f| f.synth = .{ .italic = italic, .bold = bold },
        }
    }
}

fn applyLineHeightToFace(font: *Font, top_pad: i32, target_h: i32) void {
    const target_h_u: u16 = @intCast(target_h);
    const ul_thk: i32 = @intCast(font.underline_thickness);
    const new_ul: i32 = @max(0, @min(target_h - ul_thk, font.underline_position + top_pad));
    font.cell_size.y = target_h_u;
    font.underline_position = new_ul;
    if (is_windows) {
        switch (font.backend) {
            .dwrite => |*f| {
                f.cell_size.y = target_h_u;
                f.ascent_px += top_pad;
                f.underline_position = new_ul;
            },
        }
    } else {
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

active: Backend = if (is_windows) .dwrite else .truetype,
tt: if (is_windows) void else TT = if (is_windows) {} else undefined,
ft: if (is_windows) void else FT = if (is_windows) {} else undefined,
dw: if (is_windows) DW else void = if (is_windows) undefined else {},

pub fn init(allocator: std.mem.Allocator) !Self {
    if (is_windows) {
        const dw = try DW.init(allocator);
        return .{ .dw = dw };
    } else {
        const tt = try TT.init(allocator);
        const ft = try FT.init(allocator);
        return .{ .tt = tt, .ft = ft };
    }
}

pub fn deinit(self: *Self) void {
    if (is_windows) {
        self.dw.deinit();
    } else {
        self.tt.deinit();
        self.ft.deinit();
    }
}

pub fn setBackend(self: *Self, backend: Backend) void {
    self.active = backend;
}

pub fn setHinting(self: *Self, h: Hinting) void {
    if (is_windows) {
        self.dw.hinting = h;
    } else {
        self.ft.hinting = h;
    }
}

pub fn setSymbolRasterizer(self: *Self, sr: SymbolRasterizer) void {
    if (is_windows) {
        self.dw.block_and_line_symbols = sr;
    } else {
        self.tt.block_and_line_symbols = sr;
        self.ft.block_and_line_symbols = sr;
    }
}

pub fn setAllowColorGlyphs(self: *Self, allow: bool) void {
    if (is_windows) {
        self.dw.allow_color_glyphs = allow;
    } else {
        // self.tt does not support color glyphs
        self.ft.allow_color_glyphs = allow;
    }
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const allocator = if (is_windows) self.dw.allocator else self.tt.allocator;
    const match = try font_finder.findFont(allocator, name);
    defer allocator.free(match.path);
    return self.loadFontFromPath(match.path, match.face_index, size_px);
}

fn loadFontFromPath(self: *Self, path: []const u8, face_index: i32, size_px: u16) !Font {
    if (is_windows) {
        switch (self.active) {
            .dwrite => {
                const f = try self.dw.loadFontFromPath(path, size_px);
                return .{
                    .cell_size = f.cell_size,
                    .underline_position = f.underline_position,
                    .underline_thickness = f.underline_thickness,
                    .backend = .{ .dwrite = f },
                };
            },
        }
    } else {
        switch (self.active) {
            .truetype => {
                const f = try self.tt.loadFontFromPath(path, face_index, size_px);
                return .{
                    .cell_size = f.cell_size,
                    .underline_position = f.underline_position,
                    .underline_thickness = f.underline_thickness,
                    .backend = .{ .truetype = f },
                };
            },
            .freetype => {
                const f = try self.ft.loadFontFromPath(path, face_index, size_px);
                return .{
                    .cell_size = f.cell_size,
                    .underline_position = f.underline_position,
                    .underline_thickness = f.underline_thickness,
                    .backend = .{ .freetype = f },
                };
            },
        }
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
    if (is_windows) {
        switch (self.active) {
            .dwrite => {
                const r = try self.dw.resolveFace(.{
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
                        .backend = .{ .dwrite = r.font },
                    },
                    .is_real_match = r.is_real_match,
                };
            },
        }
    } else {
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

    if (!is_windows) {
        self.tt.releaseUnusedFaces();
        self.ft.releaseUnusedFaces();
        // dwrite faces are refcounted
    }

    return set;
}

pub fn glyphAdvance(self: *const Self, font: Font, codepoint: u21) ?u16 {
    if (is_windows) {
        return switch (font.backend) {
            .dwrite => |f| self.dw.glyphAdvance(f, codepoint),
        };
    } else {
        return switch (font.backend) {
            .truetype => null,
            .freetype => |f| self.ft.glyphAdvance(f, codepoint),
        };
    }
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    emoji_presentation: bool,
    constraint: Constraint,
    constraint_width: u2,
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    if (is_windows) {
        return switch (font.backend) {
            .dwrite => |f| blk: {
                const r = self.dw.render(f, codepoint, emoji_presentation, constraint, constraint_width, split, staging_buf);
                break :blk .{ .format = @enumFromInt(@intFromEnum(r.format)) };
            },
        };
    } else {
        return switch (font.backend) {
            .truetype => |f| blk: {
                const r = self.tt.render(f, codepoint, emoji_presentation, constraint, constraint_width, split, staging_buf);
                break :blk .{ .format = @enumFromInt(@intFromEnum(r.format)) };
            },
            .freetype => |f| blk: {
                const r = self.ft.render(f, codepoint, emoji_presentation, constraint, constraint_width, @enumFromInt(@intFromEnum(split)), staging_buf);
                break :blk .{ .format = @enumFromInt(@intFromEnum(r.format)) };
            },
        };
    }
}
