const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command");
const tp = @import("thespian");

const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;
const Selection = Buffer.Selection;

const tui = @import("tui.zig");
const Editor = @import("editor.zig").Editor;
const CurSel = @import("editor.zig").CurSel;
const bracket_search_radius = @import("editor.zig").bracket_search_radius;

pub const Pair = @TypeOf(Buffer.unicode.char_pairs[0]);

pub const Span = struct { Cursor, Cursor };

fn select_pairs(comptime pairs: []const Pair, comptime keep: fn (Pair) bool) []const Pair {
    comptime {
        var selected: []const Pair = &.{};
        for (pairs) |pair| if (keep(pair)) {
            selected = selected ++ [_]Pair{pair};
        };
        const result = selected;
        return result;
    }
}

fn is_ascii_bracket(pair: Pair) bool {
    return pair[0].len == 1 and !std.mem.eql(u8, pair[0], pair[1]);
}

fn is_nearest_candidate(pair: Pair) bool {
    const excluded = [_][]const u8{ "¿", "¡", "‚" };
    for (excluded) |open| if (std.mem.eql(u8, pair[0], open)) return false;
    return true;
}

fn is_not_ascii_bracket(pair: Pair) bool {
    return !is_ascii_bracket(pair);
}

const bracket_pairs = select_pairs(&Buffer.unicode.open_close_pairs, is_ascii_bracket);
const any_pairs = select_pairs(&Buffer.unicode.char_pairs, is_nearest_candidate);
const quote_pairs = select_pairs(any_pairs, is_not_ascii_bracket);

const padded_bracket_pairs = blk: {
    var padded: [bracket_pairs.len]Pair = undefined;
    for (bracket_pairs, &padded) |pair, *padded_pair| padded_pair.* = .{ pair[0] ++ " ", " " ++ pair[1] };
    break :blk padded;
};

fn alias(char: []const u8) []const u8 {
    const aliases = [_]struct { []const u8, []const u8 }{ .{ "b", ")" }, .{ "B", "}" }, .{ "r", "]" }, .{ "a", ">" } };
    for (aliases) |a| if (std.mem.eql(u8, char, a[0])) return a[1];
    return char;
}

pub fn pair_for(char: []const u8) Pair {
    for (Buffer.unicode.open_close_pairs) |pair|
        if (std.mem.eql(u8, char, pair[0]) or std.mem.eql(u8, char, pair[1]))
            return pair;
    return .{ char, char };
}

pub fn is_pair_char(char_: []const u8) bool {
    const char = alias(char_);
    for (any_pairs) |pair| if (std.mem.eql(u8, char, pair[0]) or std.mem.eql(u8, char, pair[1])) return true;
    return false;
}

pub fn is_opening_bracket(char: []const u8) bool {
    for (bracket_pairs) |pair| if (std.mem.eql(u8, char, pair[0])) return true;
    return false;
}

pub fn padded_delimiters(char: []const u8) Pair {
    for (bracket_pairs, padded_bracket_pairs) |pair, padded|
        if (std.mem.eql(u8, char, pair[0])) return padded;
    return pair_for(alias(char));
}

pub fn find(root: Buffer.Root, cursor: Cursor, target: []const u8, metrics: Buffer.Metrics) error{Stop}!Span {
    if (std.mem.eql(u8, target, "q")) return find_nearest(root, cursor, quote_pairs, metrics);
    if (std.mem.eql(u8, target, "s")) return find_nearest(root, cursor, any_pairs, metrics);
    const pair = pair_for(alias(target));
    return find_scope_pair(root, cursor, metrics, pair[0], pair[1]);
}

fn find_nearest(root: Buffer.Root, cursor: Cursor, pairs: []const Pair, metrics: Buffer.Metrics) error{Stop}!Span {
    var innermost: ?Span = find_enclosing_bracket(root, cursor, pairs, metrics) catch null;
    var first: ?Span = null;
    for (pairs) |pair| if (is_quote(pair)) {
        const found = find_quotes(root, cursor, metrics, pair[0]) catch continue;
        if (!found[0].right_of(cursor) and !cursor.right_of(found[1])) {
            if (innermost == null or found[0].right_of(innermost.?[0])) innermost = found;
        } else if (found[0].right_of(cursor)) {
            if (first == null or first.?[0].right_of(found[0])) first = found;
        }
    };
    if (innermost) |found| return found;

    const next_bracket = find_next_bracket(root, cursor, pairs, metrics) catch return first orelse error.Stop;
    if (first) |quotes| if (next_bracket[0].right_of(quotes[0])) return quotes;
    return next_bracket;
}

