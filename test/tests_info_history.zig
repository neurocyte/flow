const std = @import("std");
const History = @import("tui").exports.info_history;

const a = std.testing.allocator;

fn all(_: void, _: History.View) bool {
    return true;
}

fn preview(path: []const u8, row: usize) History.Entry {
    return .{ .view = .{ .preview = path }, .row = row };
}

fn expect_entry(expected: History.Entry, actual: ?History.Entry) !void {
    const entry = actual orelse return error.TestExpectedEntry;
    defer entry.deinit(a);
    try std.testing.expectEqualDeep(expected, entry);
}

test "info_history back and forward" {
    var h: History = .init(a);
    defer h.deinit();
    try h.record(preview("a.md", 1));
    try h.record(preview("b.md", 2));
    try expect_entry(preview("b.md", 2), try h.jump(.back, preview("c.md", 3), {}, all));
    try expect_entry(preview("a.md", 1), try h.jump(.back, preview("b.md", 2), {}, all));
    try std.testing.expectEqual(null, try h.jump(.back, preview("a.md", 1), {}, all));
    try expect_entry(preview("b.md", 2), try h.jump(.forward, preview("a.md", 1), {}, all));
    try expect_entry(preview("c.md", 3), try h.jump(.forward, preview("b.md", 2), {}, all));
    try std.testing.expectEqual(null, try h.jump(.forward, preview("c.md", 3), {}, all));
}

test "info_history record clears forward" {
    var h: History = .init(a);
    defer h.deinit();
    try h.record(preview("a.md", 1));
    try expect_entry(preview("a.md", 1), try h.jump(.back, preview("b.md", 0), {}, all));
    try h.record(preview("a.md", 5));
    try std.testing.expectEqual(null, try h.jump(.forward, preview("c.md", 0), {}, all));
    try expect_entry(preview("a.md", 5), try h.jump(.back, preview("c.md", 0), {}, all));
}

test "info_history saves the scrolled position when leaving" {
    var h: History = .init(a);
    defer h.deinit();
    try h.record(preview("a.md", 1));
    try expect_entry(preview("a.md", 1), try h.jump(.back, preview("b.md", 7), {}, all));
    try expect_entry(preview("b.md", 7), try h.jump(.forward, preview("a.md", 40), {}, all));
    try expect_entry(preview("a.md", 40), try h.jump(.back, preview("b.md", 7), {}, all));
}

test "info_history collapses repeats" {
    var h: History = .init(a);
    defer h.deinit();
    try h.record(preview("a.md", 1));
    try h.record(preview("a.md", 1));
    try h.record(preview("a.md", 1));
    try std.testing.expectEqual(1, h.back.items.len);
    try std.testing.expectEqual(null, try h.jump(.back, preview("a.md", 1), {}, all));
}

test "info_history cap" {
    var h: History = .init(a);
    defer h.deinit();
    for (0..History.max_entries + 10) |i| try h.record(preview("a.md", i));
    try std.testing.expectEqual(History.max_entries, h.back.items.len);
    try std.testing.expectEqual(10, h.back.items[0].row);
}

fn not_panel_2(_: void, view: History.View) bool {
    return !(view == .panel and view.panel == 2);
}

test "info_history panels" {
    var h: History = .init(a);
    defer h.deinit();
    try h.record(.{ .view = .{ .panel = 1 }, .row = 1 });
    try h.record(.{ .view = .{ .panel = 2 }, .row = 2 });
    try h.record(.{ .view = .{ .panel = 2 }, .row = 3 });
    try expect_entry(.{ .view = .{ .panel = 1 }, .row = 1 }, try h.jump(.back, preview("a.md", 0), {}, not_panel_2));
    h.remove_panel(1);
    try std.testing.expectEqual(null, try h.jump(.forward, preview("a.md", 0), {}, all));

    try h.record(.{ .view = .{ .panel = 1 } });
    try h.record(preview("a.md", 0));
    try h.record(.{ .view = .{ .panel = 2 } });
    h.remove_panels();
    try std.testing.expectEqual(1, h.back.items.len);
}

test "info_history state round trip" {
    var h: History = .init(a);
    defer h.deinit();
    try h.record(preview("a.md", 1));
    try h.record(.{ .view = .{ .panel = 1 }, .row = 9 });
    try h.record(.{ .view = .{ .preview = "b.md" }, .row = 2, .offset = -3 });
    try expect_entry(.{ .view = .{ .preview = "b.md" }, .row = 2, .offset = -3 }, try h.jump(.back, preview("c.md", 4), {}, all));

    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try h.write_state(&buf.writer);

    var r: History = .init(a);
    defer r.deinit();
    var iter: []const u8 = buf.written();
    try r.extract_state(&iter);
    try std.testing.expectEqual(0, iter.len);
    try expect_entry(preview("a.md", 1), try r.jump(.back, preview("b.md", 2), {}, all));
    try expect_entry(preview("b.md", 2), try r.jump(.forward, preview("a.md", 1), {}, all));
    try expect_entry(preview("c.md", 4), try r.jump(.forward, preview("b.md", 2), {}, all));
}
