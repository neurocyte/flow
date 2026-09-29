const std = @import("std");
const Buffer = @import("Buffer");

const Editor = @import("tui").exports.editor.Editor;
const jump_labels = @import("tui").exports.jump_labels;
const Label = jump_labels.Label;

const a = std.testing.allocator;

// default of the jump_label_alphabet option
const alphabet = "abcdefghijklmnopqrstuvwxyz";

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

var eol_mode: Buffer.EolMode = .lf;
var sanitized: bool = false;

fn compute(doc: []const u8, cursor: Buffer.Cursor, view: Buffer.View, alphabet_: []const u8) ![]Label {
    const now = std.Io.Clock.real.now(std.testing.io);
    const buffer = try Buffer.create(a, now);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized), now);
    return Editor.test_internal.compute_jump_labels(buffer.root, cursor, view, alphabet_, metrics(), a);
}

fn expectLabels(labels: []const Label, expected: []const Label) !void {
    try std.testing.expectEqual(expected.len, labels.len);
    for (labels, expected) |actual, want| {
        try std.testing.expectEqual(want.pos.row, actual.pos.row);
        try std.testing.expectEqual(want.pos.col, actual.pos.col);
        try std.testing.expectEqualSlices(u8, &want.text, &actual.text);
    }
}

const words =
    \\hello world foo bar
    \\baz qux quux corge
;

const Case = struct {
    doc: []const u8,
    cursor: Buffer.Cursor,
    view: Buffer.View,
    alphabet: []const u8 = alphabet,
    expected: []const Label,
};

const all: Buffer.View = .{ .row = 0, .col = 0, .rows = 2, .cols = 80 };

// words after the cursor come first, then words before it, alternating
const labels_from_start = [_]Label{
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "aa".* }, // world
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "ab".* }, // foo
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "ac".* }, // bar
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "ad".* }, // baz
    .{ .pos = .{ .row = 1, .col = 4 }, .text = "ae".* }, // qux
    .{ .pos = .{ .row = 1, .col = 8 }, .text = "af".* }, // quux
    .{ .pos = .{ .row = 1, .col = 13 }, .text = "ag".* }, // corge
};

const labels_from_foo = [_]Label{
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "aa".* }, // bar, after the cursor word
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "ab".* }, // world, before the cursor word
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "ac".* }, // baz
    .{ .pos = .{ .row = 0, .col = 0 }, .text = "ad".* }, // hello
    .{ .pos = .{ .row = 1, .col = 4 }, .text = "ae".* }, // qux
    .{ .pos = .{ .row = 1, .col = 8 }, .text = "af".* }, // quux
    .{ .pos = .{ .row = 1, .col = 13 }, .text = "ag".* }, // corge
};

// the word under the cursor is not labeled
const labels_in_bar = [_]Label{
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "ab".* },
    .{ .pos = .{ .row = 1, .col = 4 }, .text = "ac".* },
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "ad".* },
    .{ .pos = .{ .row = 1, .col = 8 }, .text = "ae".* },
    .{ .pos = .{ .row = 0, .col = 0 }, .text = "af".* },
    .{ .pos = .{ .row = 1, .col = 13 }, .text = "ag".* },
};

// a cursor that is not on a word labels all words
const labels_from_space = [_]Label{
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "ab".* },
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "ac".* },
    .{ .pos = .{ .row = 0, .col = 0 }, .text = "ad".* },
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "ae".* },
    .{ .pos = .{ .row = 1, .col = 4 }, .text = "af".* },
    .{ .pos = .{ .row = 1, .col = 8 }, .text = "ag".* },
    .{ .pos = .{ .row = 1, .col = 13 }, .text = "ah".* },
};

// only the visible rows and columns are labeled
const labels_one_row = [_]Label{
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "ab".* },
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "ac".* },
};

const labels_narrow_view = [_]Label{
    .{ .pos = .{ .row = 1, .col = 8 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "ab".* },
    .{ .pos = .{ .row = 1, .col = 13 }, .text = "ac".* },
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "ad".* },
};

// words of a single character and runs of non word characters are skipped
const labels_short_words = [_]Label{
    .{ .pos = .{ .row = 0, .col = 7 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 2 }, .text = "ab".* },
};

const labels_lines_and_operators = [_]Label{
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 0 }, .text = "ab".* },
};

const labels_digits_and_underscore = [_]Label{
    .{ .pos = .{ .row = 0, .col = 9 }, .text = "aa".* },
};

// the number of labels is limited to alphabet.len * alphabet.len
const labels_two_letter_alphabet = [_]Label{
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "ab".* },
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "ba".* },
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "bb".* },
};

// the alphabet is filtered and duplicates are removed
const labels_sanitized_alphabet = [_]Label{
    .{ .pos = .{ .row = 0, .col = 6 }, .text = "aa".* },
    .{ .pos = .{ .row = 0, .col = 12 }, .text = "ab".* },
    .{ .pos = .{ .row = 0, .col = 16 }, .text = "ac".* },
    .{ .pos = .{ .row = 1, .col = 0 }, .text = "ba".* },
    .{ .pos = .{ .row = 1, .col = 4 }, .text = "bb".* },
    .{ .pos = .{ .row = 1, .col = 8 }, .text = "bc".* },
    .{ .pos = .{ .row = 1, .col = 13 }, .text = "ca".* },
};

