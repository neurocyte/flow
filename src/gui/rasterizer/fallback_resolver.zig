//! per-codepoint font fallback resolver.

const std = @import("std");
const font_finder = @import("font_finder");

pub const EmbeddedFont = struct {
    data: []const u8,
    is_color: bool,
    tag: []const u8,
};

const max_faces = 255;

const face_metrics = @import("face_metrics");
pub const FaceMetrics = face_metrics.FaceMetrics;
pub const faceScaleFactor = face_metrics.faceScaleFactor;

pub fn FallbackResolver(comptime Backend: type) type {
    return struct {
        const Resolver = @This();
        pub const Face = Backend.Face;
        const Context = Backend.Context;

        const Entry = struct {
            face: Backend.Face,
            path_hash: u64,
            embedded: bool,
        };
        const CacheEntry = struct { found: bool, index: u8 };
        const CacheKey = struct { cp: u21, color: bool };

        cache: std.AutoHashMapUnmanaged(CacheKey, CacheEntry) = .empty,
        faces: std.ArrayList(Entry) = .empty,
        current_size_px: u16 = 0,
        embedded_loaded: bool = false,

        pub fn deinit(self: *Resolver, ctx: Context, allocator: std.mem.Allocator) void {
            for (self.faces.items) |*e| Backend.deinitFace(ctx, allocator, &e.face);
            self.faces.deinit(allocator);
            self.cache.deinit(allocator);
        }

        fn loadEmbedded(self: *Resolver, ctx: Context, allocator: std.mem.Allocator, size_px: u16) void {
            if (self.embedded_loaded) return;
            self.embedded_loaded = true;
            inline for (Backend.embedded_fonts) |ef| {
                if (ef.data.len != 0) {
                    if (Backend.loadEmbedded(ctx, allocator, ef.data, size_px, ef.is_color)) |face| {
                        self.faces.append(allocator, .{
                            .face = face,
                            .path_hash = std.hash.Wyhash.hash(0, ef.tag),
                            .embedded = true,
                        }) catch {
                            var f = face;
                            Backend.deinitFace(ctx, allocator, &f);
                        };
                    }
                }
            }
        }

        pub fn resolve(
            self: *Resolver,
            ctx: Context,
            allocator: std.mem.Allocator,
            codepoint: u21,
            size_px: u16,
            prefer_color_override: bool,
            primary: FaceMetrics,
        ) ?*const Backend.Face {
            if (self.current_size_px != 0 and self.current_size_px != size_px) {
                for (self.faces.items) |*e| Backend.deinitFace(ctx, allocator, &e.face);
                self.faces.clearRetainingCapacity();
                self.cache.clearRetainingCapacity();
                self.embedded_loaded = false;
            }
            self.current_size_px = size_px;
            self.loadEmbedded(ctx, allocator, size_px);

            const prefer_color = prefer_color_override or Backend.preferColor(codepoint);
            const key: CacheKey = .{ .cp = codepoint, .color = prefer_color };

            if (self.cache.get(key)) |entry|
                return if (entry.found) &self.faces.items[entry.index].face else null;

            const candidates = font_finder.findFallbackFonts(allocator, codepoint, prefer_color) catch
                return self.cacheNegative(allocator, key);
            defer {
                for (candidates) |cand| allocator.free(cand.path);
                allocator.free(candidates);
            }

            for (candidates) |cand| {
                const path_hash = std.hash.Wyhash.hash(0, cand.path);

                var seen = false;
                for (self.faces.items, 0..) |*existing, idx| {
                    if (existing.path_hash == path_hash) {
                        if (Backend.hasGlyph(&existing.face, codepoint)) {
                            self.cache.put(allocator, key, .{ .found = true, .index = @intCast(idx) }) catch {};
                            return &self.faces.items[idx].face;
                        }
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;

                var face = Backend.loadPath(ctx, allocator, cand, size_px) orelse continue;
                if (!Backend.hasGlyph(&face, codepoint)) {
                    Backend.deinitFace(ctx, allocator, &face);
                    continue;
                }
                const scale = faceScaleFactor(primary, Backend.faceMetrics(&face));
                const adj: u16 = @intFromFloat(@max(1.0, @round(@as(f64, @floatFromInt(size_px)) * scale)));
                if (adj != size_px) Backend.setFaceSize(ctx, &face, adj);
                if (self.faces.items.len >= max_faces) {
                    Backend.deinitFace(ctx, allocator, &face);
                    return self.cacheNegative(allocator, key);
                }
                const idx: u8 = @intCast(self.faces.items.len);
                self.faces.append(allocator, .{ .face = face, .path_hash = path_hash, .embedded = false }) catch {
                    Backend.deinitFace(ctx, allocator, &face);
                    return self.cacheNegative(allocator, key);
                };
                self.cache.put(allocator, key, .{ .found = true, .index = idx }) catch {};
                return &self.faces.items[idx].face;
            }

            for (self.faces.items, 0..) |*e, idx| {
                if (e.embedded and Backend.hasGlyph(&e.face, codepoint)) {
                    self.cache.put(allocator, key, .{ .found = true, .index = @intCast(idx) }) catch {};
                    return &self.faces.items[idx].face;
                }
            }

            return self.cacheNegative(allocator, key);
        }

        pub fn resolveExisting(self: *Resolver, codepoint: u21, prefer_color: bool) ?*const Backend.Face {
            const entry = self.cache.get(.{ .cp = codepoint, .color = prefer_color }) orelse return null;
            return if (entry.found) &self.faces.items[entry.index].face else null;
        }

        fn cacheNegative(self: *Resolver, allocator: std.mem.Allocator, key: CacheKey) ?*const Backend.Face {
            self.cache.put(allocator, key, .{ .found = false, .index = 0 }) catch {};
            return null;
        }
    };
}
