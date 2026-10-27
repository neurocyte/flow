const std = @import("std");
const link_dispatch = @import("tui").exports.link_dispatch;

const Action = link_dispatch.Action;

fn expect(href: []const u8, base_dir: []const u8, expected: Action) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const action = try link_dispatch.classify(arena.allocator(), href, .{ .base_dir = base_dir });
    try std.testing.expectEqualDeep(expected, action);
}

test "link_dispatch anchor in the same document" {
    try expect("#usage", "docs", .{ .anchor = "usage" });
}

test "link_dispatch web and other schemes are urls" {
    try expect("https://ziglang.org/", "docs", .{ .url = "https://ziglang.org/" });
    try expect("mailto:a@b.org", "docs", .{ .url = "mailto:a@b.org" });
}

test "link_dispatch relative markdown file with an anchor" {
    try expect("other.md", "docs", .{ .markdown = .{ .path = "docs/other.md" } });
    try expect("../README.markdown#intro", "docs/sub", .{ .markdown = .{ .path = "docs/README.markdown", .anchor = "intro" } });
    try expect("my%20notes.md", "", .{ .markdown = .{ .path = "my notes.md" } });
}

test "link_dispatch files with a line" {
    try expect("src/main.zig#L10", "", .{ .file = .{ .path = "src/main.zig", .line = 10 } });
    try expect("src/main.zig#L10-L20", "", .{ .file = .{ .path = "src/main.zig", .line = 10 } });
    try expect("src/main.zig:42", "", .{ .file = .{ .path = "src/main.zig", .line = 42 } });
    try expect("build.zig", "docs", .{ .file = .{ .path = "docs/build.zig" } });
}

test "link_dispatch absolute paths and file uris ignore the base directory" {
    try expect("/abs/a.zig", "docs", .{ .file = .{ .path = "/abs/a.zig" } });
    try expect("file:///tmp/x.md", "docs", .{ .markdown = .{ .path = "/tmp/x.md" } });
    try expect("file://host/tmp/y.zig#L3", "docs", .{ .file = .{ .path = "/tmp/y.zig", .line = 3 } });
}

test "link_dispatch terminal links are web links in the tui only" {
    try std.testing.expect(link_dispatch.terminal_link("https://ziglang.org/", .tui));
    try std.testing.expect(link_dispatch.terminal_link("HTTP://example.com", .tui));
    try std.testing.expect(!link_dispatch.terminal_link("https://ziglang.org/", .gui));
    try std.testing.expect(!link_dispatch.terminal_link("mailto:a@b.org", .tui));
    try std.testing.expect(!link_dispatch.terminal_link("file:///tmp/x.md", .tui));
    try std.testing.expect(!link_dispatch.terminal_link("other.md", .tui));
}