pub fn find_scope_pair(root: Buffer.Root, current: Cursor, metrics: Buffer.Metrics, opening_char: []const u8, closing_char: []const u8) error{Stop}!Span {
    if (std.mem.eql(u8, opening_char, closing_char)) return find_quotes(root, current, metrics, opening_char);
    const pairs = [_]Pair{.{ opening_char, closing_char }};
    return find_enclosing_bracket(root, current, &pairs, metrics) catch
        find_next_bracket(root, current, &pairs, metrics);
}

fn is_quote(pair: Pair) bool {
    return std.mem.eql(u8, pair[0], pair[1]);
}

fn find_quotes(root: Buffer.Root, current: Cursor, metrics: Buffer.Metrics, quote: []const u8) error{Stop}!Span {
    const open, const close = try Editor.find_quote_pair(root, current, metrics, quote);
    return .{ .{ .row = open[0], .col = open[1] }, .{ .row = close[0], .col = close[1] } };
}

fn egc_at(root: Buffer.Root, cursor: Cursor, metrics: Buffer.Metrics) []const u8 {
    const egc, _, _ = root.egc_at(cursor.row, cursor.col, metrics) catch return "";
    return egc;
}

fn match_bracket(root: Buffer.Root, bracket: Cursor, metrics: Buffer.Metrics) ?Cursor {
    const row, const col = Editor.match_bracket(root, bracket, metrics) catch return null;
    return .{ .row = row, .col = col };
}

fn find_enclosing_bracket(root: Buffer.Root, current: Cursor, pairs: []const Pair, metrics: Buffer.Metrics) error{Stop}!Span {
    std.debug.assert(pairs.len <= any_pairs.len);
    const at_current = egc_at(root, current, metrics);
    for (pairs) |pair| if (!is_quote(pair)) {
        if (std.mem.eql(u8, at_current, pair[0]))
            return .{ current, match_bracket(root, current, metrics) orelse return error.Stop };
        if (std.mem.eql(u8, at_current, pair[1]))
            return .{ match_bracket(root, current, metrics) orelse return error.Stop, current };
    };

    var depths: [any_pairs.len]usize = @splat(0);
    var cursor = current;
    var i: usize = 0;
    while (i < bracket_search_radius) : (i += 1) {
        try cursor.move_left(root, metrics);
        const egc = egc_at(root, cursor, metrics);
        for (pairs, depths[0..pairs.len]) |pair, *depth| {
            if (is_quote(pair)) continue;
            if (std.mem.eql(u8, egc, pair[1])) {
                depth.* += 1;
            } else if (std.mem.eql(u8, egc, pair[0])) {
                if (depth.* > 0) {
                    depth.* -= 1;
                } else if (match_bracket(root, cursor, metrics)) |closing| {
                    if (closing.right_of(current)) return .{ cursor, closing };
                }
            } else continue;
            break;
        }
    }
    return error.Stop;
}

fn find_next_bracket(root: Buffer.Root, current: Cursor, pairs: []const Pair, metrics: Buffer.Metrics) error{Stop}!Span {
    var cursor = current;
    var i: usize = 0;
    while (i < bracket_search_radius) : (i += 1) {
        try cursor.move_right(root, metrics);
        const egc = egc_at(root, cursor, metrics);
        for (pairs) |pair| {
            if (is_quote(pair) or !std.mem.eql(u8, egc, pair[0])) continue;
            if (match_bracket(root, cursor, metrics)) |closing| return .{ cursor, closing };
            break;
        }
    }
    return error.Stop;
}

fn is_tab_or_space(c: []const u8) bool {
    return (c[0] == ' ') or (c[0] == '\t');
}

pub fn is_blank_at(root: Buffer.Root, cursor: Cursor, metrics: Buffer.Metrics) bool {
    return cursor.test_at(root, is_tab_or_space, metrics);
}

pub fn trim_end(root: Buffer.Root, begin: Cursor, end: *Cursor, metrics: Buffer.Metrics) void {
    while (end.right_of(begin)) {
        var prev = end.*;
        prev.move_left(root, metrics) catch return;
        if (!is_blank_at(root, prev, metrics)) return;
        end.* = prev;
    }
}

