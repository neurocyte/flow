const std = @import("std");
const builtin = @import("builtin");

const linux = if (builtin.os.tag == .linux) @import("font_finder/linux.zig") else struct {};

pub const FallbackCandidate = if (builtin.os.tag == .linux)
    linux.FallbackCandidate
else
    struct { path: []u8, face_index: i32, has_color: bool };

pub fn findFont(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .linux => linux.find(allocator, name),
        else => error.FontFinderNotSupported,
    };
}

/// Resolve a specific weight + style variant of a family by name
pub fn findFontVariant(
    allocator: std.mem.Allocator,
    family: []const u8,
    css_weight: u16,
    italic: bool,
) ![]u8 {
    return switch (builtin.os.tag) {
        .linux => linux.findVariant(allocator, family, css_weight, italic),
        else => error.FontFinderNotSupported,
    };
}

/// Returns a sorted, deduplicated list of monospace font family names.
/// Caller owns the returned slice and each string within it.
pub fn listFonts(allocator: std.mem.Allocator) ![][]u8 {
    return switch (builtin.os.tag) {
        .linux => linux.list(allocator),
        else => error.FontFinderNotSupported,
    };
}

/// Query fontconfig/system for fonts that cover a specific codepoint.
/// Returns ranked candidates; caller owns returned slice and paths within.
pub fn findFallbackFonts(
    allocator: std.mem.Allocator,
    codepoint: u21,
    prefer_color: bool,
) ![]FallbackCandidate {
    return switch (builtin.os.tag) {
        .linux => linux.findFallbackFonts(allocator, codepoint, prefer_color),
        else => allocator.alloc(FallbackCandidate, 0),
    };
}
