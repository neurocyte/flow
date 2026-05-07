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

pub const GlyphKind = TT.GlyphKind;
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

fn setItalicSynth(font: *Font, on: bool) void {
    switch (font.backend) {
        .truetype => |*f| f.italic_synth = on,
        .freetype => |*f| f.italic_synth = on,
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

/// Map CSS-style weight (100..900) to fontconfig's weight scale
fn cssToFcWeight(css: u16) u16 {
    const c = std.math.clamp(css, 100, 900);
    return switch ((c + 50) / 100) {
        0, 1 => 0, // Thin
        2 => 40, // ExtraLight
        3 => 50, // Light
        4 => 80, // Regular
        5 => 100, // Medium
        6 => 180, // SemiBold
        7 => 200, // Bold
        8 => 205, // ExtraBold
        else => 210, // Black
    };
}

fn boldCssWeight(css_regular: u16, offset: u16) u16 {
    return @min(900, css_regular + offset);
}

fn buildQuery(
    alloc: std.mem.Allocator,
    name: []const u8,
    css_weight: u16,
    italic: bool,
) ![]u8 {
    const fc_w = cssToFcWeight(css_weight);
    const slant: u16 = if (italic) 100 else 0; // ITALIC=100, ROMAN=0
    return std.fmt.allocPrint(alloc, "{s}:weight={d}:slant={d}", .{ name, fc_w, slant });
}

const FaceSpec = struct { face: Face, css_weight: u16, italic: bool };

pub fn loadFontSet(self: *Self, opts: LoadOpts) !FontSet {
    const alloc = self.tt.allocator;
    const reg_w = opts.weight;
    const bold_w = boldCssWeight(reg_w, opts.bold_offset);
    const have_bold_face = bold_w != reg_w;

    const reg_query = try buildQuery(alloc, opts.name, reg_w, false);
    defer alloc.free(reg_query);
    const regular_path = try font_finder.findFont(alloc, reg_query);
    defer alloc.free(regular_path);

    const regular = try self.loadFontFromPath(regular_path, opts.size_px);

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

        if (wants_bold and !have_bold_face) {
            // Skip lookup; bold-italic would otherwise alias onto the italic
            // file (its path differs from regular_path), so we'd install a
            // non-bold italic into the bold-italic slot.
        } else if (buildQuery(alloc, opts.name, spec.css_weight, spec.italic)) |query| {
            defer alloc.free(query);
            if (font_finder.findFont(alloc, query)) |path| {
                defer alloc.free(path);
                if (!std.mem.eql(u8, path, regular_path)) {
                    if (self.loadFontFromPath(path, opts.size_px)) |candidate| {
                        if (candidate.cell_size.x == regular.cell_size.x and
                            candidate.cell_size.y == regular.cell_size.y)
                        {
                            set.faces[idx] = candidate;
                            set.synth[idx] = false;
                            installed = true;
                        } else {
                            log.warn("rejecting face '{s}': cell {}x{} != regular {}x{}", .{
                                path,
                                candidate.cell_size.x,
                                candidate.cell_size.y,
                                regular.cell_size.x,
                                regular.cell_size.y,
                            });
                        }
                    } else |_| {}
                }
            } else |_| {}
        } else |_| {}

        if (!installed) {
            // No real face available
            if (spec.italic) setItalicSynth(&set.faces[idx], true);
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
    kind: GlyphKind,
    staging_buf: []u8,
) void {
    switch (font.backend) {
        .truetype => |f| self.tt.render(f, codepoint, kind, staging_buf),
        .freetype => |f| self.ft.render(f, codepoint, @enumFromInt(@intFromEnum(kind)), staging_buf),
    }
}