fn delimiter_ranges(root: Buffer.Root, open: Cursor, close: Cursor, trim: bool, metrics: Buffer.Metrics) error{Stop}!struct { Selection, Selection } {
    var open_end = open;
    try open_end.move_right(root, metrics);
    var close_begin = close;
    var close_end = close;
    try close_end.move_right(root, metrics);
    if (trim) {
        while (close_begin.right_of(open_end) and is_blank_at(root, open_end, metrics))
            open_end.move_right(root, metrics) catch break;
        trim_end(root, open_end, &close_begin, metrics);
    }
    return .{ .{ .begin = open, .end = open_end }, .{ .begin = close_begin, .end = close_end } };
}

fn replace_range(ed: *Editor, root: Buffer.Root, cursel: *CurSel, range: Selection, text: []const u8, allocator: Allocator) error{Stop}!Buffer.Root {
    cursel.selection = range;
    const root_ = try ed.delete_selection(root, cursel, allocator);
    if (text.len == 0) return root_;
    const begin = cursel.cursor;
    const row, const col, const root_inserted = root_.insert_chars(begin.row, begin.col, text, allocator, ed.metrics) catch return error.Stop;
    ed.nudge_insert(.insert(.{ .begin = begin, .end = .{ .row = row, .col = col } }, root_, root_inserted, ed.metrics), cursel, text.len);
    return root_inserted;
}

fn replace(ed: *Editor, root: Buffer.Root, cursel: *CurSel, open: Selection, close: Selection, delimiters: Pair, allocator: Allocator) error{Stop}!Buffer.Root {
    var root_ = try replace_range(ed, root, cursel, close, delimiters[1], allocator);
    root_ = try replace_range(ed, root_, cursel, open, delimiters[0], allocator);
    cursel.cursor = open.begin;
    cursel.selection = null;
    return root_;
}

pub fn change(ed: *Editor, root: Buffer.Root, cursel: *CurSel, at: Cursor, target: []const u8, trim: bool, delimiters: Pair, allocator: Allocator) error{Stop}!Buffer.Root {
    const open, const close = try find(root, at, target, ed.metrics);
    const open_range, const close_range = try delimiter_ranges(root, open, close, trim, ed.metrics);
    return replace(ed, root, cursel, open_range, close_range, delimiters, allocator);
}

pub fn has_key_args(ctx: command.Context) bool {
    var key: []const u8 = undefined;
    return ctx.args.match(.{ tp.extract(&key), tp.more }) catch false;
}

pub fn edit(ctx: command.Context, op: anytype) command.Result {
    const mv = tui.mainview() orelse return;
    const ed = mv.get_active_editor() orelse return;
    const b = try ed.buf_for_update();
    const root = try ed.with_cursels_mut_once_arg(b.root, op, ed.allocator, ctx);
    try ed.update_buf(root, ctx.now);
    ed.clamp(ctx.now);
}

pub fn add(root: Buffer.Root, sel: Selection, left: []const u8, right: []const u8, allocator: Allocator, metrics: Buffer.Metrics) error{Stop}!struct { Buffer.Root, Selection, [2]Buffer.Nudge } {
    var begin = sel.begin;
    var end = sel.end;
    if (sel.is_reversed()) {
        end = sel.begin;
        begin = sel.end;
    }
    if (begin.row == end.row and end.col == begin.col) {
        end.move_right(root, metrics) catch {};
    }
    const right_row, const right_col, const root_right = root.insert_chars(end.row, end.col, right, allocator, metrics) catch return error.Stop;
    const left_row, const left_col, const root_ = root_right.insert_chars(begin.row, begin.col, left, allocator, metrics) catch return error.Stop;
    const nudges: [2]Buffer.Nudge = .{
        .insert(.{ .begin = end, .end = .{ .row = right_row, .col = right_col } }, root, root_right, metrics),
        .insert(.{ .begin = begin, .end = .{ .row = left_row, .col = left_col } }, root_right, root_, metrics),
    };

    var enclosed_end: Cursor = .{ .row = right_row, .col = right_col };
    if (begin.row == right_row) enclosed_end.col += left_col - begin.col;
    return .{ root_, .{ .begin = begin, .end = enclosed_end }, nudges };
}
