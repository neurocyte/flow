const std = @import("std");
const Allocator = std.mem.Allocator;
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

    pub fn qa(_: *void, _: Ctx) Result {
        try cmd("quit", .{});
    }
    pub const qa_meta: Meta = .{ .description = "qa (close all)" };

    pub fn @"q!"(_: *void, _: Ctx) Result {
        try cmd("quit_without_saving", .{});
    }
    pub const @"q!_meta": Meta = .{ .description = "q! (quit without saving)" };

    pub fn @"qa!"(_: *void, _: Ctx) Result {
        try cmd("quit_without_saving", .{});
    }
    pub const @"qa!_meta": Meta = .{ .description = "qa! (quit without saving)" };

    pub fn wq(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const wq_meta: Meta = .{ .description = "wq (write/save file and quit)" };

    pub fn @"x!"(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit_without_saving", .{} } }));
    }
    pub const @"x!_meta": Meta = .{ .description = "x! (write/save file and exit, ignoring other unsaved changes)" };

    pub fn x(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const x_meta: Meta = .{ .description = "x (write/save file and quit)" };

    pub fn wa(_: *void, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm|
            bm.save_all() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const wa_meta: Meta = .{ .description = "wa (save all)" };

    pub fn xa(_: *void, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm| {
            bm.save_all() catch |e| return tp.exit_error(e, @errorReturnTrace());
            try cmd("quit", .{});
        }
    }
    pub const xa_meta: Meta = .{ .description = "xa (write all and quit)" };

    pub fn @"xa!"(_: *void, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm| {
            bm.save_all() catch {};
            try cmd("quit_without_saving", .{});
        }
    }
    pub const @"xa!_meta": Meta = .{ .description = "xa! (write all and exit, ignoring other unsaved changes)" };

    pub fn wqa(_: *void, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm|
            bm.save_all() catch |e| return tp.exit_error(e, @errorReturnTrace());
        try cmd("quit", .{});
    }
    pub const wqa_meta: Meta = .{ .description = "wqa (write all and quit)" };

    pub fn @"wqa!"(_: *void, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm| {
            bm.save_all() catch {};
            try cmd("quit_without_saving", .{});
        }
    }
    pub const @"wqa!_meta": Meta = .{ .description = "wqa! (write all and exit, ignoring unsaved changes)" };

    pub fn rl(_: *void, _: Ctx) Result {
        try cmd("reload_file", .{});
    }
    pub const rl_meta: Meta = .{ .description = "rl (reload current file)" };

    pub fn rla(_: *void, _: Ctx) Result {
        if (tui.get_buffer_manager()) |bm|
            bm.reload_all() catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    pub const rla_meta: Meta = .{ .description = "rla (reload all files)" };

    pub fn o(_: *void, _: Ctx) Result {
        try cmd("open_file", .{});
    }
    pub const o_meta: Meta = .{ .description = "o (open file)" };

    pub fn @"wq!"(_: *void, _: Ctx) Result {
        cmd("save_file", .{}) catch {};
        try cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta": Meta = .{ .description = "wq! (write/save file and quit without saving)" };

    pub fn n(_: *void, _: Ctx) Result {
        try cmd("create_new_file", .{});
    }
    pub const n_meta: Meta = .{ .description = "n (Create new buffer/tab)" };

    pub fn bn(_: *void, _: Ctx) Result {
        try cmd("next_tab", .{});
    }
    pub const bn_meta: Meta = .{ .description = "bn (Next buffer/tab)" };

    pub fn bp(_: *void, _: Ctx) Result {
        try cmd("previous_tab", .{});
    }
    pub const bp_meta: Meta = .{ .description = "bp (Previous buffer/tab)" };

    pub fn bc(_: *void, _: Ctx) Result {
        try cmd("delete_buffer", .{});
    }
    pub const bc_meta: Meta = .{ .description = "bc (Close buffer/tab)" };

    pub fn @"bc!"(_: *void, _: Ctx) Result {
        try cmd("close_file_without_saving", .{});
    }
    pub const @"bc!_meta": Meta = .{ .description = "bc! (Close buffer/tab, ignoring changes)" };

    pub fn @"bco!"(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        if (tui.get_buffer_manager()) |bm| {
            if (mv.get_active_buffer()) |buffer| try bm.delete_others(buffer);
        }
    }
    pub const @"bco!_meta": Meta = .{ .description = "bco! (Close other buffers/tabs, discarding changes)" };

    pub fn bco(_: *void, _: Ctx) Result {
        const logger = log.logger("helix-mode");
        defer logger.deinit();
        const mv = tui.mainview() orelse return;
        const bm = tui.get_buffer_manager() orelse return;
        if (mv.get_active_buffer()) |buffer| {
            const remaining = try bm.close_others(buffer);
            if (remaining > 0) {
                logger.print("{} unsaved buffer(s) remaining", .{remaining});
                try cmd("next_tab", .{});
            }
        }
    }
    pub const bco_meta: Meta = .{ .description = "bco (Close other buffers/tabs)" };

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

    pub fn move_next_long_word_start(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const_repeat(root, move_cursor_long_word_right, ctx) catch {};
        ed.clamp();
    }
    pub const move_next_long_word_start_meta: Meta = .{ .description = "Move next long word start", .arguments = &.{.integer} };

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

    pub fn move_prev_long_word_start(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const_repeat(root, move_cursor_long_word_left, ctx) catch {};
        ed.clamp();
    }
    pub const move_prev_long_word_start_meta: Meta = .{ .description = "Move previous long word start", .arguments = &.{.integer} };

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

    pub fn move_next_long_word_end(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const_repeat(root, move_cursor_long_word_right_end, ctx) catch {};
        ed.clamp();
    }
    pub const move_next_long_word_end_meta: Meta = .{ .description = "Move next long word end", .arguments = &.{.integer} };

    pub fn cut_forward_internal_inclusive(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const b = try ed.buf_for_update();
        tui.clipboard_start_group();
        const root = try ed.cut_to(move_noop, b.root);
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

    pub fn select_to_char_left_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &select_cursel_to_char_left_helix);
    }
    pub const select_to_char_left_helix_meta: Meta = .{ .description = "Select to char left" };

    pub fn select_till_char_left_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &select_cursel_till_char_left_helix);
    }
    pub const select_till_char_left_helix_meta: Meta = .{ .description = "Select until char left" };

    pub fn extend_to_char_left_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &extend_cursel_to_char_left_helix);
    }
    pub const extend_to_char_left_helix_meta: Meta = .{ .description = "Extend Selection to char left" };

    pub fn extend_till_char_left_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &extend_cursel_till_char_left_helix);
    }
    pub const extend_till_char_left_helix_meta: Meta = .{ .description = "Extend Selection until char left" };

    pub fn select_till_char_right_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &select_cursel_till_char_right_helix);
    }
    pub const select_till_char_right_helix_meta: Meta = .{ .description = "Select until char right" };

    pub fn select_to_char_right_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &select_cursel_to_char_right_helix);
    }
    pub const select_to_char_right_helix_meta: Meta = .{ .description = "Select to char right" };

    pub fn extend_till_char_right_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &extend_cursel_till_char_right_helix);
    }
    pub const extend_till_char_right_helix_meta: Meta = .{ .description = "Extend Selection until char right" };

    pub fn extend_to_char_right_helix(_: *void, ctx: Ctx) Result {
        try to_char_helix(ctx, &extend_cursel_to_char_right_helix);
    }
    pub const extend_to_char_right_helix_meta: Meta = .{ .description = "Extend Selection to char right" };

    pub fn copy_helix(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        tui.clipboard_start_group();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| if (cursel.selection) |sel|
            tui.clipboard_add_chunk(try Editor.copy_selection(root, sel, tui.clipboard_allocator(), ed.metrics));

        ed.logger.print("copy: {d} selections", .{ed.cursels.items.len});
    }
    pub const copy_helix_meta: Meta = .{ .description = "Copy selection to clipboard (helix)" };

    pub fn paste_after(_: *void, ctx: Ctx) Result {
        try paste_helix(ctx, insert_after);
    }
    pub const paste_after_meta: Meta = .{ .description = "Paste from clipboard after selection" };

    pub fn replace_selections_with_clipboard(_: *void, ctx: Ctx) Result {
        try paste_helix(ctx, insert_replace_selection);
    }
    pub const replace_selections_with_clipboard_meta: Meta = .{ .description = "Replace selection from clipboard" };

    pub fn paste_clipboard_before(_: *void, ctx: Ctx) Result {
        try paste_helix(ctx, insert_before);
    }
    pub const paste_clipboard_before_meta: Meta = .{ .description = "Paste from clipboard before selection" };

    pub fn replace_with_character_helix(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        var root = ed.buf_root() catch return;
        root = try ed.with_cursels_mut_once_arg(root, replace_cursel_with_character, ed.allocator, ctx);
        try ed.update_buf(root);
        ed.clamp();
        ed.need_render();
    }
    pub const replace_with_character_helix_meta: Meta = .{ .description = "Replace with character" };
};

