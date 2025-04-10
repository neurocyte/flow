const std = @import("std");
const log = @import("log");
const tp = @import("thespian");
const location_history = @import("location_history");
const command = @import("command");
const cmd = command.executeName;

const tui = @import("../tui.zig");
const Editor = @import("../editor.zig").Editor;
const CurSel = @import("../editor.zig").CurSel;
const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;
const Selection = Buffer.Selection;

var commands: Commands = undefined;

pub fn init() !void {
    var v: void = {};
    try commands.init(&v);
}

pub fn deinit() void {
    commands.deinit();
}

const Commands = command.Collection(cmds_);
const cmds_ = struct {
    pub const Target = void;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn w(_: *void, _: Ctx) Result {
        try cmd("save_file", .{});
    }
    pub const w_meta: Meta = .{ .description = "w (write/save file)" };

    pub fn q(_: *void, _: Ctx) Result {
        try cmd("quit", .{});
    }
    pub const q_meta: Meta = .{ .description = "q (quit)" };

    pub fn @"q!"(_: *void, _: Ctx) Result {
        try cmd("quit_without_saving", .{});
    }
    pub const @"q!_meta": Meta = .{ .description = "q! (quit without saving)" };

    pub fn wq(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const wq_meta: Meta = .{ .description = "wq (write/save file and quit)" };

    pub fn o(_: *void, _: Ctx) Result {
        try cmd("open_file", .{});
    }
    pub const o_meta: Meta = .{ .description = "o (open file)" };

    pub fn @"wq!"(_: *void, _: Ctx) Result {
        cmd("save_file", .{}) catch {};
        try cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta": Meta = .{ .description = "wq! (write/save file and quit without saving)" };

    pub fn save_selection(_: *void, _: Ctx) Result {
        const logger = log.logger("helix-mode");
        defer logger.deinit();
        logger.print("saved location", .{});
        const mv = tui.mainview() orelse return;
        const file_path = mv.get_active_file_path() orelse return;
        const primary = (mv.get_active_editor() orelse return).get_primary();
        const sel: ?location_history.Selection = if (primary.selection) |sel| .{
            .begin = .{ .row = sel.begin.row, .col = sel.begin.col },
            .end = .{ .row = sel.end.row, .col = sel.end.col },
        } else null;
        mv.location_history_.update(file_path, .{
            .row = primary.cursor.row + 1,
            .col = primary.cursor.col + 1,
        }, sel);
    }
    pub const save_selection_meta: Meta = .{ .description = "Save current selection to location history" };

    pub fn extend_line_below(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                const sel = cursel.enable_selection_normal();
                sel.normalize();

                try Editor.move_cursor_begin(root, &sel.begin, ed.metrics);
                try Editor.move_cursor_end(root, &sel.end, ed.metrics);
                try Editor.move_cursor_right(root, &sel.end, ed.metrics);
                cursel.cursor = sel.end;
            };
        }

        ed.clamp();
    }
    pub const extend_line_below_meta: Meta = .{ .arguments = &.{.integer}, .description = "Select current line, if already selected, extend to next line" };

    pub fn move_next_word_start(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const_repeat(root, Editor.move_cursor_word_right_vim, ctx) catch {};
        ed.clamp();
    }
    pub const move_next_word_start_meta: Meta = .{ .description = "Move next word start", .arguments = &.{.integer} };

    pub fn move_prev_word_start(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const_repeat(root, move_cursor_word_left_helix, ctx) catch {};
        ed.clamp();
    }
    pub const move_prev_word_start_meta: Meta = .{ .description = "Move previous word start", .arguments = &.{.integer} };

    pub fn move_next_word_end(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const_repeat(root, move_cursor_word_right_end_helix, ctx) catch {};
        ed.clamp();
    }
    pub const move_next_word_end_meta: Meta = .{ .description = "Move next word end", .arguments = &.{.integer} };

    pub fn cut_forward_internal_inclusive(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const b = try ed.buf_for_update();
        const text, const root = try ed.cut_to(move_noop, b.root);
        ed.set_clipboard_internal(text);
        try ed.update_buf(root);
        ed.clamp();
    }
    pub const cut_forward_internal_inclusive_meta: Meta = .{ .description = "Cut next character to internal clipboard (inclusive)" };

    pub fn select_right_helix(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                const sel = try cursel.enable_selection(root, ed.metrics);

                // handling left to right transition
                const sel_begin: i32 = @intCast(sel.begin.col);
                const sel_end: i32 = @intCast(sel.end.col);
                if ((sel_begin - sel_end) == 1 and sel.begin.row == sel.end.row) {
                    try Editor.move_cursor_right(root, &sel.end, ed.metrics);
                    sel.begin.col -= 1;
                }

                try Editor.move_cursor_right(root, &sel.end, ed.metrics);
                cursel.cursor = sel.end;
                cursel.check_selection(root, ed.metrics);
            };
        }
        ed.clamp();
    }
    pub const select_right_helix_meta: Meta = .{ .description = "Select right", .arguments = &.{.integer} };

    pub fn select_left_helix(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                if (cursel.selection == null) {
                    cursel.selection = Selection.from_cursor(&cursel.cursor);
                    try cursel.selection.?.begin.move_right(root, ed.metrics);
                }
                if (cursel.selection) |*sel| {
                    try Editor.move_cursor_left(root, &sel.end, ed.metrics);
                    cursel.cursor = sel.end;

                    if (sel.begin.col == sel.end.col and sel.begin.row == sel.end.row) {
                        try sel.begin.move_right(root, ed.metrics);
                        try Editor.move_cursor_left(root, &sel.end, ed.metrics);
                        cursel.cursor = sel.end;
                    }
                }

                cursel.check_selection(root, ed.metrics);
            };
        }
        ed.clamp();
    }
    pub const select_left_helix_meta: Meta = .{ .description = "Select left", .arguments = &.{.integer} };

    pub fn select_to_char_right_helix(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const sel = try cursel.enable_selection(root, ed.metrics);
            try Editor.move_cursor_to_char_right(root, &sel.end, ctx, ed.metrics);
            try Editor.move_cursor_right(root, &sel.end, ed.metrics);
            cursel.cursor = sel.end;
            cursel.check_selection(root, ed.metrics);
        };
        ed.clamp();
    }
    pub const select_to_char_right_helix_meta: Meta = .{ .description = "Move to char right" };

    pub fn copy_helix(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;
        var first = true;
        var text = std.ArrayList(u8).init(ed.allocator);

        if (ed.get_primary().selection) |sel| if (sel.begin.col == 0 and sel.end.row > sel.begin.row) try text.appendSlice("\n");

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |sel| {
                const copy_text = try Editor.copy_selection(root, sel, ed.allocator, ed.metrics);
                if (first) {
                    first = false;
                } else {
                    try text.appendSlice("\n");
                }
                try text.appendSlice(copy_text);
            }
        };
        if (text.items.len > 0) {
            if (text.items.len > 100) {
                ed.logger.print("copy:{s}...", .{std.fmt.fmtSliceEscapeLower(text.items[0..100])});
            } else {
                ed.logger.print("copy:{s}", .{std.fmt.fmtSliceEscapeLower(text.items)});
            }
            ed.set_clipboard_internal(text.items);
        }
    }
    pub const copy_helix_meta: Meta = .{ .description = "Copy selection to clipboard (helix)" };

    pub fn paste_after(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;

        var text: []const u8 = undefined;
        if (!(ctx.args.buf.len > 0 and try ctx.args.match(.{tp.extract(&text)}))) {
            if (ed.clipboard) |text_| text = text_ else return;
        }

        ed.logger.print("paste: {d} bytes", .{text.len});
        const b = try ed.buf_for_update();
        var root = b.root;

        if (std.mem.eql(u8, text[text.len - 1 ..], "\n")) text = text[0 .. text.len - 1];

        if (std.mem.indexOfScalar(u8, text, '\n')) |_| {
            if (ed.cursels.items.len == 1) {
                const primary = ed.get_primary();
                root = try insert_line(ed, root, primary, text, b.allocator);
            } else {
                for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    root = try insert_line(ed, root, cursel, text, b.allocator);
                };
            }
        } else {
            if (ed.cursels.items.len == 1) {
                const primary = ed.get_primary();
                root = try insert(ed, root, primary, text, b.allocator);
            } else {
                for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    root = try insert(ed, root, cursel, text, b.allocator);
                };
            }
        }

        try ed.update_buf(root);
        ed.clamp();
        ed.need_render();
    }
    pub const paste_after_meta: Meta = .{ .description = "Paste from clipboard after selection" };
};

