// sokol_gfx GPU backend for the wio-based renderer.
//
// Threading: all public functions must be called from the wio/GL thread
// (the thread that called sg.setup()).

const std = @import("std");
const builtin = @import("builtin");
const sg = @import("sokol").gfx;
const Rasterizer = @import("rasterizer");
const GlyphIndexCache = @import("GlyphIndexCache");
const XY = @import("xy").XY;
const shader = @import("shader");

pub const Font = Rasterizer.Font;
pub const RasterizerFont = Rasterizer.RasterizerFont;
pub const FontSet = Rasterizer.FontSet;
pub const Face = Rasterizer.Face;
pub const GlyphSplit = Rasterizer.GlyphSplit;
pub const Constraint = Rasterizer.Constraint;
pub const RasterFormat = Rasterizer.RasterFormat;
pub const RasterizerBackend = Rasterizer.Backend;
pub const Hinting = Rasterizer.Hinting;
pub const SymbolRasterizer = Rasterizer.SymbolRasterizer;
pub const Cell = @import("cell").Cell;
pub const flag_glyph_alpha_from_bg = @import("cell").flag_glyph_alpha_from_bg;
pub const RGBA = @import("color").RGBA;

pub const CursorShape = enum(i32) { block = 0, beam = 1, underline = 2, unfocused = 3 };

pub const CursorInfo = struct {
    vis: bool = false,
    row: u16 = 0,
    col: u16 = 0,
    width: u8 = 1,
    shape: CursorShape = .block,
    color: RGBA = .init(255, 255, 255, 255),
};

fn packCursor(c: CursorInfo, focused: bool) u32 {
    const shape_ = if (!focused) .unfocused else c.shape;
    const shape: u32 = @as(u32, @intCast(@intFromEnum(shape_))) + 1;
    return shape |
        (@as(u32, c.color.r) << 8) |
        (@as(u32, c.color.g) << 16) |
        (@as(u32, c.color.b) << 24);
}

fn markCursors(shader_cells: []ShaderCell, cursors: []const CursorInfo, cols: u16, rows: u16, focused: bool) void {
    for (cursors) |cur| {
        if (!cur.vis or cur.row >= rows or cur.col >= cols) continue;
        const packed_cursor = packCursor(cur, focused);
        const row_off = @as(usize, cur.row) * cols;
        const width = if (cur.shape == .beam) 1 else cur.width;
        var c: u16 = 0;
        while (c < width and cur.col + c < cols) : (c += 1)
            shader_cells[row_off + cur.col + c].cursor = packed_cursor;
    }
}

const log = std.log.scoped(.gpu);

// Fixed atlas width.  2048 is a universally supported texture dimension.
const atlas_width_px: u16 = 2048;

// Upper bound on the atlas height.
const atlas_max_height_px: u16 = 2048;

// Grow-to-fit: the atlas image keeps the full width but starts at a few
// cell-rows and doubles its height on demand (up to atlas_max_height_px).
const atlas_initial_rows: u16 = 4;

fn getAtlasCellCount(cell_size: XY(u16)) XY(u16) {
    return .{
        .x = @intCast(@divTrunc(atlas_width_px, cell_size.x)),
        .y = @intCast(@divTrunc(atlas_max_height_px, cell_size.y)),
    };
}

// Shader cell layout. Stored on the GPU as 5 RGBA8 texels per cell:
//   texel 0 = glyph_index bytes (LE),
//   texel 1 = bg color (r,g,b,a),
//   texel 2 = fg color,
//   texel 3 = deco bytes (LE),
//   texel 4 = cursor bytes (LE).
//
// Decoration field bit layout:
//   31..8 : underline color RRGGBB (24 bits, 0 → use fg)
//    7..5 : ul_style (3 bits, 0=off..5=dashed)
//    4    : strikethrough flag
//    3..2 : glyph_kind (00=alpha, 01=subpixel, 10=color, 11=reserved)
//    1    : reserved
//    0    : glyph_alpha_from_bg (cell α taken from bg.a in shader)
//
// Cursor field bit layout (0 → no cursor on this cell):
//    7..0 : shape+1 (1=block, 2=beam, 3=underline, 4=unfocused)
//   31..8 : cursor color RRGGBB
const ShaderCell = extern struct {
    glyph_index: u32,
    bg: u32,
    fg: u32,
    deco: u32 = 0,
    cursor: u32 = 0,
};

fn packDeco(src: Cell, kind: u2) u32 {
    const ulc = src.underline;
    // ulc.a == 0 signals "use foreground"; keep packed RGB at zero in that case.
    const color24: u32 = if (ulc.a == 0)
        0
    else
        (@as(u32, ulc.r) << 24) | (@as(u32, ulc.g) << 16) | (@as(u32, ulc.b) << 8);
    const style: u32 = (@as(u32, src.ul_style) & 7) << 5;
    const strike: u32 = if (src.strikethrough != 0) (@as(u32, 1) << 4) else 0;
    const kbits: u32 = (@as(u32, kind) & 3) << 2;
    const fg_t: u32 = if ((src.flags & flag_glyph_alpha_from_bg) != 0) 1 else 0;
    return color24 | style | strike | kbits | fg_t;
}

const global = struct {
    var init_called: bool = false;
    var rasterizer: Rasterizer = undefined;
    var pip: sg.Pipeline = .{};
    var composite_replace_pip: sg.Pipeline = .{};
    var composite_srcover_pip: sg.Pipeline = .{};
    var present_pip: sg.Pipeline = .{};
    var blit_uv_pip: sg.Pipeline = .{};
    var blur_pip: sg.Pipeline = .{};
    var blur_compose_pip: sg.Pipeline = .{};
    var shadow_pip: sg.Pipeline = .{};
    var glyph_sampler: sg.Sampler = .{};
    var cell_sampler: sg.Sampler = .{};
    var src_sampler: sg.Sampler = .{};
    var blur_sampler: sg.Sampler = .{};
    var glyph_cache_arena: std.heap.ArenaAllocator = undefined;
    var background: RGBA = .init(0, 255, 255, 255); // default is warning yellow
    var composite_sample_flip_y: f32 = 0.0;
    var transparent: bool = false;

    // Kawase blur ping-pong textures. Lazily allocated and grown to the
    // largest src footprint seen via ensureBlurTextures().
    var blur_image: [2]sg.Image = .{ .{}, .{} };
    var blur_view: [2]sg.View = .{ .{}, .{} };
    var blur_color_view: [2]sg.View = .{ .{}, .{} };
    var blur_size: XY(u16) = .{ .x = 0, .y = 0 };
};

