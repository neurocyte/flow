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

/// Set emboldening weight on a font (0 = normal).
/// For TrueType: number of morphological dilation passes.
/// For FreeType: outline inflation at 32 units per weight step (0.5px each).
pub fn setFontWeight(font: *Font, w: u8) void {
    switch (font.backend) {
        .truetype => |*f| f.weight = w,
        .freetype => |*f| f.weight_strength = @as(i64, w) * 32,
    }
}

fn setItalicSynth(font: *Font, on: bool) void {
    switch (font.backend) {
        .truetype => |*f| f.italic_synth = on,
        .freetype => |*f| f.italic_synth = on,
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
    weight: u8 = 0,
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

const FaceQuery = struct { face: Face, suffix: []const u8 };
const face_queries = [_]FaceQuery{
    .{ .face = .bold, .suffix = "Bold" },
    .{ .face = .italic, .suffix = "Italic" },
    .{ .face = .bold_italic, .suffix = "Bold Italic" },
};

fn buildQuery(alloc: std.mem.Allocator, name: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}:style={s}", .{ name, suffix });
}

pub fn loadFontSet(self: *Self, opts: LoadOpts) !FontSet {
    const alloc = self.tt.allocator;

    const regular_path = try font_finder.findFont(alloc, opts.name);
    defer alloc.free(regular_path);

    var regular = try self.loadFontFromPath(regular_path, opts.size_px);
    if (opts.weight > 0) setFontWeight(&regular, opts.weight);

    var set: FontSet = .{
        .cell_size = regular.cell_size,
        .underline_position = regular.underline_position,
        .underline_thickness = regular.underline_thickness,
        .faces = .{ regular, regular, regular, regular },
        .synth = .{ false, true, true, true },
    };

    // try to load via fontconfig, fall back to synthesis
    inline for (face_queries) |q| {
        const idx = @intFromEnum(q.face);
        var installed = false;

        if (buildQuery(alloc, opts.name, q.suffix)) |query| {
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
            // Synthesis fallback
            const wants_bold = q.face == .bold or q.face == .bold_italic;
            const wants_italic = q.face == .italic or q.face == .bold_italic;
            if (wants_bold) {
                // Add one extra weight step over regular
                setFontWeight(&set.faces[idx], opts.weight + 1);
            }
            if (wants_italic) setItalicSynth(&set.faces[idx], true);
            set.synth[idx] = true;
        }
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
