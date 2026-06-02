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
pub const RasterFormat = Rasterizer.RasterFormat;
pub const RasterizerBackend = Rasterizer.Backend;
pub const Hinting = Rasterizer.Hinting;
pub const SymbolRasterizer = Rasterizer.SymbolRasterizer;
pub const Cell = @import("cell").Cell;
pub const RGBA = @import("color").RGBA;

pub const CursorShape = enum(i32) { block = 0, beam = 1, underline = 2 };

pub const CursorInfo = struct {
    vis: bool = false,
    row: u16 = 0,
    col: u16 = 0,
    width: u8 = 1,
    shape: CursorShape = .block,
    color: RGBA = .init(255, 255, 255, 255),
};

fn packCursor(c: CursorInfo) u32 {
    const shape: u32 = @as(u32, @intCast(@intFromEnum(c.shape))) + 1;
    return shape |
        (@as(u32, c.color.r) << 8) |
        (@as(u32, c.color.g) << 16) |
        (@as(u32, c.color.b) << 24);
}

fn markCursors(shader_cells: []ShaderCell, cursors: []const CursorInfo, cols: u16, rows: u16) void {
    for (cursors) |cur| {
        if (!cur.vis or cur.row >= rows or cur.col >= cols) continue;
        const packed_cursor = packCursor(cur);
        const row_off = @as(usize, cur.row) * cols;
        const width = if (cur.shape == .beam) 1 else cur.width;
        var c: u16 = 0;
        while (c < width and cur.col + c < cols) : (c += 1)
            shader_cells[row_off + cur.col + c].cursor = packed_cursor;
    }
}

const log = std.log.scoped(.gpu);

// Maximum glyph atlas dimension.  4096 is universally supported and gives
// 65536+ glyph slots at typical cell sizes - far more than needed in practice.
const max_atlas_dim: u16 = 4096;