pub fn init(allocator: std.mem.Allocator) !void {
    std.debug.assert(!global.init_called);
    global.init_called = true;

    global.rasterizer = try Rasterizer.init(allocator);
    global.glyph_cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // Build shader + pipelines
    const builtin_shd = sg.makeShader(shader.builtinShaderDesc(sg.queryBackend()));
    var pip_desc: sg.PipelineDesc = .{ .shader = builtin_shd };
    pip_desc.primitive_type = .TRIANGLE_STRIP;
    pip_desc.color_count = 1;
    global.pip = sg.makePipeline(pip_desc);

    const composite_shd = sg.makeShader(shader.compositeShaderDesc(sg.queryBackend()));

    var composite_replace_desc: sg.PipelineDesc = .{ .shader = composite_shd };
    composite_replace_desc.primitive_type = .TRIANGLE_STRIP;
    composite_replace_desc.color_count = 1;
    global.composite_replace_pip = sg.makePipeline(composite_replace_desc);

    var composite_srcover_desc: sg.PipelineDesc = .{ .shader = composite_shd };
    composite_srcover_desc.primitive_type = .TRIANGLE_STRIP;
    composite_srcover_desc.color_count = 1;
    composite_srcover_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    };
    global.composite_srcover_pip = sg.makePipeline(composite_srcover_desc);

    const present_shd = sg.makeShader(shader.presentShaderDesc(sg.queryBackend()));
    var present_desc: sg.PipelineDesc = .{ .shader = present_shd };
    present_desc.primitive_type = .TRIANGLE_STRIP;
    present_desc.color_count = 1;
    global.present_pip = sg.makePipeline(present_desc);

    // Blur pipeline trio (snapshot / Kawase tap / post-process+compose).
    // All three write with REPLACE; the compose shader does the src_over
    // math itself, so no fixed-function blending is needed.
    const blit_uv_shd = sg.makeShader(shader.blitUvShaderDesc(sg.queryBackend()));
    var blit_uv_desc: sg.PipelineDesc = .{ .shader = blit_uv_shd };
    blit_uv_desc.primitive_type = .TRIANGLE_STRIP;
    blit_uv_desc.color_count = 1;
    global.blit_uv_pip = sg.makePipeline(blit_uv_desc);

    const blur_shd = sg.makeShader(shader.blurShaderDesc(sg.queryBackend()));
    var blur_desc: sg.PipelineDesc = .{ .shader = blur_shd };
    blur_desc.primitive_type = .TRIANGLE_STRIP;
    blur_desc.color_count = 1;
    global.blur_pip = sg.makePipeline(blur_desc);

    const blur_compose_shd = sg.makeShader(shader.blurComposeShaderDesc(sg.queryBackend()));
    var blur_compose_desc: sg.PipelineDesc = .{ .shader = blur_compose_shd };
    blur_compose_desc.primitive_type = .TRIANGLE_STRIP;
    blur_compose_desc.color_count = 1;
    blur_compose_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .ONE,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    };
    global.blur_compose_pip = sg.makePipeline(blur_compose_desc);

    const shadow_shd = sg.makeShader(shader.shadowShaderDesc(sg.queryBackend()));
    var shadow_desc: sg.PipelineDesc = .{ .shader = shadow_shd };
    shadow_desc.primitive_type = .TRIANGLE_STRIP;
    shadow_desc.color_count = 1;
    shadow_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    };
    global.shadow_pip = sg.makePipeline(shadow_desc);

    global.composite_sample_flip_y = if (sg.queryFeatures().origin_top_left) 0.0 else 1.0;

    // Nearest-neighbour samplers (no filtering)
    global.glyph_sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .mipmap_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    global.cell_sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .mipmap_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    global.src_sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .mipmap_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    // Bilinear sampler for the Kawase 4-tap kernel; each tap then
    // averages a 2x2 source neighbourhood for free.
    global.blur_sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .mipmap_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
}

pub fn deinit() void {
    std.debug.assert(global.init_called);
    global.init_called = false;
    sg.destroyPipeline(global.pip);
    sg.destroyPipeline(global.composite_replace_pip);
    sg.destroyPipeline(global.composite_srcover_pip);
    sg.destroyPipeline(global.present_pip);
    sg.destroyPipeline(global.blit_uv_pip);
    sg.destroyPipeline(global.blur_pip);
    sg.destroyPipeline(global.blur_compose_pip);
    sg.destroyPipeline(global.shadow_pip);
    sg.destroySampler(global.glyph_sampler);
    sg.destroySampler(global.cell_sampler);
    sg.destroySampler(global.src_sampler);
    sg.destroySampler(global.blur_sampler);
    freeBlurTextures();
    global.glyph_cache_arena.deinit();
    global.rasterizer.deinit();
}

fn freeBlurTextures() void {
    for (0..2) |i| {
        if (global.blur_color_view[i].id != 0) sg.destroyView(global.blur_color_view[i]);
        if (global.blur_view[i].id != 0) sg.destroyView(global.blur_view[i]);
        if (global.blur_image[i].id != 0) sg.destroyImage(global.blur_image[i]);
        global.blur_color_view[i] = .{};
        global.blur_view[i] = .{};
        global.blur_image[i] = .{};
    }
    global.blur_size = .{ .x = 0, .y = 0 };
}

fn ensureBlurTextures(needed: XY(u16)) void {
    if (needed.eql(global.blur_size) and global.blur_image[0].id != 0) return;
    freeBlurTextures();

    for (0..2) |i| {
        global.blur_image[i] = sg.makeImage(.{
            .width = needed.x,
            .height = needed.y,
            .pixel_format = .RGBA8,
            .usage = .{ .color_attachment = true },
        });
        global.blur_view[i] = sg.makeView(.{
            .texture = .{ .image = global.blur_image[i] },
        });
        global.blur_color_view[i] = sg.makeView(.{
            .color_attachment = .{ .image = global.blur_image[i] },
        });
    }
    global.blur_size = needed;
}

pub fn loadFont(name: []const u8, size_px: u16) !Font {
    return global.rasterizer.loadFont(name, size_px);
}

pub fn loadFontSet(opts: Rasterizer.LoadOpts) !FontSet {
    return global.rasterizer.loadFontSet(opts);
}

pub fn setRasterizerBackend(backend: RasterizerBackend) void {
    global.rasterizer.setBackend(backend);
}

pub fn setHinting(h: Hinting) void {
    global.rasterizer.setHinting(h);
}

pub fn setSymbolRasterizer(h: SymbolRasterizer) void {
    global.rasterizer.setSymbolRasterizer(h);
}

pub fn setAllowColorGlyphs(allow: bool) void {
    global.rasterizer.setAllowColorGlyphs(allow);
}