fn to_char_helix(ctx: command.Context, move: Editor.cursel_operator_mut_once_arg) command.Result {
    const mv = tui.mainview() orelse return;
    const ed = mv.get_active_editor() orelse return;
    const root = ed.buf_root() catch return;
    try ed.with_cursels_const_once_arg(root, move, ctx);
    ed.clamp();
}

fn select_cursel_to_char_left_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    var begin = cursel.*.cursor;
    move_cursor_to_char_left_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    // Character found, selecting
    Editor.move_cursor_right(root, &begin, metrics) catch {
        //At end of file, it's ok
    };
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn extend_cursel_to_char_left_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    const begin = if (cursel.*.selection) |sel| sel.end else cursel.*.cursor;
    move_cursor_to_char_left_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    //Character found, selecting
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    if (sel.empty())
        sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn select_cursel_till_char_left_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    var begin = cursel.*.cursor;
    move_cursor_till_char_left_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    // Character found, selecting
    Editor.move_cursor_right(root, &begin, metrics) catch {
        //At end of file, it's ok
    };
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn extend_cursel_till_char_left_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    const begin = if (cursel.*.selection) |sel| sel.end else cursel.*.cursor;
    move_cursor_till_char_left_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    //Character found, selecting
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    if (sel.empty())
        sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn select_cursel_till_char_right_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    const begin = cursel.*.cursor;
    move_cursor_to_char_right_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    //Character found, selecting
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn extend_cursel_till_char_right_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    const begin = cursel.*.cursor;
    move_cursor_to_char_right_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    //Character found, selecting
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    if (sel.empty())
        sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn select_cursel_to_char_right_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    const begin = cursel.*.cursor;
    move_cursor_to_char_right_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    //Character found, selecting
    Editor.move_cursor_right(root, &moving_cursor, metrics) catch {
        // We might be at end of file
    };
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn extend_cursel_to_char_right_helix(root: Buffer.Root, cursel: *CurSel, ctx: command.Context, metrics: Buffer.Metrics) error{Stop}!void {
    var moving_cursor: Cursor = cursel.*.cursor;
    const begin = cursel.*.cursor;
    move_cursor_to_char_right_beyond_eol(root, &moving_cursor, metrics, ctx) catch return;

    //Character found, selecting
    Editor.move_cursor_right(root, &moving_cursor, metrics) catch {
        // We might be at end of file
    };
    moving_cursor.target = moving_cursor.col;
    const sel = try cursel.enable_selection(root, metrics);
    if (sel.empty())
        sel.begin = begin;
    sel.end = moving_cursor;
    cursel.cursor = moving_cursor;
}

