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

test "link_dispatch files with a line and column" {
    try expect("src/main.rs:3:22", "", .{ .file = .{ .path = "src/main.rs", .line = 3, .column = 22 } });
    try expect("/abs/a:b.zig:7", "docs", .{ .file = .{ .path = "/abs/a:b.zig", .line = 7 } });
}

test "link_dispatch file hrefs read back" {
    var href: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer href.deinit();
    try link_dispatch.write_file_href(&href.writer, "/a dir/(x)#1\\y.md", 12, 5);
    try std.testing.expectEqualStrings("/a%20dir/%28x%29%231%5Cy.md:12:5", href.written());
    try expect(href.written(), "docs", .{ .markdown = .{ .path = "/a dir/(x)#1\\y.md", .line = 12, .column = 5 } });
}

test "link_dispatch file hrefs without a line or column" {
    var href: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer href.deinit();
    try link_dispatch.write_file_href(&href.writer, "/a/b.zig", null, null);
    try link_dispatch.write_file_href(&href.writer, " /a/c.zig", 3, null);
    try std.testing.expectEqualStrings("/a/b.zig%20/a/c.zig:3", href.written());
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