pub fn glyphAdvance(font: Font, codepoint: u21) ?u16 {
    return global.rasterizer.glyphAdvance(font, codepoint);
}

pub fn invalidateGlyphCache(state: *WindowState) void {
    state.glyph_cache_cell_size = null;
}

pub fn setBackground(color: RGBA) void {
    global.background = color;
}

pub fn getBackground() RGBA {
    return global.background;
}

pub fn setTransparent(on: bool) void {
    global.transparent = on;
}

pub fn isTransparent() bool {
    return global.transparent;
}

// ── WindowState ────────────────────────────────────────────────────────────

pub const WindowState = struct {
    // GL window size in pixels
    size: XY(u32) = .{ .x = 0, .y = 0 },

    // Glyph atlas (R8 2D texture + view)
    glyph_image: sg.Image = .{},
    glyph_view: sg.View = .{},
    glyph_image_size: XY(u16) = .{ .x = 0, .y = 0 },

    // Cell grid (RGBA8 2D texture, 4 texels per cell), updated each frame
    cell_image: sg.Image = .{},
    cell_view: sg.View = .{},
    cell_image_size: XY(u16) = .{ .x = 0, .y = 0 },
    cell_buf: std.ArrayList(ShaderCell) = .empty,

    // Glyph index cache
    glyph_cache_cell_size: ?XY(u16) = null,
    glyph_index_cache: ?GlyphIndexCache = null,

    // Atlas geometry derived from the cell size
    glyph_atlas_cell_count: XY(u16) = .{ .x = 0, .y = 0 },
    glyph_atlas_total: u32 = 0,
    glyph_atlas_pixel_size: XY(u16) = .{ .x = 0, .y = 0 },

    // Set when the CPU atlas shadow was updated; cleared after GPU upload.
    glyph_atlas_dirty: bool = false,

    pub fn init() WindowState {
        std.debug.assert(global.init_called);
        return .{};
    }

    pub fn deinit(state: *WindowState) void {
        if (state.glyph_view.id != 0) sg.destroyView(state.glyph_view);
        if (state.glyph_image.id != 0) sg.destroyImage(state.glyph_image);
        if (state.cell_view.id != 0) sg.destroyView(state.cell_view);
        if (state.cell_image.id != 0) sg.destroyImage(state.cell_image);
        state.cell_buf.deinit(global.glyph_cache_arena.allocator());
        if (state.glyph_index_cache) |*c| {
            c.deinit(global.glyph_cache_arena.allocator());
        }
        state.* = undefined;
    }

    // Ensure the glyph atlas image is (at least) the requested pixel size.
    // Returns true if the image was retained, false if (re)created.
    fn updateGlyphImage(state: *WindowState, pixel_size: XY(u16)) bool {
        if (state.glyph_image_size.eql(pixel_size)) return true;

        if (state.glyph_view.id != 0) sg.destroyView(state.glyph_view);
        if (state.glyph_image.id != 0) sg.destroyImage(state.glyph_image);

        state.glyph_image = sg.makeImage(.{
            .width = pixel_size.x,
            .height = pixel_size.y,
            .pixel_format = .RGBA8,
            .usage = .{ .dynamic_update = true },
        });
        state.glyph_view = sg.makeView(.{
            .texture = .{ .image = state.glyph_image },
        });
        state.glyph_image_size = pixel_size;
        const bytes: usize = @as(usize, pixel_size.x) * @as(usize, pixel_size.y) * 4;
        std.log.debug("glyph atlas resized to {d}x{d} RGBA8 = {d} bytes ({d} KiB)", .{
            pixel_size.x, pixel_size.y, bytes, bytes / 1024,
        });
        return false;
    }

    // Grow the atlas image so it covers at least `rows_needed` cell-rows.
    fn ensureAtlasHeight(state: *WindowState, cell_size: XY(u16), cell_count: XY(u16), rows_needed: u16) void {
        const cur_rows: u16 = if (cell_size.y == 0) 0 else @intCast(@divTrunc(state.glyph_image_size.y, cell_size.y));
        if (cur_rows >= rows_needed) return;
        const want: u32 = @max(@as(u32, rows_needed), @as(u32, cur_rows) * 2);
        const new_rows: u16 = @intCast(@min(@as(u32, cell_count.y), want));
        state.glyph_atlas_pixel_size = .{ .x = cell_count.x * cell_size.x, .y = new_rows * cell_size.y };
        _ = state.updateGlyphImage(state.glyph_atlas_pixel_size);
        state.glyph_atlas_dirty = true;
    }

    // Ensure the cell texture is the requested size.
    fn updateCellImage(state: *WindowState, allocator: std.mem.Allocator, cols: u16, rows: u16) void {
        const needed: u32 = @as(u32, cols) * @as(u32, rows);
        const sz: XY(u16) = .{ .x = cols, .y = rows };

        if (!state.cell_image_size.eql(sz)) {
            if (state.cell_view.id != 0) sg.destroyView(state.cell_view);
            if (state.cell_image.id != 0) sg.destroyImage(state.cell_image);

            state.cell_image = sg.makeImage(.{
                .width = cols * 5,
                .height = rows,
                .pixel_format = .RGBA8,
                .usage = .{ .dynamic_update = true },
            });
            state.cell_view = sg.makeView(.{
                .texture = .{ .image = state.cell_image },
            });
            state.cell_image_size = sz;
        }

        if (state.cell_buf.items.len < needed) {
            state.cell_buf.resize(allocator, needed) catch |e| oom(e);
        }
    }

    pub fn generateGlyph(
        state: *WindowState,
        font: Font,
        face: Face,
        codepoint: u21,
        emoji_presentation: bool,
        constraint: Rasterizer.Constraint,
        constraint_width: u2,
        split: Rasterizer.GlyphSplit,
    ) u32 {
        const cache_valid = if (state.glyph_cache_cell_size) |s| s.eql(font.cell_size) else false;
        if (!cache_valid) {
            const cnt = getAtlasCellCount(font.cell_size);
            state.glyph_atlas_cell_count = cnt;
            state.glyph_atlas_total = @as(u32, cnt.x) * @as(u32, cnt.y);
            const init_rows: u16 = @min(cnt.y, atlas_initial_rows);
            state.glyph_atlas_pixel_size = .{
                .x = cnt.x * font.cell_size.x,
                .y = init_rows * font.cell_size.y,
            };

            if (state.glyph_index_cache) |*c| {
                c.deinit(global.glyph_cache_arena.allocator());
                _ = global.glyph_cache_arena.reset(.retain_capacity);
                state.glyph_index_cache = null;
                // cell_buf was allocated from the arena; clear it so the next
                // resize doesn't memcpy from the now-freed memory.
                state.cell_buf = .empty;
            }
            _ = state.updateGlyphImage(state.glyph_atlas_pixel_size);
            state.glyph_atlas_dirty = true;
        }
        state.glyph_cache_cell_size = font.cell_size;

        const atlas_cell_count = state.glyph_atlas_cell_count;
        const atlas_total = state.glyph_atlas_total;

        const cache = blk: {
            if (state.glyph_index_cache) |*c| break :blk c;
            state.glyph_index_cache = GlyphIndexCache.init(
                global.glyph_cache_arena.allocator(),
                atlas_total,
            ) catch |e| oom(e);
            break :blk &(state.glyph_index_cache.?);
        };

        const right_half: bool = split == .right;
        const wide: bool = split != .single;

        switch (cache.reserve(
            global.glyph_cache_arena.allocator(),
            codepoint,
            right_half,
            wide,
            emoji_presentation,
            @intFromEnum(face),
        ) catch |e| oom(e)) {
            .newly_reserved => |reserved| {
                // Rasterize into the reusable RGBA staging buffer, then upload
                // to the atlas.
                const staging_w: u32 = @as(u32, font.cell_size.x) * 2;
                const staging_buf = ensureGlyphStaging(font.cell_size);
                @memset(staging_buf, 0);

                const rr = global.rasterizer.render(font, codepoint, emoji_presentation, constraint, constraint_width, split, staging_buf);
                cache.nodes[reserved.index].kind = @intFromEnum(rr.format);

                // (rough) atlas utilization probe.
                const used = cache.map.count();
                if ((used & (used - 1)) == 0) {
                    const cell_px: usize = @as(usize, font.cell_size.x) * @as(usize, font.cell_size.y);
                    const used_kib = (@as(usize, used) * cell_px * 4) / 1024;
                    const total_kib = (@as(usize, state.glyph_atlas_pixel_size.x) * @as(usize, state.glyph_atlas_pixel_size.y) * 4) / 1024;
                    std.log.debug("glyph atlas used: {d} glyphs ~= {d} KiB of {d} KiB allocated", .{ used, used_kib, total_kib });
                }

                // Atlas cell position for this glyph index
                const atlas_col: u16 = @intCast(reserved.index % atlas_cell_count.x);
                const atlas_row: u16 = @intCast(reserved.index / atlas_cell_count.x);

                // Grow the atlas height if this glyph lands beyond the rows allocated so far
                state.ensureAtlasHeight(font.cell_size, atlas_cell_count, atlas_row + 1);

                const atlas_x: u16 = atlas_col * font.cell_size.x;
                const atlas_y: u16 = atlas_row * font.cell_size.y;

                // Source region in the staging buffer
                const src_x: u16 = if (right_half) font.cell_size.x else 0;
                const glyph_w: u16 = font.cell_size.x;
                const glyph_h: u16 = font.cell_size.y;

                // Write into the CPU-side atlas shadow
                const staging_row_bytes: usize = @as(usize, staging_w) * 4;
                const src_x_off: usize = @as(usize, src_x) * 4;
                blitAtlasCpu(state, atlas_x, atlas_y, glyph_w, glyph_h, staging_buf, staging_row_bytes, src_x_off);
                state.glyph_atlas_dirty = true;

                return reserved.index;
            },
            .already_reserved => |index| return index,
        }
    }
};

