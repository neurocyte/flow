const std = @import("std");
const command = @import("command");
const cmd = command.executeName;

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
    pub const w_meta = .{ .description = "w (write file)" };

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
    pub const wq_meta = .{ .description = "wq (write file and quit)" };

    pub fn @"wq!"(_: *void, _: Ctx) Result {
        cmd("save_file", .{}) catch {};
        try cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta" = .{ .description = "wq! (write file and quit without saving)" };

    pub fn enter_mode_at_next_char(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const enter_mode_at_next_char_meta = .{ .description = "Move forward one char and change mode" };

    pub fn enter_mode_on_newline_down(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const enter_mode_on_newline_down_meta = .{ .description = "Insert a newline and change mode" };

    pub fn enter_mode_on_newline_up(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }
    pub const enter_mode_on_newline_up_meta = .{ .description = "Insert a newline above the current line and change mode" };

    pub fn enter_mode_at_line_begin(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const enter_mode_at_line_begin_meta = .{ .description = "Goto line begin and change mode" };

    pub fn enter_mode_at_line_end(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }
    pub const enter_mode_at_line_end_meta = .{ .description = "Goto line end and change mode" };

    pub fn copy_line(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
    }

    pub const copy_line_meta = .{ .description = "Copies the current line" };

    pub fn delete_line(self: *void, ctx: Ctx) Result {
        _ = self; // autofix
        _ = ctx; // autofix
        //TODO
        return undefined;
        //try self.move_begin(ctx);
        //const b = try self.buf_for_update();
        //var root = try self.delete_to(move_cursor_end, b.root, b.allocator);
        //root = try self.delete_to(move_cursor_right, b.root, b.allocator);
        //try self.delete_forward(ctx);
        //try self.update_buf(root);
        //self.clamp();
    }
    pub const delete_line_meta = .{ .description = "Delete the current line without copying" };
};