fn move_cursor_find_egc_beyond_eol(root: Buffer.Root, cursor: *Cursor, ctx: command.Context, metrics: Buffer.Metrics, move: find_char_function) error{Stop}!void {
    move(root, cursor, metrics, ctx);
}

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

fn replace_cursel_with_character(ed: *Editor, root: Buffer.Root, cursel: *CurSel, allocator: Allocator, ctx: command.Context) error{Stop}!Buffer.Root {
    var egc: []const u8 = undefined;
    if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
        return error.Stop;
    const no_selection = try select_char_if_no_selection(cursel, root, ed.metrics);
    var begin: Cursor = undefined;
    var sel_length: usize = 1;
    if (cursel.selection) |*sel| {
        sel.normalize();
        begin = sel.*.begin;
        _ = root.get_range(sel.*, null, null, &sel_length, ed.metrics) catch return error.Stop;
    }
    const total_length = sel_length * egc.len;
    var sfa = std.heap.stackFallback(4096, ed.allocator);
    const sfa_allocator = sfa.get();
    const replacement = sfa_allocator.alloc(u8, total_length) catch return error.Stop;
    defer sfa_allocator.free(replacement);
    for (0..sel_length) |i|
        @memcpy(replacement[i * egc.len .. (i + 1) * egc.len], egc);

    const root_ = insert_replace_selection(ed, root, cursel, replacement, allocator) catch return error.Stop;

    if (no_selection) {
        try cursel.cursor.move_left(root, ed.metrics);
        cursel.disable_selection(root, ed.metrics);
    } else {
        cursel.selection = Selection{ .begin = begin, .end = cursel.cursor };
    }
    return root_;
}