pub const LayerGpuState = struct {
    // cell texture
    cell_image: sg.Image = .{},
    cell_view: sg.View = .{},
    cell_image_size: XY(u16) = .{ .x = 0, .y = 0 },
    cell_buf: std.ArrayList(ShaderCell) = .empty,

    // offscreen pixel render target
    pixel_image: sg.Image = .{},
    pixel_view: sg.View = .{},
    pixel_color_attachment_view: sg.View = .{},
    pixel_size: XY(u16) = .{ .x = 0, .y = 0 },

    // GC bookkeeping
    last_seen_frame: u64 = 0,

    pub fn deinit(self: *LayerGpuState, allocator: std.mem.Allocator) void {
        if (self.pixel_color_attachment_view.id != 0) sg.destroyView(self.pixel_color_attachment_view);
        if (self.pixel_view.id != 0) sg.destroyView(self.pixel_view);
        if (self.pixel_image.id != 0) sg.destroyImage(self.pixel_image);
        if (self.cell_view.id != 0) sg.destroyView(self.cell_view);
        if (self.cell_image.id != 0) sg.destroyImage(self.cell_image);
        self.cell_buf.deinit(allocator);
        self.* = .{};
    }

    fn updateCellImage(self: *LayerGpuState, allocator: std.mem.Allocator, cols: u16, rows: u16) void {
        const needed: u32 = @as(u32, cols) * @as(u32, rows);
        const sz: XY(u16) = .{ .x = cols, .y = rows };

        if (!self.cell_image_size.eql(sz)) {
            if (self.cell_view.id != 0) sg.destroyView(self.cell_view);
            if (self.cell_image.id != 0) sg.destroyImage(self.cell_image);

            self.cell_image = sg.makeImage(.{
                .width = @as(i32, cols) * 5,
                .height = rows,
                .pixel_format = .RGBA8,
                .usage = .{ .dynamic_update = true },
            });
            self.cell_view = sg.makeView(.{
                .texture = .{ .image = self.cell_image },
            });
            self.cell_image_size = sz;
        }

        if (self.cell_buf.items.len < needed) {
            self.cell_buf.resize(allocator, needed) catch |e| oom(e);
        }
    }

    fn updatePixelImage(self: *LayerGpuState, pixel_w: u16, pixel_h: u16) void {
        const sz: XY(u16) = .{ .x = pixel_w, .y = pixel_h };
        if (self.pixel_size.eql(sz) and self.pixel_image.id != 0) return;

        if (self.pixel_color_attachment_view.id != 0) sg.destroyView(self.pixel_color_attachment_view);
        if (self.pixel_view.id != 0) sg.destroyView(self.pixel_view);
        if (self.pixel_image.id != 0) sg.destroyImage(self.pixel_image);

        self.pixel_image = sg.makeImage(.{
            .width = pixel_w,
            .height = pixel_h,
            .pixel_format = .RGBA8,
            .usage = .{ .color_attachment = true },
        });
        self.pixel_view = sg.makeView(.{
            .texture = .{ .image = self.pixel_image },
        });
        self.pixel_color_attachment_view = sg.makeView(.{
            .color_attachment = .{ .image = self.pixel_image },
        });
        self.pixel_size = sz;
    }

    fn attachments(self: *const LayerGpuState) sg.Attachments {
        var att: sg.Attachments = .{};
        att.colors[0] = self.pixel_color_attachment_view;
        return att;
    }
};

