const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = @import("Buffer").Cursor;
const View = @import("Buffer").View;

const Editor = @import("tui").exports.editor.Editor;
const JumpLabel = Editor.JumpLabel;

const a = std.testing.allocator;

fn metrics() Buffer.Metrics {
    return .{
        .ctx = undefined,
        .egc_length = struct {
            fn f(_: Buffer.Metrics, _: []const u8, colcount: *usize, _: usize) usize {
                colcount.* = 1;
                return 1;
            }
        }.f,
        .egc_chunk_width = struct {
            fn f(_: Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                return chunk_.len;
            }
        }.f,
        .egc_last = struct {
            fn f(_: Buffer.Metrics, _: []const u8) []const u8 {
                @panic("not implemented");
            }
        }.f,
        .tab_width = 8,
    };
}

fn free_labels(labels: ?[]const JumpLabel) void {
    if (labels) |l| {
        a.free(l);
    }
}

var eol_mode: Buffer.EolMode = .lf;
var sanitized: bool = false;

// Simple multi-word document for testing
const simple_doc: []const u8 =
    \\hello world foo bar
    \\baz qux quux corge
;

test "compute_jump_labels_basic" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(simple_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    // Cursor at row 0, col 0 ("hello"), view covers all
    const cursor = Cursor{ .row = 0, .col = 0, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 2, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    // Should have labels (cursor word "hello" is skipped, rest get labels)
    try std.testing.expect(labels != null);
    const l = labels.?;

    // "hello" at (0,0) is under cursor and should be skipped.
    // Words: world(0,6), foo(0,12), bar(0,16), baz(1,0), qux(1,4), quux(1,8), corge(1,13)
    // Bidirectional: after cursor first, then before. Since cursor is at start,
    // all words are "after", so order is: world, foo, bar, baz, qux, quux, corge
    try std.testing.expectEqual(7, l.len);

    // First label should be "aa" (first in alphabet)
    try std.testing.expectEqualSlices(u8, "aa", &l[0].label);
    // It should be the word "world" at (0,6) — first word after cursor
    try std.testing.expectEqual(0, l[0].row);
    try std.testing.expectEqual(6, l[0].col);

    // Second label "ab"
    try std.testing.expectEqualSlices(u8, "ab", &l[1].label);
    // "foo" at (0,12)
    try std.testing.expectEqual(0, l[1].row);
    try std.testing.expectEqual(12, l[1].col);
}

test "compute_jump_labels_cursor_in_middle" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(simple_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    // Cursor at "foo" (row 0, col 12)
    const cursor = Cursor{ .row = 0, .col = 12, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 2, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    try std.testing.expect(labels != null);
    const l = labels.?;

    // "foo" at (0,12) is under cursor, skipped.
    // Words after cursor: bar(0,16), baz(1,0), qux(1,4), quux(1,8), corge(1,13)
    // Words before cursor: hello(0,0), world(0,6)
    // Before reversed (closest first): world(0,6), hello(0,0)
    // Alternating: bar, world, baz, hello, qux, quux, corge
    try std.testing.expectEqual(7, l.len);

    // First label "aa" = bar (first after cursor)
    try std.testing.expectEqual(0, l[0].row);
    try std.testing.expectEqual(16, l[0].col);

    // Second label "ab" = world (first before cursor, closest)
    try std.testing.expectEqual(0, l[1].row);
    try std.testing.expectEqual(6, l[1].col);

    // Third label "ac" = baz (second after)
    try std.testing.expectEqual(1, l[2].row);
    try std.testing.expectEqual(0, l[2].col);

    // Fourth label "ad" = hello (second before)
    try std.testing.expectEqual(0, l[3].row);
    try std.testing.expectEqual(0, l[3].col);
}

test "compute_jump_labels_empty_document" {
    const empty_doc: []const u8 = "";
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(empty_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    const cursor = Cursor{ .row = 0, .col = 0, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 24, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    // No words, no labels
    try std.testing.expect(labels == null);
}

test "compute_jump_labels_single_char_words_skipped" {
    // Single-char words should be skipped (need at least 2 chars)
    const single_doc: []const u8 = "a b c hello world";
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(single_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    // Cursor at col 6 ("hello")
    const cursor = Cursor{ .row = 0, .col = 6, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 1, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    try std.testing.expect(labels != null);
    const l = labels.?;

    // "a", "b", "c" are single-char words — skipped
    // "hello" is under cursor — skipped
    // Only "world" at col 12 should get a label
    try std.testing.expectEqual(1, l.len);
    try std.testing.expectEqual(0, l[0].row);
    try std.testing.expectEqual(12, l[0].col);
    try std.testing.expectEqualSlices(u8, "aa", &l[0].label);
}

test "compute_jump_labels_view_restricts_visible_area" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(simple_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    // View only shows row 0 (rows=1), so second line words are not visible
    const cursor = Cursor{ .row = 0, .col = 0, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 1, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    try std.testing.expect(labels != null);
    const l = labels.?;

    // Only row 0 words (excluding cursor): world, foo, bar
    try std.testing.expectEqual(3, l.len);
    for (l) |label| {
        try std.testing.expectEqual(0, label.row);
    }
}

test "compute_jump_labels_label_assignment_sequence" {
    // Verify labels are assigned sequentially: aa, ab, ac, ...
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(simple_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    const cursor = Cursor{ .row = 0, .col = 0, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 2, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    try std.testing.expect(labels != null);
    const l = labels.?;

    const alphabet = Editor.jump_label_alphabet;
    for (l, 0..) |label, i| {
        const expected_first = alphabet[i / alphabet.len];
        const expected_second = alphabet[i % alphabet.len];
        try std.testing.expectEqual(expected_first, label.label[0]);
        try std.testing.expectEqual(expected_second, label.label[1]);
    }
}

test "compute_jump_labels_only_cursor_word" {
    // If only one word and cursor is on it, no labels
    const one_word_doc: []const u8 = "hello";
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(one_word_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    const cursor = Cursor{ .row = 0, .col = 0, .target = 0 };
    const view = View{ .row = 0, .col = 0, .rows = 1, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    try std.testing.expect(labels == null);
}

test "compute_jump_labels_view_col_offset" {
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(simple_doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;

    // View starts at col 10. The scan begins at col 10 on each row, so words
    // starting before col 10 are never visited. "foo" at (0,12) is under cursor.
    // Remaining visible words: bar(0,16) and corge(1,13).
    const cursor = Cursor{ .row = 0, .col = 12, .target = 0 };
    const view = View{ .row = 0, .col = 10, .rows = 2, .cols = 80 };

    const labels = Editor.compute_jump_labels_static(root, cursor, view, metrics(), a);
    defer free_labels(labels);

    try std.testing.expect(labels != null);
    const l = labels.?;

    try std.testing.expectEqual(2, l.len);
    // bar(0,16) is after cursor, corge(1,13) is also after — both "after" in order
    try std.testing.expectEqual(0, l[0].row);
    try std.testing.expectEqual(16, l[0].col);
    try std.testing.expectEqual(1, l[1].row);
    try std.testing.expectEqual(13, l[1].col);
}