fn move_cursor_word_left_helix(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    try Editor.move_cursor_left(root, cursor, metrics);

    // Consume " "
    while (Editor.is_whitespace_at_cursor(root, cursor, metrics)) {
        try Editor.move_cursor_left(root, cursor, metrics);
    }

    var next = cursor.*;
    next.move_left(root, metrics) catch return;
    var next_next = next;
    next_next.move_left(root, metrics) catch return;

    const cur = next.test_at(root, Editor.is_not_word_char, metrics);
    const nxt = next_next.test_at(root, Editor.is_not_word_char, metrics);
    if (cur != nxt) {
        try Editor.move_cursor_left(root, cursor, metrics);
        return;
    } else {
        try move_cursor_word_left_helix(root, cursor, metrics);
    }
}

fn move_noop(_: Buffer.Root, _: *Cursor, _: Buffer.Metrics) error{Stop}!void {}

fn move_cursor_word_right_end_helix(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    try Editor.move_cursor_right(root, cursor, metrics);
    Editor.move_cursor_right_until(root, cursor, Editor.is_word_boundary_right_vim, metrics);
    try cursor.move_right(root, metrics);
}

fn insert(ed: *Editor, root: Buffer.Root, cursel: *CurSel, s: []const u8, allocator: std.mem.Allocator) !Buffer.Root {
    var root_ = root;
    const cursor = &cursel.cursor;
    if (cursel.selection == null) try cursor.move_right(root_, ed.metrics);
    const begin = cursel.cursor;
    cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, s, allocator, ed.metrics);
    cursor.target = cursor.col;
    ed.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, s.len);
    cursel.selection = Selection{ .begin = begin, .end = cursor.* };
    return root_;
}

fn insert_line(ed: *Editor, root: Buffer.Root, cursel: *CurSel, s: []const u8, allocator: std.mem.Allocator) !Buffer.Root {
    var root_ = root;
    const cursor = &cursel.cursor;

    cursel.disable_selection(root, ed.metrics);
    cursel.cursor.move_end(root, ed.metrics);

    var begin = cursel.cursor;
    try begin.move_right(root, ed.metrics);

    cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, s, allocator, ed.metrics);
    cursor.target = cursor.col;
    cursel.selection = Selection{ .begin = begin, .end = cursor.* };
    return root_;
}
