//! Multi-page glyph atlas with append-and-freeze semantics.
//!
//! New glyphs are appended into a bounded "active" page; when it fills it
//! is frozen (never re-uploaded) and a fresh active page opens.
//! Reclamation is at whole-page granularity via `gc()`. This keeps the
//! per-frame upload cost at ~one bounded page regardless of the total
//! resident set.
//!
//! A glyph handle packs page id (high 10 bits) and slot (low 22); page 0
//! with a bare slot is the legacy single-atlas encoding. GPU resources are
//! reached through an injected `Backend` so the module stays
//! headless-testable.

const std = @import("std");
const XY = @import("xy").XY;

const GlyphAtlas = @This();

// Fixed atlas page width. 2048 is a universally supported texture dimension.
pub const atlas_width_px: u16 = 2048;
// Upper bound on a page's height.
pub const atlas_max_height_px: u16 = 2048;

pub const default_page_byte_target: usize = 4 << 20; // ~4 MiB

// Glyph handle bit layout.
pub const slot_bits: u5 = 22;
pub const slot_mask: u32 = (1 << slot_bits) - 1;
pub const max_pages: u32 = 1 << (32 - @as(u6, slot_bits)); // 1024

comptime {
    // The slot field must be wide enough for a fully-packed page.
    std.debug.assert(@as(u32, atlas_width_px) * atlas_max_height_px <= (1 << slot_bits));
}

pub inline fn packGlyph(page: u32, slot: u32) u32 {
    std.debug.assert(page < max_pages);
    std.debug.assert(slot <= slot_mask);
    return (page << slot_bits) | slot;
}
pub inline fn glyphPage(g: u32) u32 {
    return g >> slot_bits;
}
pub inline fn glyphSlot(g: u32) u32 {
    return g & slot_mask;
}

/// Cache key identifying a rasterized glyph variant. Kept 32-bit and uniquely
/// representable so the hash map hits its fast path.
pub const MapKey = packed struct(u32) {
    codepoint: u21,
    right_half: bool,
    wide: bool,
    emoji: bool,
    face: u2,
    _pad: u6 = 0,
};

/// Opaque GPU resource handle for one page (an image + its texture view).
/// The atlas never interprets these; only the backend does.
pub const PageHandle = struct {
    image: u32 = 0,
    view: u32 = 0,
};

/// Injected GPU resource lifecycle.
pub const Backend = struct {
    ctx: *anyopaque,
    createFn: *const fn (ctx: *anyopaque, size: XY(u16)) PageHandle,
    destroyFn: *const fn (ctx: *anyopaque, handle: PageHandle) void,
    uploadFn: *const fn (ctx: *anyopaque, handle: PageHandle, data: []const u8) void,

    inline fn create(self: Backend, size: XY(u16)) PageHandle {
        return self.createFn(self.ctx, size);
    }
    inline fn destroy(self: Backend, handle: PageHandle) void {
        self.destroyFn(self.ctx, handle);
    }
    inline fn upload(self: Backend, handle: PageHandle, data: []const u8) void {
        self.uploadFn(self.ctx, handle, data);
    }
};

const AtlasPage = struct {
    handle: PageHandle,
    cpu: []u8, // RGBA8 shadow, page_pixel_size.x * .y * 4
    kinds: []u8, // per-slot glyph format (0=alpha,1=subpixel,2=color)
    keys: []MapKey, // per-slot key, for O(occupants) eviction
    next_slot: u32 = 0, // bump allocator
    capacity: u32,
    dirty: bool = false,
    frozen: bool = false,
    last_used_frame: u64 = 0,
};

pub const Error = error{ OutOfMemory, TooManyGlyphPages };

backend: Backend,
page_byte_target: usize,

cell_size: ?XY(u16) = null,
cells_per_row: u16 = 0,
rows_per_page: u16 = 0,
page_pixel_size: XY(u16) = .{ .x = 0, .y = 0 },
page_capacity: u32 = 0,

/// Stable-index page table. Evicted entries become `null` and their index is
/// pushed to `free_list` for reuse, so a page id encoded in a glyph handle
/// never shifts meaning within a frame.
pages: std.ArrayList(?AtlasPage) = .empty,
free_list: std.ArrayList(u32) = .empty,
active: ?u32 = null,

map: std.AutoHashMapUnmanaged(MapKey, u32) = .empty,

/// Set by the caller once per frame; drives `last_used_frame` and gc.
current_frame: u64 = 0,

