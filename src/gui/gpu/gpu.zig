// sokol_gfx GPU backend for the wio-based renderer.
//
// Threading: all public functions must be called from the wio/GL thread
// (the thread that called sg.setup()).

const std = @import("std");
const sg = @import("sokol").gfx;
const Rasterizer = @import("rasterizer");
const GlyphIndexCache = @import("GlyphIndexCache");
const gui_cell = @import("Cell");
const XY = @import("xy").XY;
const builtin_shader = @import("builtin.glsl.zig");

pub const Font = Rasterizer.Font;
pub const GlyphKind = Rasterizer.GlyphKind;
pub const Cell = gui_cell.Cell;
pub const Color = gui_cell.Rgba8;
const Rgba8 = gui_cell.Rgba8;

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

// Shader cell layout for the RGBA32UI cell texture.
// Each texel encodes one terminal cell:
//   .r = glyph_index  (u32)
//   .g = bg packed    (Rgba8 bit-cast to u32: r<<24|g<<16|b<<8|a)
//   .b = fg packed    (same)
//   .a = 0 (reserved)
const ShaderCell = extern struct {
    glyph_index: u32,
    bg: u32,
    fg: u32,
    _pad: u32 = 0,
};

const global = struct {
    var init_called: bool = false;
    var rasterizer: Rasterizer = undefined;
    var pip: sg.Pipeline = .{};
    var glyph_sampler: sg.Sampler = .{};
    var cell_sampler: sg.Sampler = .{};
    var glyph_cache_arena: std.heap.ArenaAllocator = undefined;
    var background: Rgba8 = .{ .r = 19, .g = 19, .b = 19, .a = 255 };
};

pub fn init(allocator: std.mem.Allocator) !void {
    std.debug.assert(!global.init_called);
    global.init_called = true;

    global.rasterizer = try Rasterizer.init(allocator);
    global.glyph_cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // Build shader + pipeline
    const shd = sg.makeShader(builtin_shader.shaderDesc(sg.queryBackend()));

    var pip_desc: sg.PipelineDesc = .{ .shader = shd };
    pip_desc.primitive_type = .TRIANGLE_STRIP;
    pip_desc.color_count = 1;
    global.pip = sg.makePipeline(pip_desc);

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
}

pub fn deinit() void {
    std.debug.assert(global.init_called);
    global.init_called = false;
    sg.destroyPipeline(global.pip);
    sg.destroySampler(global.glyph_sampler);
    sg.destroySampler(global.cell_sampler);
    global.glyph_cache_arena.deinit();
    global.rasterizer.deinit();
}

pub fn loadFont(name: []const u8, size_px: u16) !Font {
    return global.rasterizer.loadFont(name, size_px);
}

pub fn setBackground(color: Rgba8) void {
    global.background = color;
}

// ── WindowState ────────────────────────────────────────────────────────────