fn move_noop(_: Buffer.Root, _: *Cursor, _: Buffer.Metrics) error{Stop}!void {}

fn move_cursor_word_right_end_helix(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    try Editor.move_cursor_right(root, cursor, metrics);
    Editor.move_cursor_right_until(root, cursor, Editor.is_word_boundary_right_vim, metrics);
    try cursor.move_right(root, metrics);
}

fn move_cursor_to_char_left_beyond_eol(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics, ctx: command.Context) error{Stop}!void {
    var egc: []const u8 = undefined;
    if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
        return error.Stop;
    var test_cursor = cursor.*;
    try test_cursor.move_left(root, metrics);
    while (true) {
        const curr_egc, _, _ = root.egc_at(test_cursor.row, test_cursor.col, metrics) catch return error.Stop;
        if (std.mem.eql(u8, curr_egc, egc)) {
            cursor.row = test_cursor.row;
            cursor.col = test_cursor.col;
            cursor.target = cursor.col;
            return;
        }
        test_cursor.move_left(root, metrics) catch return error.Stop;
    }
}

fn move_cursor_to_char_right_beyond_eol(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics, ctx: command.Context) error{Stop}!void {
    var egc: []const u8 = undefined;
    if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
        return error.Stop;
    var test_cursor = cursor.*;
    while (true) {
        const curr_egc, _, _ = root.egc_at(test_cursor.row, test_cursor.col, metrics) catch return error.Stop;
        if (std.mem.eql(u8, curr_egc, egc)) {
            cursor.row = test_cursor.row;
            cursor.col = test_cursor.col;
            cursor.target = cursor.col;
            return;
        }
        test_cursor.move_right(root, metrics) catch return error.Stop;
    }
}

fn move_cursor_till_char_left_beyond_eol(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics, ctx: command.Context) error{Stop}!void {
    var egc: []const u8 = undefined;
    if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
        return error.Stop;
    var test_cursor = cursor;
    try test_cursor.move_left(root, metrics);
    var prev = test_cursor.*;
    try prev.move_left(root, metrics);
    while (true) {
        const prev_egc, _, _ = root.egc_at(prev.row, prev.col, metrics) catch return error.Stop;
        if (std.mem.eql(u8, prev_egc, egc)) {
            cursor.row = test_cursor.row;
            cursor.col = test_cursor.col;
            cursor.target = cursor.col;
            return;
        }
        test_cursor.move_left(root, metrics) catch return error.Stop;
        prev.move_left(root, metrics) catch return error.Stop;
    }
}

fn move_cursor_till_char_right_beyond_eol(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics, ctx: command.Context) error{Stop}!void {
    var egc: []const u8 = undefined;
    if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
        return error.Stop;
    var test_cursor = cursor;
    try test_cursor.move_right(root, metrics);
    var next = test_cursor.*;
    try next.move_right(root, metrics);
    while (true) {
        const next_egc, _, _ = root.egc_at(next.row, next.col, metrics) catch return error.Stop;
        if (std.mem.eql(u8, next_egc, egc)) {
            cursor.row = test_cursor.row;
            cursor.col = test_cursor.col;
            cursor.target = cursor.col;
            return;
        }
        test_cursor.move_right(root, metrics) catch return error.Stop;
        next.move_right(root, metrics) catch return error.Stop;
    }
}

fn insert_before(editor: *Editor, root: Buffer.Root, cursel: *CurSel, text: []const u8, allocator: Allocator) !Buffer.Root {
    var root_: Buffer.Root = root;
    const cursor: *Cursor = &cursel.cursor;

    cursel.check_selection(root, editor.metrics);
    if (cursel.selection) |sel_| {
        var sel = sel_;
        sel.normalize();
        cursor.move_to(root, sel.begin.row, sel.begin.col, editor.metrics) catch {};

        if (text[text.len - 1] == '\n') {
            cursor.move_begin();
        }
    } else if (text[text.len - 1] == '\n') {
        cursor.move_begin();
    }

    cursel.disable_selection_normal();
    const begin = cursel.cursor;
    cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, text, allocator, editor.metrics);
    cursor.target = cursor.col;
    cursel.selection = Selection{ .begin = begin, .end = cursor.* };
    editor.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, text.len);
    return root_;
}