pub fn paintLayerOffscreen(
    window_state: *WindowState,
    layer_state: *LayerGpuState,
    allocator: std.mem.Allocator, // for layer_state.cell_buf
    font_set: FontSet,
    cells: []const Cell,
    cols: u16,
    rows: u16,
    pixel_size: XY(u16),
    cursors: []const CursorInfo,
    bg_alpha: u8,
    focused: bool,
) void {
    if (cols == 0 or rows == 0) return;
    if (pixel_size.x == 0 or pixel_size.y == 0) return;

    const pixel_w: u16 = pixel_size.x;
    const pixel_h: u16 = pixel_size.y;

    layer_state.updateCellImage(allocator, cols, rows);
    layer_state.updatePixelImage(pixel_w, pixel_h);

    const total: u32 = @as(u32, cols) * @as(u32, rows);
    const shader_cells = layer_state.cell_buf.items[0..total];
    const cache_nodes: ?[]GlyphIndexCache.Node = if (window_state.glyph_index_cache) |*c| c.nodes else null;

    for (cells[0..total], shader_cells) |src, *dst| {
        const kind: u2 = if (cache_nodes) |nodes|
            (if (src.glyph_index < nodes.len) nodes[src.glyph_index].kind else 0)
        else
            0;
        dst.* = .{
            .glyph_index = src.glyph_index,
            .bg = src.background.to_u32(),
            .fg = src.foreground.to_u32(),
            .deco = packDeco(src, kind),
        };
    }

    markCursors(shader_cells, cursors, cols, rows, focused);

    if (window_state.glyph_atlas_dirty) flushGlyphAtlas(window_state);

    var cell_data: sg.ImageData = .{};
    const cell_bytes = std.mem.sliceAsBytes(shader_cells);
    cell_data.mip_levels[0] = .{ .ptr = cell_bytes.ptr, .size = cell_bytes.len };
    sg.updateImage(layer_state.cell_image, cell_data);

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };

    sg.beginPass(.{
        .attachments = layer_state.attachments(),
        .action = pass_action,
    });
    sg.applyPipeline(global.pip);

    var bindings: sg.Bindings = .{};
    bindings.views[0] = window_state.glyph_view;
    bindings.views[1] = layer_state.cell_view;
    bindings.samplers[0] = global.glyph_sampler;
    bindings.samplers[1] = global.cell_sampler;
    sg.applyBindings(bindings);

    const fs_params = shader.FsParams{
        .cell_size = .{
            font_set.cell_size.x,
            font_set.cell_size.y,
            cols,
            rows,
        },
        .viewport = .{ pixel_h, pixel_w, 0, 0 },
        .underline_info = .{
            font_set.underline_position,
            font_set.underline_thickness,
            0,
            0,
        },
        .bg_color = blk: {
            var v = global.background.to_vec4();
            v[3] = @as(f32, @floatFromInt(bg_alpha)) / 255.0;
            break :blk v;
        },
    };
    sg.applyUniforms(shader.UB_fs_params, .{
        .ptr = &fs_params,
        .size = @sizeOf(shader.FsParams),
    });

    sg.draw(0, 4, 1);
    sg.endPass();
}

pub const CompositeOp = struct {
    /// pixel-space top-left of the source quad inside the destination
    /// attachment. (Caller-resolved from `Target.dst_{x,y}_off + Target.{x,y}`
    /// times cell_size, plus sub-cell `xoffset/yoffset`.)
    dst_x: i32,
    dst_y: i32,
    /// pixel-space size of the source quad. Usually `src_layer.pixel_size`
    dst_w: u16,
    dst_h: u16,
    blend: BlendMode,
    /// global alpha multiplier
    alpha: u8,
    /// corner rounding radius in px (0 = square)
    radius: f32 = 0,
    //// per-corner rounding enable mask (tl, tr, br, bl)
    corners: [4]f32 = .{ 1, 1, 1, 1 },
    /// scissor rect in dst-attachment pixels
    clip: ?Rect = null,

    pub const BlendMode = enum { replace, src_over, src_over_blur };
    pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
};

/// Composite one layer's offscreen pixel buffer into another's, using the
/// `composite_{replace,srcover}_pip` pipeline and a sub-rect viewport.
/// `.src_over_blur` runs a separate snapshot -> Kawase -> compose sequence.
pub fn compositeLayer(
    dst_layer_state: *const LayerGpuState,
    src_layer_state: *const LayerGpuState,
    op: CompositeOp,
) void {
    if (dst_layer_state.pixel_image.id == 0 or src_layer_state.pixel_image.id == 0) return;
    if (op.dst_w == 0 or op.dst_h == 0) return;

    if (op.blend == .src_over_blur) {
        compositeLayerBlur(dst_layer_state, src_layer_state, op);
        return;
    }

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{ .load_action = .LOAD };

    sg.beginPass(.{
        .attachments = dst_layer_state.attachments(),
        .action = pass_action,
    });

    sg.applyViewport(op.dst_x, op.dst_y, op.dst_w, op.dst_h, true);
    if (op.clip) |c| sg.applyScissorRect(c.x, c.y, c.w, c.h, true);

    const pipeline = switch (op.blend) {
        .replace => global.composite_replace_pip,
        .src_over => global.composite_srcover_pip,
        .src_over_blur => unreachable, // handled above
    };
    sg.applyPipeline(pipeline);

    var bindings: sg.Bindings = .{};
    bindings.views[shader.VIEW_src_tex] = src_layer_state.pixel_view;
    bindings.samplers[shader.SMP_src_smp] = global.src_sampler;
    sg.applyBindings(bindings);

    const fs_params = shader.FsCompositeParams{
        .composite_alpha = .{ @as(f32, @floatFromInt(op.alpha)) / 255.0, 0, 0, 0 },
        .sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
        .round_geom = .{ @floatFromInt(op.dst_w), @floatFromInt(op.dst_h), op.radius, 0 },
        .round_mask = op.corners,
    };
    sg.applyUniforms(shader.UB_fs_composite_params, .{
        .ptr = &fs_params,
        .size = @sizeOf(shader.FsCompositeParams),
    });

    sg.draw(0, 4, 1);
    sg.endPass();
}

