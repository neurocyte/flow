const std = @import("std");
const command = @import("command");
const cmd = command.executeName;

const tui = @import("../tui.zig");

const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;
const CurSel = @import("../editor.zig").CurSel;
const Editor = @import("../editor.zig").Editor;
const bracket_search_radius = @import("../editor.zig").bracket_search_radius;

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

    pub fn w(_: *void, ctx: Ctx) Result {
        try cmd("save_file", ctx);
    }
    pub const w_meta: Meta = .{ .description = "w (write file)" };

    pub fn q(_: *void, ctx: Ctx) Result {
        try cmd("quit", ctx);
    }
    pub const q_meta: Meta = .{ .description = "q (quit)" };

    pub fn @"q!"(_: *void, ctx: Ctx) Result {
        try cmd("quit_without_saving", ctx);
    }
    pub const @"q!_meta": Meta = .{ .description = "q! (quit without saving)" };

    pub fn @"qa!"(_: *void, ctx: Ctx) Result {
        try cmd("quit_without_saving", ctx);
    }
    pub const @"qa!_meta": Meta = .{ .description = "qa! (quit without saving anything)" };

    pub fn wq(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const wq_meta: Meta = .{ .description = "wq (write file and quit)" };

    pub fn @"wq!"(_: *void, ctx: Ctx) Result {
        cmd("save_file", ctx) catch {};
        try cmd("quit_without_saving", .empty_from(ctx));
    }
    pub const @"wq!_meta": Meta = .{ .description = "wq! (write file and quit without saving)" };

    pub fn @"e!"(_: *void, ctx: Ctx) Result {
        try cmd("reload_file", ctx);
    }
    pub const @"e!_meta": Meta = .{ .description = "e! (force reload current file)" };

    pub fn bd(_: *void, ctx: Ctx) Result {
        try cmd("close_file", ctx);
    }
    pub const bd_meta: Meta = .{ .description = "bd (Close file)" };

    pub fn bw(_: *void, ctx: Ctx) Result {
        try cmd("delete_buffer", ctx);
    }
    pub const bw_meta: Meta = .{ .description = "bw (Delete buffer)" };

    pub fn bnext(_: *void, ctx: Ctx) Result {
        try cmd("next_tab", ctx);
    }
    pub const bnext_meta: Meta = .{ .description = "bnext (Next buffer/tab)" };

    pub fn bprevious(_: *void, ctx: Ctx) Result {
        try cmd("next_tab", ctx);
    }
    pub const bprevious_meta: Meta = .{ .description = "bprevious (Previous buffer/tab)" };

    pub fn ls(_: *void, ctx: Ctx) Result {
        try cmd("switch_buffers", ctx);
    }
    pub const ls_meta: Meta = .{ .description = "ls (List/switch buffers)" };

    pub fn move_begin_or_add_integer_argument_zero(_: *void, ctx: Ctx) Result {
        return if (@import("keybind").current_integer_argument()) |_|
            command.executeName("add_integer_argument_digit", .fmt(.{0}))
        else
            command.executeName("move_begin", .empty_from(ctx));
    }
    pub const move_begin_or_add_integer_argument_zero_meta: Meta = .{ .description = "Move cursor to beginning of line (vim)" };

    pub fn enter_mode_at_next_char(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const enter_mode_at_next_char_meta: Meta = .{ .description = "Move forward one char and change mode" };

    pub fn enter_mode_on_newline_down(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const enter_mode_on_newline_down_meta: Meta = .{ .description = "Insert a newline and change mode" };

    pub fn enter_mode_on_newline_up(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }
    pub const enter_mode_on_newline_up_meta: Meta = .{ .description = "Insert a newline above the current line and change mode" };

    pub fn enter_mode_at_line_begin(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const enter_mode_at_line_begin_meta: Meta = .{ .description = "Goto line begin and change mode" };

    pub fn enter_mode_at_line_end(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }
    pub const enter_mode_at_line_end_meta: Meta = .{ .description = "Goto line end and change mode" };

    pub fn copy_line(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }
    pub const copy_line_meta: Meta = .{ .description = "Copies the current line" };

    pub fn select_inside_word(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_word_textobject, ed.metrics);
    }
    pub const select_inside_word_meta: Meta = .{ .description = "Select inside word" };

    pub fn select_around_word(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_word_textobject, ed.metrics);
    }
    pub const select_around_word_meta: Meta = .{ .description = "Select around word" };

    pub fn select_inside_parentheses(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_parentheses_textobject, ed.metrics);
    }
    pub const select_inside_parentheses_meta: Meta = .{ .description = "Select inside ()" };

    pub fn select_around_parentheses(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_parentheses_textobject, ed.metrics);
    }
    pub const select_around_parentheses_meta: Meta = .{ .description = "Select around ()" };

    pub fn select_inside_square_brackets(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_square_brackets_textobject, ed.metrics);
    }
    pub const select_inside_square_brackets_meta: Meta = .{ .description = "Select inside []" };

    pub fn select_around_square_brackets(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_square_brackets_textobject, ed.metrics);
    }
    pub const select_around_square_brackets_meta: Meta = .{ .description = "Select around []" };

    pub fn select_inside_angle_brackets(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_angle_brackets_textobject, ed.metrics);
    }
    pub const select_inside_angle_brackets_meta: Meta = .{ .description = "Select inside <>" };

    pub fn select_around_angle_brackets(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_angle_brackets_textobject, ed.metrics);
    }
    pub const select_around_angle_brackets_meta: Meta = .{ .description = "Select around <>" };

    pub fn select_inside_braces(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_braces_textobject, ed.metrics);
    }
    pub const select_inside_braces_meta: Meta = .{ .description = "Select inside {}" };

    pub fn select_around_braces(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_braces_textobject, ed.metrics);
    }
    pub const select_around_braces_meta: Meta = .{ .description = "Select around {}" };

    pub fn select_inside_single_quotes(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_single_quotes_textobject, ed.metrics);
    }
    pub const select_inside_single_quotes_meta: Meta = .{ .description = "Select inside ''" };

    pub fn select_around_single_quotes(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_single_quotes_textobject, ed.metrics);
    }
    pub const select_around_single_quotes_meta: Meta = .{ .description = "Select around ''" };

    pub fn select_inside_double_quotes(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_double_quotes_textobject, ed.metrics);
    }
    pub const select_inside_double_quotes_meta: Meta = .{ .description = "Select inside \"\"" };

    pub fn select_around_double_quotes(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_double_quotes_textobject, ed.metrics);
    }
    pub const select_around_double_quotes_meta: Meta = .{ .description = "Select around \"\"" };

    pub fn select_inside_backticks(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_backticks_textobject, ed.metrics);
    }
    pub const select_inside_backticks_meta: Meta = .{ .description = "Select inside ``" };

    pub fn select_around_backticks(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_backticks_textobject, ed.metrics);
    }
    pub const select_around_backticks_meta: Meta = .{ .description = "Select around ``" };

    pub fn cut_inside_word(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_word_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_word_meta: Meta = .{ .description = "Cut inside word" };

    pub fn cut_around_word(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_word_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_word_meta: Meta = .{ .description = "Cut around word" };

    pub fn cut_inside_parentheses(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_parentheses_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_parentheses_meta: Meta = .{ .description = "Cut inside ()" };

    pub fn cut_around_parentheses(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_parentheses_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_parentheses_meta: Meta = .{ .description = "Cut around ()" };

    pub fn cut_inside_square_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_square_brackets_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_square_brackets_meta: Meta = .{ .description = "Cut inside []" };

    pub fn cut_around_square_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_square_brackets_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_square_brackets_meta: Meta = .{ .description = "Cut around []" };

    pub fn cut_inside_angle_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_angle_brackets_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_angle_brackets_meta: Meta = .{ .description = "Cut inside <>" };

    pub fn cut_around_angle_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_angle_brackets_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_angle_brackets_meta: Meta = .{ .description = "Cut around <>" };

    pub fn cut_inside_braces(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_braces_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_braces_meta: Meta = .{ .description = "Cut inside {}" };

    pub fn cut_around_braces(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_braces_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_braces_meta: Meta = .{ .description = "Cut around {}" };

    pub fn cut_inside_single_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_single_quotes_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_single_quotes_meta: Meta = .{ .description = "Cut inside ''" };

    pub fn cut_around_single_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_single_quotes_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_single_quotes_meta: Meta = .{ .description = "Cut around ''" };

    pub fn cut_inside_double_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_double_quotes_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_double_quotes_meta: Meta = .{ .description = "Cut inside \"\"" };

    pub fn cut_around_double_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_double_quotes_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_double_quotes_meta: Meta = .{ .description = "Cut around \"\"" };

    pub fn cut_inside_backticks(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_backticks_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_inside_backticks_meta: Meta = .{ .description = "Cut inside ``" };

    pub fn cut_around_backticks(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_backticks_textobject, ed.metrics);
        try ed.cut_internal_vim(ctx);
    }
    pub const cut_around_backticks_meta: Meta = .{ .description = "Cut around ``" };

    pub fn copy_inside_word(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_word_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_word_meta: Meta = .{ .description = "Copy inside word" };

    pub fn copy_around_word(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_word_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_word_meta: Meta = .{ .description = "Copy around word" };

    pub fn copy_inside_parentheses(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_parentheses_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_parentheses_meta: Meta = .{ .description = "Copy inside ()" };

    pub fn copy_around_parentheses(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_parentheses_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_parentheses_meta: Meta = .{ .description = "Copy around ()" };

    pub fn copy_inside_square_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_square_brackets_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_square_brackets_meta: Meta = .{ .description = "Copy inside []" };

    pub fn copy_around_square_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_square_brackets_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_square_brackets_meta: Meta = .{ .description = "Copy around []" };

    pub fn copy_inside_angle_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_angle_brackets_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_angle_brackets_meta: Meta = .{ .description = "Copy inside <>" };

    pub fn copy_around_angle_brackets(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_angle_brackets_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_angle_brackets_meta: Meta = .{ .description = "Copy around <>" };

    pub fn copy_inside_braces(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_braces_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_braces_meta: Meta = .{ .description = "Copy inside {}" };

    pub fn copy_around_braces(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_braces_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_braces_meta: Meta = .{ .description = "Copy around {}" };

    pub fn copy_inside_single_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_single_quotes_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_single_quotes_meta: Meta = .{ .description = "Copy inside ''" };

    pub fn copy_around_single_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_single_quotes_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_single_quotes_meta: Meta = .{ .description = "Copy around ''" };

    pub fn copy_inside_double_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_double_quotes_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_double_quotes_meta: Meta = .{ .description = "Copy inside \"\"" };

    pub fn copy_around_double_quotes(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_double_quotes_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_double_quotes_meta: Meta = .{ .description = "Copy around \"\"" };

    pub fn copy_inside_backticks(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_inside_backticks_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_inside_backticks_meta: Meta = .{ .description = "Copy inside ``" };

    pub fn copy_around_backticks(_: *void, ctx: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = ed.buf_root() catch return;

        try ed.with_cursels_const(root, select_around_backticks_textobject, ed.metrics);
        try ed.copy_internal_vim(ctx);
    }
    pub const copy_around_backticks_meta: Meta = .{ .description = "Copy around ``" };
};

fn is_tab_or_space(c: []const u8) bool {
    return (c[0] == ' ') or (c[0] == '\t');
}

fn is_tab_or_space_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    return cursor.test_at(root, is_tab_or_space, metrics);
}
fn is_not_tab_or_space_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
    return !cursor.test_at(root, is_tab_or_space, metrics);
}

fn select_inside_word_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_word_textobject(root, cursel, metrics, .inside);
}

fn select_around_word_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_word_textobject(root, cursel, metrics, .around);
}

fn select_word_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics, scope: enum { inside, around }) !void {
    var prev = cursel.cursor;
    var next = cursel.cursor;

    if (cursel.cursor.test_at(root, Editor.is_non_word_char, metrics)) {
        if (cursel.cursor.test_at(root, Editor.is_whitespace_or_eol, metrics)) {
            Editor.move_cursor_left_until(root, &prev, Editor.is_non_whitespace_at_cursor, metrics);
            Editor.move_cursor_right_until(root, &next, Editor.is_non_whitespace_at_cursor, metrics);
        } else {
            Editor.move_cursor_left_until(root, &prev, Editor.is_whitespace_or_eol_at_cursor, metrics);
            Editor.move_cursor_right_until(root, &next, Editor.is_whitespace_or_eol_at_cursor, metrics);
        }
        prev.move_right(root, metrics) catch {};
    } else {
        Editor.move_cursor_left_until(root, &prev, Editor.is_word_boundary_left_vim, metrics);
        Editor.move_cursor_right_until(root, &next, Editor.is_word_boundary_right_vim, metrics);
        next.move_right(root, metrics) catch {};
    }

    if (scope == .around) {
        const inside_prev = prev;
        const inside_next = next;

        if (next.test_at(root, is_tab_or_space, metrics)) {
            Editor.move_cursor_right_until(root, &next, is_not_tab_or_space_at_cursor, metrics);
        } else {
            next = inside_next;
            prev.move_left(root, metrics) catch {};
            if (prev.test_at(root, is_tab_or_space, metrics)) {
                Editor.move_cursor_left_until(root, &prev, is_not_tab_or_space_at_cursor, metrics);
                prev.move_right(root, metrics) catch {};
            } else {
                prev = inside_prev;
            }
        }
    }

    const sel = cursel.enable_selection(root, metrics);
    sel.begin = prev;
    sel.end = next;
    cursel.*.cursor = next;
}

fn select_inside_parentheses_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "(", ")", .inside);
}

fn select_around_parentheses_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "(", ")", .around);
}

fn select_inside_square_brackets_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "[", "]", .inside);
}

fn select_around_square_brackets_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "[", "]", .around);
}

fn select_inside_angle_brackets_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "<", ">", .inside);
}