pub fn init(backend: Backend, page_byte_target: usize) GlyphAtlas {
    return .{
        .backend = backend,
        .page_byte_target = if (page_byte_target == 0) default_page_byte_target else page_byte_target,
    };
}

pub fn deinit(self: *GlyphAtlas, allocator: std.mem.Allocator) void {
    self.reset(allocator);
    self.pages.deinit(allocator);
    self.free_list.deinit(allocator);
    self.map.deinit(allocator);
    self.* = undefined;
}

/// Drop every page and forget the current cell size.
pub fn reset(self: *GlyphAtlas, allocator: std.mem.Allocator) void {
    for (self.pages.items) |*maybe| {
        if (maybe.*) |page| self.freePage(allocator, page);
        maybe.* = null;
    }
    self.pages.clearRetainingCapacity();
    self.free_list.clearRetainingCapacity();
    self.map.clearRetainingCapacity();
    self.active = null;
    self.cell_size = null;
    self.cells_per_row = 0;
    self.rows_per_page = 0;
    self.page_pixel_size = .{ .x = 0, .y = 0 };
    self.page_capacity = 0;
}

/// Establish (or change) the cell size and derive page geometry from it and the
/// byte target. A change drops all existing pages (they hold the old size).
pub fn setCellSize(self: *GlyphAtlas, allocator: std.mem.Allocator, cell: XY(u16)) void {
    std.debug.assert(cell.x > 0 and cell.y > 0);
    if (self.cell_size) |c| {
        if (c.eql(cell)) return;
    }
    self.reset(allocator);
    self.cell_size = cell;

    // page height derives from the byte target, floored to whole cell rows and
    // clamped to at least one row (so any font size fits) and the max texture
    // dimension.
    const bytes_per_row_px: usize = @as(usize, atlas_width_px) * 4;
    const target_rows_px: usize = self.page_byte_target / bytes_per_row_px;
    const max_rows: u16 = @intCast(atlas_max_height_px / cell.y);
    const rows: u16 = @intCast(std.math.clamp(
        target_rows_px / cell.y,
        1,
        @as(usize, max_rows),
    ));

    self.cells_per_row = atlas_width_px / cell.x;
    self.rows_per_page = rows;
    self.page_pixel_size = .{ .x = atlas_width_px, .y = rows * cell.y };
    self.page_capacity = @as(u32, self.cells_per_row) * rows;
}

pub const Reserved = struct { glyph: u32, newly: bool };

/// Look up `key`; on a miss, append a new slot on the active page (opening /
/// freezing pages as needed). Returns the packed glyph handle.
pub fn reserve(self: *GlyphAtlas, allocator: std.mem.Allocator, key: MapKey) Error!Reserved {
    const gop = try self.map.getOrPut(allocator, key);
    if (gop.found_existing) {
        self.touch(gop.value_ptr.*);
        return .{ .glyph = gop.value_ptr.*, .newly = false };
    }
    errdefer _ = self.map.remove(key);

    const page_id = try self.ensureActive(allocator);
    const page = &self.pages.items[page_id].?;
    const slot = page.next_slot;
    page.next_slot += 1;
    page.keys[slot] = key;
    page.kinds[slot] = 0;
    page.dirty = true;
    page.last_used_frame = self.current_frame;

    const glyph = packGlyph(page_id, slot);
    gop.value_ptr.* = glyph;
    return .{ .glyph = glyph, .newly = true };
}

fn touch(self: *GlyphAtlas, glyph: u32) void {
    if (self.pages.items[glyphPage(glyph)]) |*p| p.last_used_frame = self.current_frame;
}

fn ensureActive(self: *GlyphAtlas, allocator: std.mem.Allocator) Error!u32 {
    if (self.active) |a| if (self.pages.items[a]) |*p| {
        if (p.next_slot < p.capacity) return a;
        p.frozen = true; // full -> freeze, then open a fresh page
    };

    const id = try self.openPage(allocator);
    self.active = id;
    return id;
}

