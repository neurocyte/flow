const std = @import("std");
const TrueType = @import("TrueType");
const XY = @import("xy").XY;
pub const font_finder = @import("font_finder");
const fallback_resolver = @import("fallback_resolver");
const flow_sprite = @import("flow_sprite");
const root = @import("soft_root").root;
const SymbolRasterizer = @import("gui_config").SymbolRasterizer;
const glyph_constraint = @import("glyph_constraint");

const Self = @This();

const nerd_font_data = @embedFile("nerd_font");

fn unitsPerEm(tt: *const TrueType) u16 {
    const head = tt.table_offsets[@intFromEnum(TrueType.TableId.head)];
    return std.mem.readInt(u16, tt.ttf_bytes[head + 18 ..][0..2], .big);
}

fn blitAlphaAt(staging_buf: []u8, buf_w: i32, buf_h: i32, src: []const u8, gw: i32, gh: i32, dst_x0: i32, dst_y0: i32) void {
    if (gw <= 0 or gh <= 0) return;
    var row: i32 = 0;
    while (row < gh) : (row += 1) {
        const py = dst_y0 + row;
        if (py < 0 or py >= buf_h) continue;
        var col: i32 = 0;
        while (col < gw) : (col += 1) {
            const px = dst_x0 + col;
            if (px < 0 or px >= buf_w) continue;
            const src_idx: usize = @intCast(row * gw + col);
            const dst_idx: usize = @as(usize, @intCast(py * buf_w + px)) * 4;
            if (src_idx < src.len and dst_idx < staging_buf.len) staging_buf[dst_idx] = src[src_idx];
        }
    }
}

const TtBackend = struct {
    pub const Context = void;
    pub const Face = struct {
        tt: TrueType,
        units_per_em: u16,
        data: ?[]u8,
    };

    pub const embedded_fonts = [_]fallback_resolver.EmbeddedFont{
        .{ .data = nerd_font_data, .is_color = false, .tag = "<embedded:nerd_font>" },
    };

    pub fn preferColor(_: u21) bool {
        return false;
    }

    pub fn loadEmbedded(_: void, _: std.mem.Allocator, data: []const u8, _: u16, _: bool) ?Face {
        const tt = TrueType.load(data) catch return null;
        return .{ .tt = tt, .units_per_em = unitsPerEm(&tt), .data = null };
    }

    pub fn loadPath(_: void, allocator: std.mem.Allocator, cand: font_finder.FallbackCandidate, _: u16) ?Face {
        const data = readFontFile(allocator, cand.path) catch return null;
        const tt = TrueType.load(data) catch {
            allocator.free(data);
            return null;
        };
        if (tt.table_offsets[@intFromEnum(TrueType.TableId.glyf)] == 0) {
            allocator.free(data);
            return null;
        }
        return .{ .tt = tt, .units_per_em = unitsPerEm(&tt), .data = data };
    }

    pub fn hasGlyph(face: *const Face, codepoint: u21) bool {
        return face.tt.codepointGlyphIndex(codepoint) != .notdef;
    }

    pub fn deinitFace(_: void, allocator: std.mem.Allocator, face: *Face) void {
        if (face.data) |d| allocator.free(d);
    }
};

const FallbackResolver = fallback_resolver.FallbackResolver(TtBackend);

fn readFontFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = root.get_io();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    var read_buf: [4096]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    return try reader.interface.readAlloc(allocator, @intCast(stat.size));
}

pub const GlyphSplit = enum {
    single,
    left,
    right,
};

pub const RasterFormat = enum(u2) {
    alpha = 0,
    subpixel = 1,
    color = 2,
};

pub const RenderResult = struct { format: RasterFormat };

pub const SynthFlags = packed struct(u8) {
    italic: bool = false, // noop for TrueType
    bold: bool = false, // noop for TrueType
    _pad: u6 = 0,
};

pub const Font = struct {
    cell_size: XY(u16),
    scale: f32 = 0,
    size_px: u16 = 0,
    ascent_px: i32 = 0,
    /// Top edge of the underline bar, in pixels from the top of the cell.
    underline_position: i32 = 0,
    /// Thickness of the underline bar, in pixels (>= 1).
    underline_thickness: u16 = 1,
    box_thickness: u16 = 1,
    tt: ?TrueType = null,
    synth: SynthFlags = .{},

    face_width: f64 = 0,
    face_height: f64 = 0,
    face_y: f64 = 0,
    icon_height: f64 = 0,
    icon_height_single: f64 = 0,
};