fn getAtlasCellCount(cell_size: XY(u16)) XY(u16) {
    return .{
        .x = @intCast(@divTrunc(max_atlas_dim, cell_size.x)),
        .y = @intCast(@divTrunc(max_atlas_dim, cell_size.y)),
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
//
// Cursor field bit layout (0 → no cursor on this cell):
//    7..0 : shape+1 (1=block, 2=beam, 3=underline)
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
    return color24 | style | strike | kbits;
}

const global = struct {
    var init_called: bool = false;
    var rasterizer: Rasterizer = undefined;
    var pip: sg.Pipeline = .{};
    var composite_replace_pip: sg.Pipeline = .{};
    var composite_srcover_pip: sg.Pipeline = .{};
    var present_pip: sg.Pipeline = .{};
    var glyph_sampler: sg.Sampler = .{};
    var cell_sampler: sg.Sampler = .{};
    var src_sampler: sg.Sampler = .{};
    var glyph_cache_arena: std.heap.ArenaAllocator = undefined;
    var background: RGBA = .init(0, 255, 255, 255); // default is warning yellow
    var composite_sample_flip_y: f32 = 0.0;
    var transparent: bool = false;
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
}

pub fn deinit() void {
    std.debug.assert(global.init_called);
    global.init_called = false;
    sg.destroyPipeline(global.pip);
    sg.destroyPipeline(global.composite_replace_pip);
    sg.destroyPipeline(global.composite_srcover_pip);
    sg.destroyPipeline(global.present_pip);
    sg.destroySampler(global.glyph_sampler);
    sg.destroySampler(global.cell_sampler);
    sg.destroySampler(global.src_sampler);
    global.glyph_cache_arena.deinit();
    global.rasterizer.deinit();
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
        return false;
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
        split: Rasterizer.GlyphSplit,
    ) u32 {
        const atlas_cell_count = getAtlasCellCount(font.cell_size);
        const atlas_total: u32 = @as(u32, atlas_cell_count.x) * @as(u32, atlas_cell_count.y);
        const atlas_pixel_size: XY(u16) = .{
            .x = atlas_cell_count.x * font.cell_size.x,
            .y = atlas_cell_count.y * font.cell_size.y,
        };

        const atlas_retained = state.updateGlyphImage(atlas_pixel_size);

        const cache_valid = if (state.glyph_cache_cell_size) |s| s.eql(font.cell_size) else false;
        state.glyph_cache_cell_size = font.cell_size;

        if (!atlas_retained or !cache_valid) {
            if (state.glyph_index_cache) |*c| {
                c.deinit(global.glyph_cache_arena.allocator());
                _ = global.glyph_cache_arena.reset(.retain_capacity);
                state.glyph_index_cache = null;
                // cell_buf was allocated from the arena; clear it so the next
                // resize doesn't memcpy from the now-freed memory.
                state.cell_buf = .empty;
            }
        }

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
            @intFromEnum(face),
        ) catch |e| oom(e)) {
            .newly_reserved => |reserved| {
                // Rasterize into RGBA staging buffer then upload to the atlas
                const staging_w: u32 = @as(u32, font.cell_size.x) * 2;
                const staging_h: u32 = font.cell_size.y;
                var staging_buf = global.glyph_cache_arena.allocator().alloc(
                    u8,
                    staging_w * staging_h * 4,
                ) catch |e| oom(e);
                defer global.glyph_cache_arena.allocator().free(staging_buf);
                @memset(staging_buf, 0);

                const rr = global.rasterizer.render(font, codepoint, split, staging_buf);
                cache.nodes[reserved.index].kind = @intFromEnum(rr.format);

                // Atlas cell position for this glyph index
                const atlas_col: u16 = @intCast(reserved.index % atlas_cell_count.x);
                const atlas_row: u16 = @intCast(reserved.index / atlas_cell_count.x);
                const atlas_x: u16 = atlas_col * font.cell_size.x;
                const atlas_y: u16 = atlas_row * font.cell_size.y;

                // Source region in the staging buffer
                const src_x: u16 = if (right_half) font.cell_size.x else 0;
                const glyph_w: u16 = font.cell_size.x;
                const glyph_h: u16 = font.cell_size.y;

                // Build a sub-region buffer for sokol updateImage
                const glyph_row_bytes: u32 = @as(u32, glyph_w) * 4;
                const staging_row_bytes: u32 = staging_w * 4;
                var region_buf = global.glyph_cache_arena.allocator().alloc(
                    u8,
                    glyph_row_bytes * @as(u32, glyph_h),
                ) catch |e| oom(e);
                defer global.glyph_cache_arena.allocator().free(region_buf);

                for (0..glyph_h) |row_i| {
                    const src_off = row_i * staging_row_bytes + @as(u32, src_x) * 4;
                    const dst_off = row_i * glyph_row_bytes;
                    @memcpy(region_buf[dst_off .. dst_off + glyph_row_bytes], staging_buf[src_off .. src_off + glyph_row_bytes]);
                }

                // Write into the CPU-side atlas shadow.  The GPU upload is
                // deferred to paint() so it happens at most once per frame.
                blitAtlasCpu(state, atlas_x, atlas_y, glyph_w, glyph_h, region_buf);
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

    markCursors(shader_cells, cursors, cols, rows);

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

    pub const BlendMode = enum { replace, src_over };
};

/// Composite one layer's offscreen pixel buffer into another's, using the
/// `composite_{replace,srcover}_pip` pipeline and a sub-rect viewport.
pub fn compositeLayer(
    dst_layer_state: *const LayerGpuState,
    src_layer_state: *const LayerGpuState,
    op: CompositeOp,
) void {
    if (dst_layer_state.pixel_image.id == 0 or src_layer_state.pixel_image.id == 0) return;
    if (op.dst_w == 0 or op.dst_h == 0) return;

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{ .load_action = .LOAD };

    sg.beginPass(.{
        .attachments = dst_layer_state.attachments(),
        .action = pass_action,
    });

    sg.applyViewport(op.dst_x, op.dst_y, op.dst_w, op.dst_h, true);

    const pipeline = switch (op.blend) {
        .replace => global.composite_replace_pip,
        .src_over => global.composite_srcover_pip,
    };
    sg.applyPipeline(pipeline);

    var bindings: sg.Bindings = .{};
    bindings.views[shader.VIEW_src_tex] = src_layer_state.pixel_view;
    bindings.samplers[shader.SMP_src_smp] = global.src_sampler;
    sg.applyBindings(bindings);

    const fs_params = shader.FsCompositeParams{
        .composite_alpha = .{ @as(f32, @floatFromInt(op.alpha)) / 255.0, 0, 0, 0 },
        .sample_flip = .{ global.composite_sample_flip_y, 0, 0, 0 },
    };
    sg.applyUniforms(shader.UB_fs_composite_params, .{
        .ptr = &fs_params,
        .size = @sizeOf(shader.FsCompositeParams),
    });

    sg.draw(0, 4, 1);
    sg.endPass();
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

// Blit one glyph cell into the CPU-side atlas shadow.
// pixels is RGBA8 with stride = w * 4.
fn blitAtlasCpu(
    state: *const WindowState,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const u8,
) void {
    const asz = state.glyph_image_size;
    const total_bytes: usize = @as(usize, asz.x) * @as(usize, asz.y) * 4;

    if (!atlas_cpu_size.eql(asz)) {
        if (atlas_cpu) |old| std.heap.page_allocator.free(old);
        atlas_cpu = std.heap.page_allocator.alloc(u8, total_bytes) catch |e| oom(e);
        @memset(atlas_cpu.?, 0);
        atlas_cpu_size = asz;
    }

    const buf = atlas_cpu.?;
    const row_bytes: usize = @as(usize, w) * 4;
    const atlas_row_bytes: usize = @as(usize, asz.x) * 4;
    for (0..h) |row_i| {
        const src_off = row_i * row_bytes;
        const dst_off = (@as(usize, y) + row_i) * atlas_row_bytes + @as(usize, x) * 4;
        @memcpy(buf[dst_off .. dst_off + row_bytes], pixels[src_off .. src_off + row_bytes]);
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
    const blank_glyph_index = state.generateGlyph(font_set.faces[@intFromEnum(Face.regular)], .regular, ' ', .single);

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