pub const ShadowOp = struct {
    /// Intended shadow quad in dst-attachment pixels (top-origin). This is the
    /// child footprint expanded by `range` on every side, plus the offset; it
    /// may extend outside the attachment and is clamped here.
    quad_x: i32,
    quad_y: i32,
    quad_w: u16,
    quad_h: u16,
    /// Child footprint (cutout) in quad-local pixels.
    cut_x: f32,
    cut_y: f32,
    cut_w: f32,
    cut_h: f32,
    range: f32,
    power: f32,
    radius: f32,
    color: [3]f32, // straight rgb in 0..1
    alpha: f32, // peak opacity in 0..1
    edge_mask: [4]f32, // top, right, bottom, left
    corner_mask: [4]f32, // tl, tr, br, bl
    bleed_mask: [4]f32 = .{ 0, 0, 0, 0 }, // disabled edges a band may extend across
};

/// Draw an analytic drop shadow onto `dst_layer_state`, around and under a
/// child layer's footprint. Uses `shadow_pip`; the quad is clamped to the
/// attachment and the clamp is folded into `uv_rect` so the shader still
/// reasons in full-quad coordinates.
pub fn drawLayerShadow(dst_layer_state: *const LayerGpuState, op: ShadowOp) void {
    if (dst_layer_state.pixel_image.id == 0) return;
    if (op.quad_w == 0 or op.quad_h == 0 or op.alpha <= 0.0) return;

    const att_w: i32 = dst_layer_state.pixel_size.x;
    const att_h: i32 = dst_layer_state.pixel_size.y;
    const quad_w: f32 = @floatFromInt(op.quad_w);
    const quad_h: f32 = @floatFromInt(op.quad_h);

    // clamp viewport to the attachment, tracking the visible sub-rect in
    // full-quad uv space.
    var vx = op.quad_x;
    var vy = op.quad_y;
    var vw: i32 = op.quad_w;
    var vh: i32 = op.quad_h;
    if (vx < 0) {
        vw += vx;
        vx = 0;
    }
    if (vy < 0) {
        vh += vy;
        vy = 0;
    }
    if (vx + vw > att_w) vw = att_w - vx;
    if (vy + vh > att_h) vh = att_h - vy;
    if (vw <= 0 or vh <= 0) return;

    const uoff: f32 = @as(f32, @floatFromInt(vx - op.quad_x)) / quad_w;
    const voff: f32 = @as(f32, @floatFromInt(vy - op.quad_y)) / quad_h;
    const du: f32 = @as(f32, @floatFromInt(vw)) / quad_w;
    const dv: f32 = @as(f32, @floatFromInt(vh)) / quad_h;

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{ .load_action = .LOAD };

    sg.beginPass(.{
        .attachments = dst_layer_state.attachments(),
        .action = pass_action,
    });

    sg.applyViewport(vx, vy, vw, vh, true);
    sg.applyPipeline(global.shadow_pip);
    sg.applyBindings(.{});

    const fs_params = shader.FsShadowParams{
        .color = .{ op.color[0], op.color[1], op.color[2], op.alpha },
        .full_size = .{ quad_w, quad_h, 0, 0 },
        .cut = .{ op.cut_x, op.cut_y, op.cut_x + op.cut_w, op.cut_y + op.cut_h },
        .geom = .{ op.range, op.power, op.radius, 0 },
        .edge_mask = op.edge_mask,
        .corner_mask = op.corner_mask,
        .bleed_mask = op.bleed_mask,
        .uv_rect = .{ uoff, voff, du, dv },
    };
    sg.applyUniforms(shader.UB_fs_shadow_params, .{
        .ptr = &fs_params,
        .size = @sizeOf(shader.FsShadowParams),
    });

    sg.draw(0, 4, 1);
    sg.endPass();
}

const BlurParams = struct {
    size: f32 = 1.0,
    passes: u32 = 3,
    noise: f32 = 0.0117,
    contrast: f32 = 0.8916,
    brightness: f32 = 0.8172,
    vibrancy: f32 = 0.1696,
    vibrancy_darkness: f32 = 0.0,
};

const default_blur_params: BlurParams = .{};

/// snapshot dst sub-rect -> N Kawase passes ping-pong -> post-process +
/// src_over compose back into dst sub-rect.
fn compositeLayerBlur(
    dst_layer_state: *const LayerGpuState,
    src_layer_state: *const LayerGpuState,
    op: CompositeOp,
) void {
    const params = default_blur_params;
    const w = op.dst_w;
    const h = op.dst_h;

    ensureBlurTextures(.{ .x = w, .y = h });

    // snapshot dst sub-rect -> blur_image[0]
    {
        const dst_w_full: f32 = @floatFromInt(dst_layer_state.pixel_size.x);
        const dst_h_full: f32 = @floatFromInt(dst_layer_state.pixel_size.y);
        // dst sub-rect in normalised dst UV space (top-origin, before any
        // GL Y-flip — the shader applies that itself).
        const src_uv: [4]f32 = .{
            @as(f32, @floatFromInt(op.dst_x)) / dst_w_full,
            @as(f32, @floatFromInt(op.dst_y)) / dst_h_full,
            @as(f32, @floatFromInt(w)) / dst_w_full,
            @as(f32, @floatFromInt(h)) / dst_h_full,
        };

        var pass_action: sg.PassAction = .{};
        pass_action.colors[0] = .{ .load_action = .DONTCARE };
        var atts: sg.Attachments = .{};
        atts.colors[0] = global.blur_color_view[0];

        sg.beginPass(.{ .attachments = atts, .action = pass_action });
        sg.applyViewport(0, 0, w, h, true);
        sg.applyPipeline(global.blit_uv_pip);
        var bindings: sg.Bindings = .{};
        bindings.views[shader.VIEW_blit_tex] = dst_layer_state.pixel_view;
        bindings.samplers[shader.SMP_blit_smp] = global.blur_sampler;
        sg.applyBindings(bindings);
        const blit_params = shader.FsBlitUvParams{
            .src_uv = src_uv,
            .blit_sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
        };
        sg.applyUniforms(shader.UB_fs_blit_uv_params, .{
            .ptr = &blit_params,
            .size = @sizeOf(shader.FsBlitUvParams),
        });
        sg.draw(0, 4, 1);
        sg.endPass();
    }

    // N Kawase passes ping-ponging blur_image[0] <-> blur_image[1]
    var src_idx: usize = 0;
    {
        // Blur textures are sized exactly to (w, h), so UV offsets map
        // 1 pixel -> 1/w (or 1/h) directly.
        const tex_w: f32 = @floatFromInt(w);
        const tex_h: f32 = @floatFromInt(h);
        var pass_idx: u32 = 0;
        while (pass_idx < params.passes) : (pass_idx += 1) {
            const dst_idx: usize = 1 - src_idx;
            // Classic Kawase: kernel grows per pass.
            const off_px: f32 = params.size * @as(f32, @floatFromInt(pass_idx + 1)) + 0.5;
            const off_u: f32 = off_px / tex_w;
            const off_v: f32 = off_px / tex_h;

            var pass_action: sg.PassAction = .{};
            pass_action.colors[0] = .{ .load_action = .DONTCARE };
            var atts: sg.Attachments = .{};
            atts.colors[0] = global.blur_color_view[dst_idx];

            sg.beginPass(.{ .attachments = atts, .action = pass_action });
            sg.applyViewport(0, 0, w, h, true);
            sg.applyPipeline(global.blur_pip);
            var bindings: sg.Bindings = .{};
            bindings.views[shader.VIEW_blur_src_tex] = global.blur_view[src_idx];
            bindings.samplers[shader.SMP_blur_src_smp] = global.blur_sampler;
            sg.applyBindings(bindings);
            const blur_params = shader.FsBlurParams{
                .blur_step = .{ off_u, off_v, 0, 0 },
                .blur_sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
            };
            sg.applyUniforms(shader.UB_fs_blur_params, .{
                .ptr = &blur_params,
                .size = @sizeOf(shader.FsBlurParams),
            });
            sg.draw(0, 4, 1);
            sg.endPass();

            src_idx = dst_idx;
        }
    }

    // post-process backdrop + src_over src -> dst sub-rect (replace)
    {
        var pass_action: sg.PassAction = .{};
        pass_action.colors[0] = .{ .load_action = .LOAD };

        sg.beginPass(.{
            .attachments = dst_layer_state.attachments(),
            .action = pass_action,
        });
        sg.applyViewport(op.dst_x, op.dst_y, op.dst_w, op.dst_h, true);
        sg.applyPipeline(global.blur_compose_pip);

        var bindings: sg.Bindings = .{};
        bindings.views[shader.VIEW_backdrop_tex] = global.blur_view[src_idx];
        bindings.views[shader.VIEW_bc_src_tex] = src_layer_state.pixel_view;
        bindings.samplers[shader.SMP_backdrop_smp] = global.blur_sampler;
        bindings.samplers[shader.SMP_bc_src_smp] = global.blur_sampler;
        sg.applyBindings(bindings);

        const compose_params = shader.FsBlurComposeParams{
            .post0 = .{ params.noise, params.contrast, params.brightness, params.vibrancy },
            .post1 = .{ params.vibrancy_darkness, @as(f32, @floatFromInt(op.alpha)) / 255.0, 0, 0 },
            .bc_sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
            .round_geom = .{ @floatFromInt(op.dst_w), @floatFromInt(op.dst_h), op.radius, 0 },
            .round_mask = op.corners,
        };
        sg.applyUniforms(shader.UB_fs_blur_compose_params, .{
            .ptr = &compose_params,
            .size = @sizeOf(shader.FsBlurComposeParams),
        });

        sg.draw(0, 4, 1);
        sg.endPass();
    }
}