pub fn constraintMetrics(font: Font) glyph_constraint.Metrics {
    return .{
        .cell_width = font.cell_size.x,
        .cell_height = font.cell_size.y,
        .face_width = font.face_width,
        .face_height = font.face_height,
        .face_y = font.face_y,
        .icon_height = font.icon_height,
        .icon_height_single = font.icon_height_single,
    };
}

pub const Fonts = struct {};

pub const FaceRequest = struct {
    family: []const u8,
    css_weight: u16,
    italic: bool,
    size_px: u16,
    /// regular face font set
    is_baseline: bool,
};

pub const FaceResolution = struct {
    font: Font,
    /// face differs from baseline
    is_real_match: bool,
};

allocator: std.mem.Allocator,
font_data: std.ArrayListUnmanaged([]u8),
regular_path: ?[]u8 = null,
block_and_line_symbols: SymbolRasterizer = .default,
fallback: ?*FallbackResolver = null,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .font_data = .empty,
    };
}

pub fn deinit(self: *Self) void {
    if (self.fallback) |fb| {
        fb.deinit({}, self.allocator);
        self.allocator.destroy(fb);
    }
    self.fallback = null;
    if (self.regular_path) |p| self.allocator.free(p);
    self.regular_path = null;
    for (self.font_data.items) |data| {
        self.allocator.free(data);
    }
    self.font_data.deinit(self.allocator);
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const path = try font_finder.findFont(self.allocator, name);
    defer self.allocator.free(path);
    return self.loadFontFromPath(path, size_px);
}

pub fn loadFontFromPath(self: *Self, path: []const u8, size_px: u16) !Font {
    const io = root.get_io();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    var read_buf: [4096]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    const data = try reader.interface.readAlloc(self.allocator, @intCast(stat.size));
    errdefer self.allocator.free(data);

    const tt = try TrueType.load(data);

    const head_offset = tt.table_offsets[@intFromEnum(TrueType.TableId.head)];
    const units_per_em: u16 = std.mem.readInt(u16, tt.ttf_bytes[head_offset + 18 ..][0..2], .big);
    const scale: f32 = @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(@max(units_per_em, 1)));
    const vm = tt.verticalMetrics();

    const sc: f64 = scale;
    const m_ascent: f64 = @as(f64, @floatFromInt(vm.ascent)) * sc;
    const m_descent: f64 = @as(f64, @floatFromInt(vm.descent)) * sc; // < 0, below baseline
    const m_line_gap: f64 = @max(0.0, @as(f64, @floatFromInt(vm.line_gap)) * sc);
    const m_line_height: f64 = (m_ascent - m_descent) + m_line_gap;
    const m_face_baseline: f64 = (m_line_gap / 2.0) - m_descent;
    const cell_h_f: f64 = @max(1.0, @round(m_line_height));
    const cell_h: u16 = @intFromFloat(cell_h_f);
    const cell_baseline: f64 = @round(m_face_baseline - (cell_h_f - m_line_height) / 2.0);
    const ascent_px: i32 = @intFromFloat(cell_h_f - cell_baseline);

    const m_glyph = tt.codepointGlyphIndex('M');
    const m_hmetrics = tt.glyphHMetrics(m_glyph);
    const cell_w_f: f32 = @as(f32, @floatFromInt(m_hmetrics.advance_width)) * scale;
    const cell_w: u16 = @max(1, @as(u16, @intFromFloat(@ceil(cell_w_f))));

    const m_bbox = tt.glyphBitmapBox(m_glyph, scale, scale);
    const cap_height_px: f64 = if (m_glyph != .notdef and m_bbox.y1 > m_bbox.y0)
        @floatFromInt(-@as(i32, m_bbox.y0))
    else
        @as(f64, @floatFromInt(ascent_px)) * 0.7;

    const grid_metrics = glyph_constraint.metricsFromFace(.{
        .cell_width = cell_w,
        .cell_height = cell_h,
        .cell_baseline_from_top = @floatFromInt(ascent_px),
        .face_advance = @as(f64, cell_w_f),
        .face_ascent = m_ascent,
        .face_descent = m_descent,
        .face_line_gap = m_line_gap,
        .cap_height = cap_height_px,
    });

    try self.font_data.append(self.allocator, data);

    // Underline metrics: the TrueType package doesn't expose post/OS-2
    // tables, so use a heuristic derived from cell geometry. Roughly
    // matches what most fonts specify: thickness ≈ size / 14, position
    // about ⅓ of the way into the descender region.
    const ul_thk_px: u16 = @max(1, @as(u16, @intCast(@divFloor(@as(i32, @intCast(size_px)), 14))));
    const box_thk_px: u16 = @max(1, @as(u16, @intCast(@divFloor(@as(i32, @intCast(size_px)) + 13, 14))));
    const cell_h_i: i32 = @intCast(cell_h);
    const descender: i32 = @max(1, cell_h_i - ascent_px);
    const ul_pos_unclamped: i32 = ascent_px + @divFloor(descender, 3);
    const ul_top: i32 = @max(0, @min(cell_h_i - @as(i32, ul_thk_px), ul_pos_unclamped));

    return Font{
        .tt = tt, // TrueType holds a slice into `data` which is now owned by self.font_data
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .scale = scale,
        .size_px = size_px,
        .ascent_px = ascent_px,
        .underline_position = ul_top,
        .underline_thickness = ul_thk_px,
        .box_thickness = box_thk_px,
        .face_width = grid_metrics.face_width,
        .face_height = grid_metrics.face_height,
        .face_y = grid_metrics.face_y,
        .icon_height = grid_metrics.icon_height,
        .icon_height_single = grid_metrics.icon_height_single,
    };
}