fn select_around_angle_brackets_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "<", ">", .around);
}

fn select_inside_braces_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "{", "}", .inside);
}

fn select_around_braces_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "{", "}", .around);
}

fn select_inside_single_quotes_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "'", "'", .inside);
}

fn select_around_single_quotes_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "'", "'", .around);
}

fn select_inside_double_quotes_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "\"", "\"", .inside);
}

fn select_around_double_quotes_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "\"", "\"", .around);
}

fn select_inside_backticks_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "`", "`", .inside);
}

fn select_around_backticks_textobject(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
    return try select_scope_textobject(root, cursel, metrics, "`", "`", .around);
}

fn select_scope_textobject(
    root: Buffer.Root,
    cursel: *CurSel,
    metrics: Buffer.Metrics,
    opening_char: []const u8,
    closing_char: []const u8,
    scope: enum { inside, around },
) !void {
    const current = cursel.cursor;
    var prev = cursel.cursor;
    var next = cursel.cursor;

    if (std.mem.eql(u8, opening_char, closing_char)) {
        const opening_pos, const closing_pos =
            try Editor.find_quote_pair(root, current, metrics, opening_char);

        prev.row = opening_pos[0];
        prev.col = opening_pos[1];
        next.row = closing_pos[0];
        next.col = closing_pos[1];
    } else {
        const bracket_egc, _, _ = root.egc_at(current.row, current.col, metrics) catch {
            return error.Stop;
        };

        if (std.mem.eql(u8, bracket_egc, opening_char)) {
            const closing_row, const closing_col =
                try Editor.match_bracket(root, current, metrics);

            prev = current;
            next.row = closing_row;
            next.col = closing_col;
        } else if (std.mem.eql(u8, bracket_egc, closing_char)) {
            const opening_row, const opening_col =
                try Editor.match_bracket(root, current, metrics);

            prev.row = opening_row;
            prev.col = opening_col;
            next = current;
        } else {
            const pair = find_bracket_pair(root, cursel, metrics, .left, opening_char) catch blk: {
                break :blk try find_bracket_pair(root, cursel, metrics, .right, opening_char);
            };

            prev.row = pair[0][0];
            prev.col = pair[0][1];
            next.row = pair[1][0];
            next.col = pair[1][1];
        }
    }

    prev.move_right(root, metrics) catch {};

    if (scope == .around) {
        prev.move_left(root, metrics) catch {};
        next.move_right(root, metrics) catch {};
    }

    const sel = cursel.enable_selection(root, metrics);
    sel.begin = prev;
    sel.end = next;
    cursel.*.cursor = next;
}

fn find_bracket_pair(root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics, direction: enum { left, right }, char: []const u8) error{Stop}!struct { struct { usize, usize }, struct { usize, usize } } {
    const start = cursel.cursor;
    var moving_cursor = cursel.cursor;

    var i: usize = 0;
    while (i < bracket_search_radius) : (i += 1) {
        switch (direction) {
            .left => try moving_cursor.move_left(root, metrics),
            .right => try moving_cursor.move_right(root, metrics),
        }

        const curr_egc, _, _ = root.egc_at(moving_cursor.row, moving_cursor.col, metrics) catch {
            return error.Stop;
        };
        if (std.mem.eql(u8, char, curr_egc)) {
            const closing_row, const closing_col = try Editor.match_bracket(root, moving_cursor, metrics);

            switch (direction) {
                .left => if (closing_row > start.row or (closing_row == start.row and closing_col > start.col)) {
                    return .{ .{ moving_cursor.row, moving_cursor.col }, .{ closing_row, closing_col } };
                } else {
                    continue;
                },
                .right => {
                    return .{ .{ moving_cursor.row, moving_cursor.col }, .{ closing_row, closing_col } };
                },
            }
        }
    }

    return error.Stop;
}