fn openPage(self: *GlyphAtlas, allocator: std.mem.Allocator) Error!u32 {
    std.debug.assert(self.cell_size != null); // setCellSize must precede reservation
    const size = self.page_pixel_size;
    const cap = self.page_capacity;
    const bytes: usize = @as(usize, size.x) * @as(usize, size.y) * 4;

    const cpu = try allocator.alloc(u8, bytes);
    errdefer allocator.free(cpu);
    @memset(cpu, 0);
    const kinds = try allocator.alloc(u8, cap);
    errdefer allocator.free(kinds);
    const keys = try allocator.alloc(MapKey, cap);
    errdefer allocator.free(keys);

    const reuse: ?u32 = if (self.free_list.items.len > 0)
        self.free_list.items[self.free_list.items.len - 1]
    else
        null;
    const id: u32 = reuse orelse @intCast(self.pages.items.len);
    if (id >= max_pages) return error.TooManyGlyphPages;

    const handle = self.backend.create(size);
    errdefer self.backend.destroy(handle);

    const page: AtlasPage = .{
        .handle = handle,
        .cpu = cpu,
        .kinds = kinds,
        .keys = keys,
        .capacity = cap,
        .last_used_frame = self.current_frame,
    };
    if (reuse) |ri| {
        self.pages.items[ri] = page;
        _ = self.free_list.pop(); // commit the reuse only on success
    } else {
        try self.pages.append(allocator, page);
    }
    return id;
}

fn freePage(self: *GlyphAtlas, allocator: std.mem.Allocator, page: AtlasPage) void {
    self.backend.destroy(page.handle);
    allocator.free(page.cpu);
    allocator.free(page.kinds);
    allocator.free(page.keys);
}

/// Per-slot glyph format for the `deco` kind bits; 0 for unknown handles.
pub fn kindOf(self: *const GlyphAtlas, glyph: u32) u2 {
    const pid = glyphPage(glyph);
    if (pid >= self.pages.items.len) return 0;
    const page = self.pages.items[pid] orelse return 0;
    const slot = glyphSlot(glyph);
    if (slot >= page.next_slot) return 0;
    return @intCast(page.kinds[slot]);
}

pub fn setKind(self: *GlyphAtlas, glyph: u32, kind: u2) void {
    const pid = glyphPage(glyph);
    if (pid >= self.pages.items.len) return;
    if (self.pages.items[pid]) |*page| page.kinds[glyphSlot(glyph)] = kind;
}

/// Pixel top-left of a glyph's slot within its page.
pub fn slotOrigin(self: *const GlyphAtlas, glyph: u32) XY(u16) {
    const cell = self.cell_size.?;
    const slot = glyphSlot(glyph);
    const col: u16 = @intCast(slot % self.cells_per_row);
    const row: u16 = @intCast(slot / self.cells_per_row);
    return .{ .x = col * cell.x, .y = row * cell.y };
}

/// Mutable page shadow, for blitting a freshly rasterized glyph.
pub fn pageCpu(self: *GlyphAtlas, page_id: u32) ?[]u8 {
    if (page_id >= self.pages.items.len) return null;
    if (self.pages.items[page_id]) |*page| return page.cpu;
    return null;
}

/// GPU handle for a page, for binding during a paint pass.
pub fn pageHandle(self: *const GlyphAtlas, page_id: u32) ?PageHandle {
    if (page_id >= self.pages.items.len) return null;
    const page = self.pages.items[page_id] orelse return null;
    return page.handle;
}

/// Upload every dirty page once. Only pages that received new glyphs this frame are dirty.
pub fn flushDirty(self: *GlyphAtlas) void {
    for (self.pages.items) |*maybe| {
        if (maybe.*) |*page| {
            if (!page.dirty) continue;
            self.backend.upload(page.handle, page.cpu);
            page.dirty = false;
        }
    }
}

/// Post-frame reclamation. Evicts whole frozen pages, coldest first, until the
/// resident shadow bytes fit `budget_bytes`. `0` disables eviction (unbounded).
pub fn gc(self: *GlyphAtlas, allocator: std.mem.Allocator, budget_bytes: usize) void {
    if (budget_bytes == 0) return;
    while (self.residentBytes() > budget_bytes) {
        const victim = self.pickVictim() orelse break;
        self.evict(allocator, victim);
    }
}

fn residentBytes(self: *const GlyphAtlas) usize {
    var total: usize = 0;
    for (self.pages.items) |maybe| {
        if (maybe) |page| total += page.cpu.len;
    }
    return total;
}

fn pickVictim(self: *const GlyphAtlas) ?u32 {
    var best: ?u32 = null;
    var best_frame: u64 = 0;
    for (self.pages.items, 0..) |maybe, i| {
        const page = maybe orelse continue;
        if (!page.frozen) continue; // never evict the open/active page
        if (self.active != null and self.active.? == i) continue;
        if (page.last_used_frame == self.current_frame) continue; // used this frame
        if (best == null or page.last_used_frame < best_frame) {
            best = @intCast(i);
            best_frame = page.last_used_frame;
        }
    }
    return best;
}

