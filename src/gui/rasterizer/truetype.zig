const std = @import("std");
const TrueType = @import("TrueType");
const XY = @import("xy").XY;
const font_finder = @import("font_finder.zig");

const Self = @This();

pub const GlyphKind = enum {
    single,
    left,
    right,
};

pub const Font = struct {
    cell_size: XY(u16),
    scale: f32 = 0,
    ascent_px: i32 = 0,
    tt: ?TrueType = null,
};

pub const Fonts = struct {};

allocator: std.mem.Allocator,
font_data: std.ArrayListUnmanaged([]u8),

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .font_data = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.font_data.items) |data| {
        self.allocator.free(data);
    }
    self.font_data.deinit(self.allocator);
}

pub fn loadFont(self: *Self, name: []const u8, size_px: u16) !Font {
    const path = try font_finder.findFont(self.allocator, name);
    defer self.allocator.free(path);

    const data = try std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024);
    errdefer self.allocator.free(data);

    const tt = try TrueType.load(data);

    const scale = tt.scaleForPixelHeight(@floatFromInt(size_px));
    const vm = tt.verticalMetrics();

    // Use the full block glyph (U+2588) to derive exact cell dimensions.
    // Its rasterized bbox defines exactly how many pixels tall a full-height
    // character is, and where the baseline sits within the cell.  Using font
    // metrics (vm.ascent/vm.descent) produces a cell_h that may differ from
    // the glyph because the font bbox can diverge from nominal metrics.
    const full_block_glyph = tt.codepointGlyphIndex('█');
    const block_bbox = tt.glyphBitmapBox(full_block_glyph, scale, scale);
    const has_block = full_block_glyph != .notdef and block_bbox.y1 > block_bbox.y0;
    const ascent_px: i32 = if (has_block)
        -@as(i32, block_bbox.y0)
    else
        @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(vm.ascent)) * scale)));
    const cell_h: u16 = @as(u16, if (has_block)
        @intCast(@max(block_bbox.y1 - block_bbox.y0, 1))
    else blk: {
        const d: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(vm.descent)) * scale));
        break :blk @intCast(@max(ascent_px - d, 1));
    }) -| 1;

    const m_glyph = tt.codepointGlyphIndex('M');
    const m_hmetrics = tt.glyphHMetrics(m_glyph);
    const cell_w_f: f32 = @as(f32, @floatFromInt(m_hmetrics.advance_width)) * scale;
    const cell_w: u16 = @as(u16, @intFromFloat(@ceil(cell_w_f))) -| 1;

    try self.font_data.append(self.allocator, data);

    return Font{
        .tt = tt, // TrueType holds a slice into `data` which is now owned by self.font_data
        .cell_size = .{ .x = cell_w, .y = cell_h },
        .scale = scale,
        .ascent_px = ascent_px,
    };
}

pub fn render(
    self: *const Self,
    font: Font,
    codepoint: u21,
    kind: GlyphKind,
    staging_buf: []u8,
) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tt = font.tt orelse return;

    var pixels = std.ArrayListUnmanaged(u8){};

    const glyph = tt.codepointGlyphIndex(codepoint);
    const dims = tt.glyphBitmap(alloc, &pixels, glyph, font.scale, font.scale) catch return;

    if (dims.width == 0 or dims.height == 0) return;

    // Always use 2*cell_w as the row stride so it matches the staging buffer
    // width allocated by generateGlyph (which always allocates 2*cell_w wide).
    const buf_w: i32 = @as(i32, @intCast(font.cell_size.x)) * 2;
    const buf_h: i32 = @intCast(font.cell_size.y);

    const x_offset: i32 = switch (kind) {
        .single, .left => 0,
        .right => @intCast(font.cell_size.x),
    };

    for (0..dims.height) |row| {
        const dst_y: i32 = font.ascent_px + @as(i32, dims.off_y) + @as(i32, @intCast(row));
        if (dst_y < 0 or dst_y >= buf_h) continue;

        for (0..dims.width) |col| {
            const dst_x: i32 = x_offset + @as(i32, dims.off_x) + @as(i32, @intCast(col));
            if (dst_x < 0 or dst_x >= buf_w) continue;

            const src_idx = row * dims.width + col;
            const dst_idx: usize = @intCast(dst_y * buf_w + dst_x);

            if (src_idx < pixels.items.len and dst_idx < staging_buf.len) {
                staging_buf[dst_idx] = pixels.items[src_idx];
            }
        }
    }
}