test "jump labels: candidates and ordering" {
    const cases = [_]Case{
        .{ .doc = words, .cursor = .{ .row = 0, .col = 0 }, .view = all, .expected = &labels_from_start },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 12 }, .view = all, .expected = &labels_from_foo },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 17 }, .view = all, .expected = &labels_in_bar },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 11 }, .view = all, .expected = &labels_from_space },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 0 }, .view = .{ .row = 0, .col = 0, .rows = 1, .cols = 80 }, .expected = &labels_one_row },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 19 }, .view = .{ .row = 0, .col = 8, .rows = 2, .cols = 10 }, .expected = &labels_narrow_view },
        .{ .doc = "a bb c dd", .cursor = .{ .row = 0, .col = 5 }, .view = all, .expected = &labels_short_words },
        .{ .doc = "ab\ncd\na == b", .cursor = .{ .row = 0, .col = 2 }, .view = all, .expected = &labels_lines_and_operators },
        .{ .doc = "foo_bar1 baz2", .cursor = .{ .row = 0, .col = 0 }, .view = all, .expected = &labels_digits_and_underscore },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 0 }, .view = all, .alphabet = "ab", .expected = &labels_two_letter_alphabet },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 0 }, .view = all, .alphabet = "ab\tb\xffc ", .expected = &labels_sanitized_alphabet },
        // no words or no alphabet means no labels
        .{ .doc = "", .cursor = .{ .row = 0, .col = 0 }, .view = all, .expected = &.{} },
        .{ .doc = words, .cursor = .{ .row = 0, .col = 0 }, .view = all, .alphabet = "", .expected = &.{} },
    };
    for (cases) |case| {
        const labels = try compute(case.doc, case.cursor, case.view, case.alphabet);
        defer a.free(labels);
        try expectLabels(labels, case.expected);
    }
}

test "jump labels: label text" {
    try std.testing.expectEqualSlices(u8, "aa", &jump_labels.label_text("ab", 0));
    try std.testing.expectEqualSlices(u8, "ab", &jump_labels.label_text("ab", 1));
    try std.testing.expectEqualSlices(u8, "ba", &jump_labels.label_text("ab", 2));
    try std.testing.expectEqualSlices(u8, "bb", &jump_labels.label_text("ab", 3));
    try std.testing.expectEqualSlices(u8, "ag", &jump_labels.label_text("abcdefg", 6));
}

test "jump labels: alphabet sanitizing" {
    const s = try jump_labels.sanitize_alphabet(a, "a b\tb\xffc ");
    defer a.free(s);
    try std.testing.expectEqualSlices(u8, "abc", s);

    const d = try jump_labels.sanitize_alphabet(a, alphabet);
    defer a.free(d);
    try std.testing.expectEqualSlices(u8, alphabet, d);

    const none = try jump_labels.sanitize_alphabet(a, "");
    defer a.free(none);
    try std.testing.expectEqual(0, none.len);
}

fn expectPending(action: jump_labels.State.Action, first: u8) !void {
    switch (action) {
        .pending => |actual| try std.testing.expectEqual(first, actual),
        else => return error.TestExpectedPendingAction,
    }
}

fn expectCancel(action: jump_labels.State.Action) !void {
    switch (action) {
        .cancel => {},
        else => return error.TestExpectedCancelAction,
    }
}

fn expectSelect(action: jump_labels.State.Action, row_: usize, col: usize, text: []const u8) !void {
    switch (action) {
        .select => |label| {
            try std.testing.expectEqual(row_, label.pos.row);
            try std.testing.expectEqual(col, label.pos.col);
            try std.testing.expectEqualSlices(u8, text, &label.text);
        },
        else => return error.TestExpectedSelectAction,
    }
}

test "jump labels: input" {
    const labels = [_]Label{
        .{ .pos = .{ .row = 0, .col = 6 }, .text = "aa".* },
        .{ .pos = .{ .row = 0, .col = 12 }, .text = "ab".* },
        .{ .pos = .{ .row = 1, .col = 0 }, .text = "ba".* },
    };

    var state = jump_labels.State.init(&labels);
    try expectCancel(state.input('z'));
    try expectCancel(state.input('B'));

    state = jump_labels.State.init(&labels);
    try expectPending(state.input('a'), 'a');
    try expectSelect(state.input('b'), 0, 12, "ab");

    state = jump_labels.State.init(&labels);
    try expectPending(state.input('b'), 'b');
    try expectSelect(state.input('a'), 1, 0, "ba");

    state = jump_labels.State.init(&labels);
    try expectPending(state.input('a'), 'a');
    try expectCancel(state.input('z'));

    state = jump_labels.State.init(&labels);
    try expectPending(state.input('a'), 'a');
    try std.testing.expectEqual(@as(?u8, 'a'), state.first);
}