/// Blit a layer's offscreen pixel buffer to the swapchain
pub fn presentLayerToSwapchain(
    src_layer_state: *const LayerGpuState,
    client_size: XY(u32),
    swapchain_render_view: ?*const anyopaque, // windows only
) void {
    if (src_layer_state.pixel_image.id == 0) return;

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = @as(f32, @floatFromInt(global.background.r)) / 255.0,
            .g = @as(f32, @floatFromInt(global.background.g)) / 255.0,
            .b = @as(f32, @floatFromInt(global.background.b)) / 255.0,
            .a = if (global.transparent) 0.0 else 1.0,
        },
    };

    sg.beginPass(.{
        .swapchain = if (builtin.os.tag == .windows) .{
            .width = @intCast(client_size.x),
            .height = @intCast(client_size.y),
            .sample_count = 1,
            .color_format = .RGBA8,
            .depth_format = .NONE,
            .d3d11 = .{ .render_view = swapchain_render_view },
        } else .{
            .width = @intCast(client_size.x),
            .height = @intCast(client_size.y),
            .sample_count = 1,
            .color_format = .RGBA8,
            .depth_format = .NONE,
            .gl = .{ .framebuffer = 0 },
        },
        .action = pass_action,
    });

    if (global.transparent) {
        // straight-alpha
        sg.applyPipeline(global.present_pip);

        var bindings: sg.Bindings = .{};
        bindings.views[shader.VIEW_present_tex] = src_layer_state.pixel_view;
        bindings.samplers[shader.SMP_present_smp] = global.src_sampler;
        sg.applyBindings(bindings);

        const present_params = shader.FsPresentParams{
            .present_sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
        };
        sg.applyUniforms(shader.UB_fs_present_params, .{
            .ptr = &present_params,
            .size = @sizeOf(shader.FsPresentParams),
        });
    } else {
        // premultiplied alpha
        sg.applyPipeline(global.composite_replace_pip);

        var bindings: sg.Bindings = .{};
        bindings.views[shader.VIEW_src_tex] = src_layer_state.pixel_view;
        bindings.samplers[shader.SMP_src_smp] = global.src_sampler;
        sg.applyBindings(bindings);

        const fs_params = shader.FsCompositeParams{
            .composite_alpha = .{ 1.0, 0, 0, 0 },
            .sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
            .round_geom = .{ 0, 0, 0, 0 }, // no rounding for the final present
            .round_mask = .{ 1, 1, 1, 1 },
        };
        sg.applyUniforms(shader.UB_fs_composite_params, .{
            .ptr = &fs_params,
            .size = @sizeOf(shader.FsCompositeParams),
        });
    }

    sg.draw(0, 4, 1);
    sg.endPass();
}

// CPU-side shadow copy of the glyph atlas (RGBA8, row-major).
// Kept alive for the process lifetime; resized when the atlas image grows.
var atlas_cpu: ?[]u8 = null;
var atlas_cpu_size: XY(u16) = .{ .x = 0, .y = 0 };

// Reusable RGBA staging buffer for rasterizing a single glyph.
var glyph_staging: ?[]u8 = null;
var glyph_staging_cell: XY(u16) = .{ .x = 0, .y = 0 };

fn ensureGlyphStaging(cell_size: XY(u16)) []u8 {
    if (glyph_staging == null or !glyph_staging_cell.eql(cell_size)) {
        if (glyph_staging) |old| std.heap.page_allocator.free(old);
        const bytes: usize = @as(usize, cell_size.x) * 2 * @as(usize, cell_size.y) * 4;
        glyph_staging = std.heap.page_allocator.alloc(u8, bytes) catch |e| oom(e);
        glyph_staging_cell = cell_size;
    }
    return glyph_staging.?;
}

