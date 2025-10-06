const std = @import("std");
const Buffer = @import("Buffer");
const Cursor = @import("Cursor");
const helix = @import("helix");

// error: import of file outside module path
// const helix = @import("../src/tui/mode/helix.zig");

const ArrayList = std.ArrayList;
const a = std.testing.allocator;

fn metrics() Buffer.Metrics {
    return .{
        .ctx = undefined,
        .egc_length = struct {
            fn f(_: Buffer.Metrics, _: []const u8, colcount: *c_int, _: usize) usize {
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

fn the_pos(buffer: Buffer, pos: u8) Cursor {
    return buffer.root.byte_offset_to_line_and_col(pos, metrics(), .lf);
}

test "word_movement" {
    const W = helix.move_cursor_long_word_right;
    const B = helix.move_cursor_long_word_left;
    const E = helix.move_cursor_long_word_right_end;
    const doc: []const u8 =
        \\a small $% Test.here,   with.things()to demo
        \\ with surrounding.space    a bb  AA   a small and long
        \\
        \\  
        \\nospace.
        \\   try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 0 }, buffer.root.byte_offset_to_line_and_col(0, test_metrics(), eol_mode));
        \\
        \\
        \\  $$%.  []{{}. dart de
        \\da
    ;

    //44 55 0 8 0
    // TODO: test selections. Parity with Helix

    var eol_mode: Buffer.EolMode = .lf;
    var sanitized: bool = false;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc, &eol_mode, &sanitized));
    const root: Buffer.Root = buffer.root;
    var c = Cursor{ .row = 0, .col = 0, .target = 0 };
    const t = the_pos;

    try std.testing.expectEqual(Buffer.Cursor{ .row = 0, .col = 0 }, buffer.root.byte_offset_to_line_and_col(0, metrics(), eol_mode));
    try std.testing.expectEqual(try buffer.root.line_width(0, metrics()), 44);
    try std.testing.expectEqual(try buffer.root.line_width(1, metrics()), 55);
    try E(root, &c, metrics());
    try std.testing.expectEqual(c, t(buffer.*, 1));
    try B(root, &c, metrics());
    try std.testing.expectEqual(c, t(buffer.*, 0));
    try W(root, &c, metrics());
    try std.testing.expectEqual(c, t(buffer.*, 2));
    try B(root, &c, metrics());
    try std.testing.expectEqual(c, t(buffer.*, 1));
}