pub const WindowState = struct {
    // GL window size in pixels
    size: XY(u32) = .{ .x = 0, .y = 0 },

    // Glyph atlas (R8 2D texture + view)
    glyph_image: sg.Image = .{},
    glyph_view: sg.View = .{},
    glyph_image_size: XY(u16) = .{ .x = 0, .y = 0 },

    // Cell grid (RGBA32UI 2D texture + view), updated each frame
    cell_image: sg.Image = .{},
    cell_view: sg.View = .{},
    cell_image_size: XY(u16) = .{ .x = 0, .y = 0 },
    cell_buf: std.ArrayListUnmanaged(ShaderCell) = .{},

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
            .pixel_format = .R8,
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
                .width = cols,
                .height = rows,
                .pixel_format = .RGBA32UI,
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
        codepoint: u21,
        kind: Rasterizer.GlyphKind,
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

        const right_half: bool = switch (kind) {
            .single, .left => false,
            .right => true,
        };

        switch (cache.reserve(
            global.glyph_cache_arena.allocator(),
            codepoint,
            right_half,
        ) catch |e| oom(e)) {
            .newly_reserved => |reserved| {
                // Rasterize into a staging buffer then upload the relevant
                // portion to the atlas.
                const staging_w: u32 = @as(u32, font.cell_size.x) * 2;
                const staging_h: u32 = font.cell_size.y;
                var staging_buf = global.glyph_cache_arena.allocator().alloc(
                    u8,
                    staging_w * staging_h,
                ) catch |e| oom(e);
                defer global.glyph_cache_arena.allocator().free(staging_buf);
                @memset(staging_buf, 0);

                global.rasterizer.render(font, codepoint, kind, staging_buf);

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
                var region_buf = global.glyph_cache_arena.allocator().alloc(
                    u8,
                    @as(u32, glyph_w) * @as(u32, glyph_h),
                ) catch |e| oom(e);
                defer global.glyph_cache_arena.allocator().free(region_buf);

                for (0..glyph_h) |row_i| {
                    const src_off = row_i * staging_w + src_x;
                    const dst_off = row_i * glyph_w;
                    @memcpy(region_buf[dst_off .. dst_off + glyph_w], staging_buf[src_off .. src_off + glyph_w]);
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

// CPU-side shadow copy of the glyph atlas (R8, row-major).
// Kept alive for the process lifetime; resized when the atlas image grows.
var atlas_cpu: ?[]u8 = null;
var atlas_cpu_size: XY(u16) = .{ .x = 0, .y = 0 };

// Blit one glyph cell into the CPU-side atlas shadow.
fn blitAtlasCpu(
    state: *const WindowState,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const u8,
) void {
    const asz = state.glyph_image_size;
    const total: usize = @as(usize, asz.x) * @as(usize, asz.y);

    if (!atlas_cpu_size.eql(asz)) {
        if (atlas_cpu) |old| std.heap.page_allocator.free(old);
        atlas_cpu = std.heap.page_allocator.alloc(u8, total) catch |e| oom(e);
        @memset(atlas_cpu.?, 0);
        atlas_cpu_size = asz;
    }

    const buf = atlas_cpu.?;
    for (0..h) |row_i| {
        const src_off = row_i * w;
        const dst_off = (@as(usize, y) + row_i) * asz.x + x;
        @memcpy(buf[dst_off .. dst_off + w], pixels[src_off .. src_off + w]);
    }
}

// Upload the CPU shadow to the GPU.  Called once per frame if dirty.
// Must be called outside a sokol render pass.
fn flushGlyphAtlas(state: *WindowState) void {
    const asz = state.glyph_image_size;
    const total: usize = @as(usize, asz.x) * @as(usize, asz.y);
    const buf = atlas_cpu orelse return;

    var img_data: sg.ImageData = .{};
    img_data.mip_levels[0] = .{ .ptr = buf.ptr, .size = total };
    sg.updateImage(state.glyph_image, img_data);
    state.glyph_atlas_dirty = false;
}

pub fn paint(
    state: *WindowState,
    client_size: XY(u32),
    font: Font,
    row_count: u16,
    col_count: u16,
    top: u16,
    cells: []const Cell,
) void {
    const shader_col_count: u16 = @intCast(@divTrunc(client_size.x, font.cell_size.x));
    const shader_row_count: u16 = @intCast(@divTrunc(client_size.y, font.cell_size.y));

    const copy_col_count: u16 = @min(col_count, shader_col_count);
    const blank_glyph_index = state.generateGlyph(font, ' ', .single);

    const alloc = global.glyph_cache_arena.allocator();
    state.updateCellImage(alloc, shader_col_count, shader_row_count);

    const shader_cells = state.cell_buf.items[0 .. @as(u32, shader_col_count) * @as(u32, shader_row_count)];

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
            shader_cells[dst_row_offset + ci] = .{
                .glyph_index = src.glyph_index,
                .bg = @bitCast(src.background),
                .fg = @bitCast(src.foreground),
            };
        }
        for (copy_len..shader_col_count) |ci| {
            shader_cells[dst_row_offset + ci] = .{
                .glyph_index = blank_glyph_index,
                .bg = @bitCast(global.background),
                .fg = @bitCast(global.background),
            };
        }
    }

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
            .a = 1.0,
        },
    };

    sg.beginPass(.{
        .swapchain = .{
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

    const fs_params = builtin_shader.FsParams{
        .cell_size_x = font.cell_size.x,
        .cell_size_y = font.cell_size.y,
        .col_count = shader_col_count,
        .row_count = shader_row_count,
        .viewport_height = @intCast(client_size.y),
    };
    sg.applyUniforms(0, .{
        .ptr = &fs_params,
        .size = @sizeOf(builtin_shader.FsParams),
    });

    sg.draw(0, 4, 1);
    sg.endPass();
    // Note: caller (app.zig) calls sg.commit() and window.swapBuffers()
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
