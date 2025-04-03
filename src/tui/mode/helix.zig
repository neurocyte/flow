const std = @import("std");
const log = @import("log");
const location_history = @import("location_history");
const command = @import("command");
const cmd = command.executeName;

const tui = @import("../tui.zig");
const Editor = @import("../editor.zig").Editor;
const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;

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

    pub fn extend_line_below(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;

        const root = try ed.buf_root();
        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const sel = cursel.enable_selection_normal();
            sel.normalize();

            try Editor.move_cursor_begin(root, &sel.begin, ed.metrics);
            try Editor.move_cursor_end(root, &sel.end, ed.metrics);
            cursel.cursor = sel.end;
            try cursel.selection.?.end.move_right(root, ed.metrics);
            try cursel.cursor.move_right(root, ed.metrics);
        };

        ed.clamp();
    }
    pub const extend_line_below_meta: Meta = .{ .description = "Select current line, if already selected, extend to next line" };

    pub fn move_next_word_start(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const(root, Editor.move_cursor_word_right_vim) catch {};
        ed.clamp();
    }

    pub const move_next_word_start_meta: Meta = .{ .description = "Move next word start" };

    pub fn move_prev_word_start(_: *void, _: Ctx) Result {
        const mv = tui.mainview() orelse return;
        const ed = mv.get_active_editor() orelse return;
        const root = try ed.buf_root();

        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
        };

        ed.with_selections_const(root, move_cursor_word_left_helix) catch {};
        ed.clamp();
    }
    pub const move_prev_word_start_meta: Meta = .{ .description = "Move previous word start" };
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