// Blit one glyph cell into the CPU-side atlas shadow.
fn blitAtlasCpu(
    state: *const WindowState,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    src: []const u8,
    src_row_bytes: usize,
    src_x_off: usize,
) void {
    const asz = state.glyph_image_size;
    const total_bytes: usize = @as(usize, asz.x) * @as(usize, asz.y) * 4;

    if (!atlas_cpu_size.eql(asz)) {
        const new_buf = std.heap.page_allocator.alloc(u8, total_bytes) catch |e| oom(e);
        @memset(new_buf, 0);
        if (atlas_cpu) |old| {
            if (atlas_cpu_size.x == asz.x and asz.y >= atlas_cpu_size.y)
                @memcpy(new_buf[0..old.len], old[0..old.len]);
            std.heap.page_allocator.free(old);
        }
        atlas_cpu = new_buf;
        atlas_cpu_size = asz;
    }

    const buf = atlas_cpu.?;
    const row_bytes: usize = @as(usize, w) * 4;
    const atlas_row_bytes: usize = @as(usize, asz.x) * 4;
    for (0..h) |row_i| {
        const src_off = row_i * src_row_bytes + src_x_off;
        const dst_off = (@as(usize, y) + row_i) * atlas_row_bytes + @as(usize, x) * 4;
        @memcpy(buf[dst_off .. dst_off + row_bytes], src[src_off .. src_off + row_bytes]);
    }
}

// Upload the CPU shadow to the GPU.  Called once per frame if dirty.
// Must be called outside a sokol render pass.
fn flushGlyphAtlas(state: *WindowState) void {
    const asz = state.glyph_image_size;
    const total_bytes: usize = @as(usize, asz.x) * @as(usize, asz.y) * 4;
    const buf = atlas_cpu orelse return;

    var img_data: sg.ImageData = .{};
    img_data.mip_levels[0] = .{ .ptr = buf.ptr, .size = total_bytes };
    sg.updateImage(state.glyph_image, img_data);
    state.glyph_atlas_dirty = false;
}

pub fn paint(
    state: *WindowState,
    client_size: XY(u32),
    font_set: FontSet,
    row_count: u16,
    col_count: u16,
    top: u16,
    cells: []const Cell,
    cursors: []const CursorInfo,
    swapchain_render_view: ?*const anyopaque, // windows only
) void {
    const shader_col_count: u16 = @intCast(@divTrunc(client_size.x, font_set.cell_size.x));
    const shader_row_count: u16 = @intCast(@divTrunc(client_size.y, font_set.cell_size.y));

    const copy_col_count: u16 = @min(col_count, shader_col_count);
    const blank_glyph_index = state.generateGlyph(font_set.faces[@intFromEnum(Face.regular)], .regular, ' ', false, .none, 1, .single);

    const alloc = global.glyph_cache_arena.allocator();
    state.updateCellImage(alloc, shader_col_count, shader_row_count);

    const shader_cells = state.cell_buf.items[0 .. @as(u32, shader_col_count) * @as(u32, shader_row_count)];

    // cache holds the per-glyph format
    const cache_nodes: ?[]GlyphIndexCache.Node = if (state.glyph_index_cache) |*c| c.nodes else null;

    for (0..shader_row_count) |row_i| {
        const src_row = blk: {
            const r = top + @as(u16, @intCast(row_i));
            break :blk if (r < row_count) r else 0;
        };
        const src_row_offset = @as(usize, src_row) * col_count;
        const dst_row_offset = @as(usize, row_i) * shader_col_count;
        const copy_len = if (row_i < row_count) copy_col_count else 0;

        for (0..copy_len) |ci| {
            const src = cells[src_row_offset + ci];
            const kind: u2 = if (cache_nodes) |nodes|
                (if (src.glyph_index < nodes.len) nodes[src.glyph_index].kind else 0)
            else
                0;
            shader_cells[dst_row_offset + ci] = .{
                .glyph_index = src.glyph_index,
                .bg = src.background.to_u32(),
                .fg = src.foreground.to_u32(),
                .deco = packDeco(src, kind),
            };
        }
        for (copy_len..shader_col_count) |ci| {
            shader_cells[dst_row_offset + ci] = .{
                .glyph_index = blank_glyph_index,
                .bg = global.background.to_u32(),
                .fg = global.background.to_u32(),
            };
        }
    }

    markCursors(shader_cells, cursors, shader_col_count, shader_row_count);

    // Upload glyph atlas to GPU if any new glyphs were rasterized this frame.
    if (state.glyph_atlas_dirty) flushGlyphAtlas(state);

    // Upload cell texture
    var cell_data: sg.ImageData = .{};
    const cell_bytes = std.mem.sliceAsBytes(shader_cells);
    cell_data.mip_levels[0] = .{ .ptr = cell_bytes.ptr, .size = cell_bytes.len };
    sg.updateImage(state.cell_image, cell_data);

    // Render pass
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = @as(f32, @floatFromInt(global.background.r)) / 255.0,
            .g = @as(f32, @floatFromInt(global.background.g)) / 255.0,
            .b = @as(f32, @floatFromInt(global.background.b)) / 255.0,
            .a = if (global.transparent) 0.0 else 1.0,
        },
    };

    sg.beginPass(.{
        .swapchain = if (builtin.os.tag == .windows) .{
            .width = @intCast(client_size.x),
            .height = @intCast(client_size.y),
            .sample_count = 1,
            .color_format = .RGBA8,
            .depth_format = .NONE,
            .d3d11 = .{ .render_view = swapchain_render_view },
        } else .{
            .width = @intCast(client_size.x),
            .height = @intCast(client_size.y),
            .sample_count = 1,
            .color_format = .RGBA8,
            .depth_format = .NONE,
            .gl = .{ .framebuffer = 0 },
        },
        .action = pass_action,
    });
    sg.applyPipeline(global.pip);

    var bindings: sg.Bindings = .{};
    bindings.views[0] = state.glyph_view;
    bindings.views[1] = state.cell_view;
    bindings.samplers[0] = global.glyph_sampler;
    bindings.samplers[1] = global.cell_sampler;
    sg.applyBindings(bindings);

    const fs_params = shader.FsParams{
        .cell_size = .{
            font_set.cell_size.x,
            font_set.cell_size.y,
            shader_col_count,
            shader_row_count,
        },
        .viewport = .{ @intCast(client_size.y), @intCast(client_size.x), 0, 0 },
        .underline_info = .{
            font_set.underline_position,
            font_set.underline_thickness,
            0,
            0,
        },
        .bg_color = global.background.to_vec4(),
    };
    sg.applyUniforms(shader.UB_fs_params, .{
        .ptr = &fs_params,
        .size = @sizeOf(shader.FsParams),
    });

    sg.draw(0, 4, 1);
    sg.endPass();
    // Note: caller (app.zig) calls sg.commit() and window.swapBuffers()
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