fn evict(self: *GlyphAtlas, allocator: std.mem.Allocator, page_id: u32) void {
    const page = self.pages.items[page_id].?;
    var slot: u32 = 0;
    while (slot < page.next_slot) : (slot += 1) _ = self.map.remove(page.keys[slot]);
    self.freePage(allocator, page);
    self.pages.items[page_id] = null;
    // If this append fails the index is simply not reused.
    self.free_list.append(allocator, page_id) catch {};
}

pub fn lookup(self: *const GlyphAtlas, key: MapKey) ?u32 {
    return self.map.get(key);
}

pub fn pageCapacity(self: *const GlyphAtlas) u32 {
    return self.page_capacity;
}

pub fn livePageCount(self: *const GlyphAtlas) usize {
    var n: usize = 0;
    for (self.pages.items) |maybe| {
        if (maybe != null) n += 1;
    }
    return n;
}

pub fn isLive(self: *const GlyphAtlas, page_id: u32) bool {
    return page_id < self.pages.items.len and self.pages.items[page_id] != null;
}

pub fn isFrozen(self: *const GlyphAtlas, page_id: u32) bool {
    if (page_id >= self.pages.items.len) return false;
    const page = self.pages.items[page_id] orelse return false;
    return page.frozen;
}

const testing = std.testing;

const TestBackend = struct {
    next: u32 = 1,
    creates: usize = 0,
    destroys: usize = 0,
    uploads: usize = 0,

    fn iface(self: *TestBackend) Backend {
        return .{ .ctx = self, .createFn = create, .destroyFn = destroy, .uploadFn = upload };
    }
    fn create(ctx: *anyopaque, size: XY(u16)) PageHandle {
        _ = size;
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        self.creates += 1;
        const id = self.next;
        self.next += 1;
        return .{ .image = id, .view = id };
    }
    fn destroy(ctx: *anyopaque, handle: PageHandle) void {
        _ = handle;
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        self.destroys += 1;
    }
    fn upload(ctx: *anyopaque, handle: PageHandle, data: []const u8) void {
        _ = handle;
        _ = data;
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        self.uploads += 1;
    }
};

fn tkey(cp: u21) MapKey {
    return .{ .codepoint = cp, .right_half = false, .wide = false, .emoji = false, .face = 0 };
}

test "pack/unpack round-trip and legacy encoding" {
    const g = packGlyph(5, 12345);
    try testing.expectEqual(@as(u32, 5), glyphPage(g));
    try testing.expectEqual(@as(u32, 12345), glyphSlot(g));
    // a bare slot value (no page bits) resolves to page 0
    try testing.expectEqual(@as(u32, 0), glyphPage(1000));
    try testing.expectEqual(@as(u32, 1000), glyphSlot(1000));
    // maximal slot fits exactly
    try testing.expectEqual(slot_mask, glyphSlot(packGlyph(0, slot_mask)));
}

test "geometry: 4 MiB target, 512x512 cell -> capacity 4" {
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(testing.allocator);
    a.setCellSize(testing.allocator, .{ .x = 512, .y = 512 });
    try testing.expectEqual(@as(u16, 4), a.cells_per_row);
    try testing.expectEqual(@as(u16, 1), a.rows_per_page);
    try testing.expectEqual(@as(u32, 4), a.pageCapacity());
    try testing.expectEqual(@as(u16, 512), a.page_pixel_size.y);
}

test "append fills a page then freezes and opens the next" {
    const alloc = testing.allocator;
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(alloc);
    a.setCellSize(alloc, .{ .x = 512, .y = 512 });
    a.current_frame = 1;

    const cap = a.pageCapacity();
    var i: u21 = 0;
    while (i < cap) : (i += 1) {
        const r = try a.reserve(alloc, tkey(i));
        try testing.expect(r.newly);
        try testing.expectEqual(@as(u32, 0), glyphPage(r.glyph));
        try testing.expectEqual(@as(u32, i), glyphSlot(r.glyph));
    }
    try testing.expectEqual(@as(usize, 1), a.livePageCount());
    try testing.expect(!a.isFrozen(0));

    // one past capacity opens page 1 and freezes page 0
    const r = try a.reserve(alloc, tkey(@intCast(cap)));
    try testing.expect(r.newly);
    try testing.expectEqual(@as(u32, 1), glyphPage(r.glyph));
    try testing.expect(a.isFrozen(0));
    try testing.expect(!a.isFrozen(1));
    try testing.expectEqual(@as(?u32, 1), a.active);
    try testing.expectEqual(@as(usize, 2), be.creates);
}

