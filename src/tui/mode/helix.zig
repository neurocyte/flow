const std = @import("std");
const log = @import("log");
const location_history = @import("location_history");
const command = @import("command");
const cmd = command.executeName;

const tui = @import("../tui.zig");

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
    const Result = command.Result;

    pub fn w(_: *void, _: Ctx) Result {
        try cmd("save_file", .{});
    }
    pub const w_meta = .{ .description = "w (write/save file)" };

    pub fn q(_: *void, _: Ctx) Result {
        try cmd("quit", .{});
    }
    pub const q_meta = .{ .description = "q (quit)" };

    pub fn @"q!"(_: *void, _: Ctx) Result {
        try cmd("quit_without_saving", .{});
    }
    pub const @"q!_meta" = .{ .description = "q! (quit without saving)" };

    pub fn wq(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const wq_meta = .{ .description = "wq (write/save file and quit)" };

    pub fn o(_: *void, _: Ctx) Result {
        try cmd("open_file", .{});
    }
    pub const o_meta = .{ .description = "o (open file)" };

    pub fn @"wq!"(_: *void, _: Ctx) Result {
        cmd("save_file", .{}) catch {};
        try cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta" = .{ .description = "wq! (write/save file and quit without saving)" };

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
        mv.location_history.update(file_path, .{
            .row = primary.cursor.row + 1,
            .col = primary.cursor.col + 1,
        }, sel);
    }
    pub const save_selection_meta = .{ .description = "Save current selection to location history" };
};
