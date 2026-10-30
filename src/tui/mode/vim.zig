const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const command = @import("command");
const cmd = command.executeName;

const tui = @import("../tui.zig");

const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;
const Selection = Buffer.Selection;
const CurSel = @import("../editor.zig").CurSel;
const Editor = @import("../editor.zig").Editor;
const surround = @import("../surround.zig");

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

    pub fn @"w!"(_: *void, ctx: Ctx) Result {
        try cmd("force_save_file", ctx);
    }
    pub const @"w!_meta": Meta = .{ .description = "w! (write file, overwriting external changes)" };

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

    pub fn x(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const x_meta: Meta = .{ .description = "x (write file and quit)" };

    pub fn @"wq!"(_: *void, ctx: Ctx) Result {
        cmd("force_save_file", ctx) catch {};
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

    pub const enter_mode_at_line_begin_meta: Meta = .{ .description = "Go to line begin and change mode" };

    pub fn enter_mode_at_line_end(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }
    pub const enter_mode_at_line_end_meta: Meta = .{ .description = "Go to line end and change mode" };

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

    pub fn surround_add_vim(_: *void, ctx: Ctx) Result {
        if (!surround.has_key_args(ctx)) {
            const mv = tui.mainview() orelse return;
            const ed = mv.get_active_editor() orelse return;
            if (ed.get_primary().selection == null) return cmd("surround", .fmt(.{"add"}));
            try cmd("enter_mode", .fmt(.{"normal"}));
            return cmd("surround", .fmt(.{"selection"}));
        }
        try surround.edit(ctx, surround_add_cursel);
    }
    pub const surround_add_vim_meta: Meta = .{
        .description = "Surround motion (or selection) with character",
        .arguments = &.{ .string, .string },
    };

    pub fn surround_delete_vim(_: *void, ctx: Ctx) Result {
        if (!surround.has_key_args(ctx)) return cmd("surround", .fmt(.{"delete"}));
        try surround.edit(ctx, surround_delete_cursel);
    }
    pub const surround_delete_vim_meta: Meta = .{ .description = "Delete surrounding pair", .arguments = &.{.string} };

    pub fn surround_change_vim(_: *void, ctx: Ctx) Result {
        if (!surround.has_key_args(ctx)) return cmd("surround", .fmt(.{"change"}));
        try surround.edit(ctx, surround_change_cursel);
    }
    pub const surround_change_vim_meta: Meta = .{ .description = "Change surrounding pair", .arguments = &.{ .string, .string } };
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
    var prev, var next = try surround.find_scope_pair(root, cursel.cursor, metrics, opening_char, closing_char);

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

fn is_blank_or_eol_at(root: Buffer.Root, cursor: Cursor, metrics: Buffer.Metrics) bool {
    return cursor.test_at(root, Editor.is_whitespace_or_eol, metrics);
}

fn line_end(root: Buffer.Root, cursor: Cursor, metrics: Buffer.Metrics) Cursor {
    var end = cursor;
    end.move_end(root, metrics);
    return end;
}

fn select_long_word(root: Buffer.Root, cursor: Cursor, metrics: Buffer.Metrics, scope: enum { inside, around }) error{Stop}!Selection {
    if (is_blank_or_eol_at(root, cursor, metrics)) return error.Stop;
    var begin = cursor;
    while (begin.col > 0) {
        var prev = begin;
        prev.move_left(root, metrics) catch break;
        if (is_blank_or_eol_at(root, prev, metrics)) break;
        begin = prev;
    }
    var end = cursor;
    while (!is_blank_or_eol_at(root, end, metrics)) end.move_right(root, metrics) catch break;
    if (scope == .around) {
        if (surround.is_blank_at(root, end, metrics)) {
            while (surround.is_blank_at(root, end, metrics)) end.move_right(root, metrics) catch break;
        } else while (begin.col > 0) {
            var prev = begin;
            prev.move_left(root, metrics) catch break;
            if (!surround.is_blank_at(root, prev, metrics)) break;
            begin = prev;
        }
    }
    return .{ .begin = begin, .end = end };
}

fn select_surround_motion(root: Buffer.Root, cursor: Cursor, motion: []const u8, metrics: Buffer.Metrics) error{Stop}!Selection {
    var begin = cursor;
    var end = cursor;
    if (motion.len == 1) switch (motion[0]) {
        'w', 'e' => {
            if (motion[0] == 'w')
                try Editor.move_cursor_word_right_vim(root, &end, metrics)
            else {
                try Editor.move_cursor_word_right_end_vim(root, &end, metrics);
                end.move_right(root, metrics) catch {};
            }
            if (end.row != begin.row) end = line_end(root, begin, metrics);
            surround.trim_end(root, begin, &end, metrics);
        },
        'W' => while (!is_blank_or_eol_at(root, end, metrics)) end.move_right(root, metrics) catch break,
        '$' => end = line_end(root, begin, metrics),
        's' => {
            begin.move_begin();
            while (surround.is_blank_at(root, begin, metrics)) try begin.move_right(root, metrics);
            end = line_end(root, begin, metrics);
            surround.trim_end(root, begin, &end, metrics);
        },
        else => return error.Stop,
    } else if (motion.len == 2 and (motion[0] == 'i' or motion[0] == 'a')) {
        const object = motion[1..];
        if (std.mem.eql(u8, object, "W"))
            return select_long_word(root, cursor, metrics, if (motion[0] == 'i') .inside else .around);
        if (std.mem.eql(u8, object, "w")) {
            var cursel: CurSel = .{ .cursor = cursor };
            try select_word_textobject(root, &cursel, metrics, if (motion[0] == 'i') .inside else .around);
            return cursel.selection orelse error.Stop;
        }
        if (!surround.is_pair_char(object)) return error.Stop;
        begin, end = try surround.find(root, cursor, object, metrics);
        if (motion[0] == 'i') try begin.move_right(root, metrics) else try end.move_right(root, metrics);
    } else return error.Stop;
    if (!end.right_of(begin)) return error.Stop;
    return .{ .begin = begin, .end = end };
}

fn surround_add_cursel(ed: *Editor, root: Buffer.Root, cursel: *CurSel, allocator: Allocator, ctx: command.Context) error{Stop}!Buffer.Root {
    var char: []const u8 = undefined;
    var motion: []const u8 = undefined;
    var range: Selection = undefined;
    if (ctx.args.match(.{ tp.extract(&char), tp.extract(&motion) }) catch false) {
        range = try select_surround_motion(root, cursel.cursor, motion, ed.metrics);
    } else if (ctx.args.match(.{tp.extract(&char)}) catch false) {
        range = cursel.selection orelse return error.Stop;
        range.normalize();
    } else return error.Stop;
    const delimiters = surround.padded_delimiters(char);
    const root_, _, const nudges = try surround.add(root, range, delimiters[0], delimiters[1], allocator, ed.metrics);
    for (nudges) |nudge| ed.nudge_insert(nudge, cursel, 1);
    cursel.cursor = range.begin;
    cursel.selection = null;
    return root_;
}

fn surround_delete_cursel(ed: *Editor, root: Buffer.Root, cursel: *CurSel, allocator: Allocator, ctx: command.Context) error{Stop}!Buffer.Root {
    var target: []const u8 = undefined;
    if (!(ctx.args.match(.{tp.extract(&target)}) catch return error.Stop))
        return error.Stop;
    return surround.change(ed, root, cursel, cursel.cursor, target, surround.is_opening_bracket(target), .{ "", "" }, allocator);
}

fn surround_change_cursel(ed: *Editor, root: Buffer.Root, cursel: *CurSel, allocator: Allocator, ctx: command.Context) error{Stop}!Buffer.Root {
    var target: []const u8 = undefined;
    var replacement: []const u8 = undefined;
    if (!(ctx.args.match(.{ tp.extract(&target), tp.extract(&replacement) }) catch return error.Stop))
        return error.Stop;
    return surround.change(ed, root, cursel, cursel.cursor, target, surround.is_opening_bracket(target), surround.padded_delimiters(replacement), allocator);
}