/// Resolve a face for a given family + weight + style
pub fn resolveFace(self: *Self, req: FaceRequest) !FaceResolution {
    if (req.is_baseline) {
        if (self.regular_path) |old| self.allocator.free(old);
        self.regular_path = null;
    }

    const path = try font_finder.findFontVariant(
        self.allocator,
        req.family,
        req.css_weight,
        req.italic,
    );
    errdefer self.allocator.free(path);

    const is_real = if (req.is_baseline)
        true
    else if (self.regular_path) |reg|
        !std.mem.eql(u8, path, reg)
    else
        true;

    const font = try self.loadFontFromPath(path, req.size_px);

    if (req.is_baseline) {
        self.regular_path = path; // transfer ownership
    } else {
        self.allocator.free(path);
    }

    return .{ .font = font, .is_real_match = is_real };
}

/// Rasterize a glyph into the staging buffer
/// The staging buffer is RGBA8
/// alpha format is written into the red channel
pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    emoji_presentation: bool,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
    split: GlyphSplit,
    staging_buf: []u8,
) RenderResult {
    _ = emoji_presentation; // truetype has no color path
    const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
    const buf_h: i32 = @intCast(font.cell_size.y);
    const x_offset: i32 = switch (split) {
        .single, .left => 0,
        .right => @intCast(font.cell_size.x),
    };
    const cw: i32 = @intCast(font.cell_size.x);
    const ch: i32 = @intCast(font.cell_size.y);

    if (self.block_and_line_symbols == .sprite) {
        if (flow_sprite.renderSprite(self.allocator, codepoint, staging_buf, buf_w, buf_h, x_offset, cw, ch, font.box_thickness))
            return .{ .format = .alpha };
    }

    const tt = font.tt orelse return .{ .format = .alpha };

    const glyph = tt.codepointGlyphIndex(codepoint);

    const metrics = constraintMetrics(font);

    if (glyph == .notdef and codepoint != 0) {
        if (self.fallbackResolver()) |fb| {
            if (fb.resolve({}, self.allocator, codepoint, font.size_px, false)) |fb_face| {
                const fg = fb_face.tt.codepointGlyphIndex(codepoint);
                const fscale: f32 = @as(f32, @floatFromInt(font.size_px)) /
                    @as(f32, @floatFromInt(@max(fb_face.units_per_em, 1)));
                return rasterizeGlyph(self.allocator, &fb_face.tt, fscale, font.ascent_px, fg, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
            }
        }
    }

    return rasterizeGlyph(self.allocator, &tt, font.scale, font.ascent_px, glyph, split, constraint, constraint_width, metrics, font.cell_size, staging_buf);
}

fn fallbackResolver(self: *const Self) ?*FallbackResolver {
    if (self.fallback) |fb| return fb;
    const fb = self.allocator.create(FallbackResolver) catch return null;
    fb.* = .{};
    @constCast(&self.fallback).* = fb;
    return fb;
}

fn rasterizeGlyph(
    allocator: std.mem.Allocator,
    tt: *const TrueType,
    scale: f32,
    ascent_px: i32,
    glyph: TrueType.GlyphIndex,
    split: GlyphSplit,
    constraint: glyph_constraint.Constraint,
    constraint_width: u2,
    metrics: glyph_constraint.Metrics,
    cell_size: XY(u16),
    staging_buf: []u8,
) RenderResult {
    const buf_w: i32 = @as(i32, @intCast(cell_size.x)) * 2;
    const buf_h: i32 = @intCast(cell_size.y);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (constraint.doesAnything()) {
        const box = tt.glyphBitmapBox(glyph, scale, scale);
        const rect_w: f64 = @floatFromInt(@as(i32, box.x1) - @as(i32, box.x0));
        const rect_h: f64 = @floatFromInt(@as(i32, box.y1) - @as(i32, box.y0));
        if (rect_w > 0 and rect_h > 0) {
            const rect_x: f64 = @floatFromInt(box.x0);
            const rect_y: f64 = @floatFromInt(-@as(i32, box.y1));
            const baseline_from_bottom: f64 = @as(f64, @floatFromInt(cell_size.y)) -
                @as(f64, @floatFromInt(ascent_px));
            const cg = constraint.constrain(.{
                .width = rect_w,
                .height = rect_h,
                .x = rect_x,
                .y = rect_y + baseline_from_bottom,
            }, metrics, constraint_width);

            const cell_w_f: f64 = @floatFromInt(metrics.cell_width);
            var gx: f64 = cg.x;
            if (constraint.size != .stretch and metrics.face_width < cell_w_f)
                gx += @round((cell_w_f - metrics.face_width) / 2.0);

            const sx: f32 = scale * @as(f32, @floatCast(cg.width / rect_w));
            const sy: f32 = scale * @as(f32, @floatCast(cg.height / rect_h));
            var big = std.ArrayList(u8).empty;
            const bdims = tt.glyphBitmap(alloc, &big, glyph, sx, sy) catch return .{ .format = .alpha };
            if (bdims.width == 0 or bdims.height == 0) return .{ .format = .alpha };

            const dst_x0: i32 = @intFromFloat(@round(gx));
            const dst_y0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(cell_size.y)) - (cg.y + cg.height)));
            blitAlphaAt(staging_buf, buf_w, buf_h, big.items, @intCast(bdims.width), @intCast(bdims.height), dst_x0, dst_y0);
        }
        return .{ .format = .alpha };
    }

    var pixels = std.ArrayList(u8).empty;
    const dims = tt.glyphBitmap(alloc, &pixels, glyph, scale, scale) catch return .{ .format = .alpha };

    if (dims.width == 0 or dims.height == 0) return .{ .format = .alpha };

    const glyph_extent: i32 = @as(i32, dims.off_x) + @as(i32, @intCast(dims.width));
    const center_offset: i32 = if (split != .single and glyph_extent < buf_w)
        @divTrunc(buf_w - glyph_extent, 2)
    else
        0;

    for (0..dims.height) |row| {
        const dst_y: i32 = ascent_px + @as(i32, dims.off_y) + @as(i32, @intCast(row));
        if (dst_y < 0 or dst_y >= buf_h) continue;

        for (0..dims.width) |col| {
            const dst_x: i32 = center_offset + @as(i32, dims.off_x) + @as(i32, @intCast(col));
            if (dst_x < 0 or dst_x >= buf_w) continue;

            const src_idx = row * dims.width + col;
            const dst_idx: usize = @as(usize, @intCast(dst_y * buf_w + dst_x)) * 4;

            if (src_idx < pixels.items.len and dst_idx < staging_buf.len) {
                staging_buf[dst_idx] = pixels.items[src_idx];
            }
        }
    }
    return .{ .format = .alpha };
}