test "reserve of an existing key hits without appending" {
    const alloc = testing.allocator;
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(alloc);
    a.setCellSize(alloc, .{ .x = 512, .y = 512 });

    const first = try a.reserve(alloc, tkey(7));
    try testing.expect(first.newly);
    const again = try a.reserve(alloc, tkey(7));
    try testing.expect(!again.newly);
    try testing.expectEqual(first.glyph, again.glyph);
    try testing.expectEqual(@as(u32, 1), a.map.count());
}

test "setKind / kindOf" {
    const alloc = testing.allocator;
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(alloc);
    a.setCellSize(alloc, .{ .x = 512, .y = 512 });

    const r = try a.reserve(alloc, tkey(1));
    try testing.expectEqual(@as(u2, 0), a.kindOf(r.glyph));
    a.setKind(r.glyph, 2);
    try testing.expectEqual(@as(u2, 2), a.kindOf(r.glyph));
    // unknown handle -> 0
    try testing.expectEqual(@as(u2, 0), a.kindOf(packGlyph(9, 9)));
}

test "flushDirty uploads only dirty pages, once" {
    const alloc = testing.allocator;
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(alloc);
    a.setCellSize(alloc, .{ .x = 512, .y = 512 });

    _ = try a.reserve(alloc, tkey(1));
    _ = try a.reserve(alloc, tkey(2)); // both on page 0
    try testing.expectEqual(@as(usize, 1), a.livePageCount());

    a.flushDirty();
    try testing.expectEqual(@as(usize, 1), be.uploads); // one dirty page
    a.flushDirty();
    try testing.expectEqual(@as(usize, 1), be.uploads); // nothing dirty now
}

test "gc evicts the coldest frozen page and reuses its index" {
    const alloc = testing.allocator;
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(alloc);
    a.setCellSize(alloc, .{ .x = 512, .y = 512 });

    const cap = a.pageCapacity();
    // Fill three pages, each on its own frame so page 0 is coldest.
    var cp: u21 = 0;
    var frame: u64 = 1;
    var filled: u32 = 0;
    while (filled < cap * 3) : (filled += 1) {
        a.current_frame = frame;
        _ = try a.reserve(alloc, tkey(cp));
        cp += 1;
        if ((filled + 1) % cap == 0) frame += 1; // advance frame at each page boundary
    }
    try testing.expectEqual(@as(usize, 3), a.livePageCount());
    try testing.expect(a.isFrozen(0) and a.isFrozen(1) and !a.isFrozen(2));

    const page_bytes: usize = @as(usize, a.page_pixel_size.x) * a.page_pixel_size.y * 4;
    a.current_frame = 100;
    a.gc(alloc, page_bytes * 2); // room for two pages -> evict exactly one

    try testing.expectEqual(@as(usize, 2), a.livePageCount());
    try testing.expect(!a.isLive(0)); // coldest page 0 gone
    try testing.expectEqual(@as(?u32, null), a.lookup(tkey(0))); // its keys removed
    try testing.expectEqual(@as(usize, 1), be.destroys);

    // A new reservation reuses the freed index 0 (page 2 is full).
    const r = try a.reserve(alloc, tkey(9999));
    try testing.expectEqual(@as(u32, 0), glyphPage(r.glyph));
    try testing.expect(a.isLive(0));
}

test "cell-size change resets all pages" {
    const alloc = testing.allocator;
    var be = TestBackend{};
    var a = GlyphAtlas.init(be.iface(), 4 << 20);
    defer a.deinit(alloc);
    a.setCellSize(alloc, .{ .x = 512, .y = 512 });
    _ = try a.reserve(alloc, tkey(1));
    try testing.expectEqual(@as(usize, 1), a.livePageCount());

    a.setCellSize(alloc, .{ .x = 256, .y = 512 });
    try testing.expectEqual(@as(usize, 0), a.livePageCount());
    try testing.expectEqual(@as(u32, 0), a.map.count());
    try testing.expectEqual(@as(usize, 1), be.destroys); // old page destroyed
    try testing.expectEqual(@as(u16, 8), a.cells_per_row); // 2048/256
}