fn insert_replace_selection(editor: *Editor, root: Buffer.Root, cursel: *CurSel, text: []const u8, allocator: Allocator) !Buffer.Root {
    // replaces the selection, if no selection, replaces the current
    // character and sets the selection to the replacement text
    var root_: Buffer.Root = root;
    cursel.check_selection(root, editor.metrics);

    if (cursel.selection == null) {
        // Select current character to replace it
        Editor.with_selection_const(root, move_noop, cursel, editor.metrics) catch {};
    }
    root_ = editor.delete_selection(root, cursel, allocator) catch root;

    const cursor = &cursel.cursor;
    const begin = cursel.cursor;
    cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, text, allocator, editor.metrics);
    cursor.target = cursor.col;
    cursel.selection = Selection{ .begin = begin, .end = cursor.* };
    editor.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, text.len);
    return root_;
}

fn insert_after(editor: *Editor, root: Buffer.Root, cursel: *CurSel, text: []const u8, allocator: Allocator) !Buffer.Root {
    var root_: Buffer.Root = root;
    const cursor = &cursel.cursor;
    cursel.check_selection(root, editor.metrics);
    if (text[text.len - 1] == '\n') {
        move_cursor_carriage_return(root, cursel.*, cursor, editor.metrics) catch {};
    } else {
        if (cursel.selection) |sel_| {
            var sel = sel_;
            sel.normalize();
            cursor.move_to(root, sel.end.row, sel.end.col, editor.metrics) catch {};
        } else {
            cursor.move_right(root_, editor.metrics) catch {};
        }
    }

    cursel.disable_selection_normal();
    const begin = cursel.cursor;
    cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, text, allocator, editor.metrics);
    cursor.target = cursor.col;
    cursel.selection = Selection{ .begin = begin, .end = cursor.* };
    editor.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, text.len);
    return root_;
}

fn is_not_whitespace_or_eol(c: []const u8) bool {
    return !Editor.is_whitespace_or_eol(c);
}

fn is_whitespace_or_eol_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    return cursor.test_at(root, Editor.is_whitespace_or_eol, metrics);
}

fn is_non_whitespace_or_eol_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    return cursor.test_at(root, is_not_whitespace_or_eol, metrics);
}

fn is_long_word_boundary_left(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    if (cursor.test_at(root, Editor.is_whitespace, metrics)) return false;
    var next = cursor.*;
    next.move_left(root, metrics) catch return true;

    const next_is_whitespace = Editor.is_whitespace_at_cursor(root, &next, metrics);
    if (next_is_whitespace) return true;

    const curr_is_non_word = is_non_whitespace_or_eol_at_cursor(root, cursor, metrics);
    const next_is_non_word = is_non_whitespace_or_eol_at_cursor(root, &next, metrics);
    return curr_is_non_word != next_is_non_word;
}

fn move_cursor_long_word_left(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    try Editor.move_cursor_left(root, cursor, metrics);

    // Consume " "
    while (Editor.is_whitespace_at_cursor(root, cursor, metrics)) {
        try Editor.move_cursor_left(root, cursor, metrics);
    }

    var next = cursor.*;
    next.move_left(root, metrics) catch return;
    var next_next = next;
    next_next.move_left(root, metrics) catch return;

    const cur = next.test_at(root, is_not_whitespace_or_eol, metrics);
    const nxt = next_next.test_at(root, is_not_whitespace_or_eol, metrics);
    if (cur != nxt) {
        try Editor.move_cursor_left(root, cursor, metrics);
        return;
    } else {
        try move_cursor_long_word_left(root, cursor, metrics);
    }
}

fn is_word_boundary_right(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    if (Editor.is_whitespace_at_cursor(root, cursor, metrics)) return false;
    var next = cursor.*;
    next.move_right(root, metrics) catch return true;

    const next_is_whitespace = Editor.is_whitespace_at_cursor(root, &next, metrics);
    if (next_is_whitespace) return true;

    const curr_is_non_word = is_non_whitespace_or_eol_at_cursor(root, cursor, metrics);
    const next_is_non_word = is_non_whitespace_or_eol_at_cursor(root, &next, metrics);
    return curr_is_non_word != next_is_non_word;
}

fn move_cursor_long_word_right(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    try cursor.move_right(root, metrics);
    Editor.move_cursor_right_until(root, cursor, is_long_word_boundary_left, metrics);
}

fn is_long_word_boundary_right(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    if (Editor.is_whitespace_at_cursor(root, cursor, metrics)) return false;
    var next = cursor.*;
    next.move_right(root, metrics) catch return true;

    const next_is_whitespace = Editor.is_whitespace_at_cursor(root, &next, metrics);
    if (next_is_whitespace) return true;

    const curr_is_non_word = is_non_whitespace_or_eol_at_cursor(root, cursor, metrics);
    const next_is_non_word = is_non_whitespace_or_eol_at_cursor(root, &next, metrics);
    return curr_is_non_word != next_is_non_word;
}

fn move_cursor_long_word_right_end(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    // try Editor.move_cursor_right(root, cursor, metrics);
    Editor.move_cursor_right_until(root, cursor, is_long_word_boundary_right, metrics);
    try cursor.move_right(root, metrics);
}

const pasting_function = @TypeOf(insert_before);
const find_char_function = @TypeOf(move_cursor_to_char_left_beyond_eol);

fn paste_helix(ctx: command.Context, do_paste: pasting_function) command.Result {
    const mv = tui.mainview() orelse return;
    const ed = mv.get_active_editor() orelse return;
    var text_: []const u8 = undefined;

    const clipboard: []const tui.ClipboardEntry = if (ctx.args.buf.len > 0 and try ctx.args.match(.{tp.extract(&text_)}))
        &[_]tui.ClipboardEntry{.{ .text = text_ }}
    else
        tui.clipboard_get_group(0);

    const b = try ed.buf_for_update();
    var root = b.root;

    // Chunks from clipboard are paired to selections
    // If more selections than chunks in the clipboard, the exceding selections
    // use the last chunk in the clipboard

    var bytes: usize = 0;
    for (ed.cursels.items, 0..) |*cursel_, idx| if (cursel_.*) |*cursel| {
        if (idx < clipboard.len) {
            root = try do_paste(ed, root, cursel, clipboard[idx].text, b.allocator);
            bytes += clipboard[idx].text.len;
        } else {
            bytes += clipboard[clipboard.len - 1].text.len;
            root = try do_paste(ed, root, cursel, clipboard[clipboard.len - 1].text, b.allocator);
        }
    };
    ed.logger.print("paste: {d} bytes", .{bytes});

    try ed.update_buf(root);
    ed.clamp();
    ed.need_render();
}

fn move_cursor_carriage_return(root: Buffer.Root, cursel: CurSel, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
    if (is_cursel_from_extend_line_below(cursel)) {
        //The cursor is already beginning next line
        return;
    }
    if (!Editor.is_eol_right(root, cursor, metrics)) {
        try Editor.move_cursor_end(root, cursor, metrics);
    }
    try Editor.move_cursor_right(root, cursor, metrics);
}

fn select_char_if_no_selection(cursel: *CurSel, root: Buffer.Root, metrics: Buffer.Metrics) !bool {
    if (cursel.selection) |*sel_| {
        const sel: *Selection = sel_;
        if (sel.*.empty()) {
            sel.*.begin = .{ .row = cursel.cursor.row, .col = cursel.cursor.col + 1, .target = cursel.cursor.target + 1 };
            return true;
        }
        return false;
    } else {
        const sel = try cursel.enable_selection(root, metrics);
        sel.begin = .{ .row = cursel.cursor.row, .col = cursel.cursor.col + 1, .target = cursel.cursor.target + 1 };
        return true;
    }
}

fn is_cursel_from_extend_line_below(cursel: CurSel) bool {
    if (cursel.selection) |sel_| {
        var sel = sel_;
        sel.normalize();
        return sel.end.row != sel.begin.row and sel.end.col == 0;
    }
    return false;
}

const private = @This();
// exports for unittests
pub const test_internal = struct {
    pub const move_cursor_long_word_right = private.move_cursor_long_word_right;
    pub const move_cursor_long_word_left = private.move_cursor_long_word_left;
    pub const move_cursor_long_word_right_end = private.move_cursor_long_word_right_end;
    pub const move_cursor_word_left_helix = private.move_cursor_word_left_helix;
    pub const move_cursor_word_right_end_helix = private.move_cursor_word_right_end_helix;
    pub const move_cursor_to_char_left_beyond_eol = private.move_cursor_to_char_left_beyond_eol;
    pub const move_cursor_to_char_right_beyond_eol = private.move_cursor_to_char_right_beyond_eol;
    pub const move_cursor_till_char_left_beyond_eol = private.move_cursor_till_char_left_beyond_eol;
    pub const move_cursor_till_char_right_beyond_eol = private.move_cursor_till_char_right_beyond_eol;
    pub const insert_before = private.insert_before;
    pub const insert_replace_selection = private.insert_replace_selection;
    pub const insert_after = private.insert_after;
};
