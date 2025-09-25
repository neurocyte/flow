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
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn w(_: *void, _: Ctx) Result {
        try cmd("save_file", .{});
    }
    pub const w_meta: Meta = .{ .description = "w (write file)" };

    pub fn q(_: *void, _: Ctx) Result {
        try cmd("quit", .{});
    }
    pub const q_meta: Meta = .{ .description = "q (quit)" };

    pub fn @"q!"(_: *void, _: Ctx) Result {
        try cmd("quit_without_saving", .{});
    }
    pub const @"q!_meta": Meta = .{ .description = "q! (quit without saving)" };

    pub fn @"qa!"(_: *void, _: Ctx) Result {
        try cmd("quit_without_saving", .{});
    }
    pub const @"qa!_meta": Meta = .{ .description = "qa! (quit without saving anything)" };

    pub fn wq(_: *void, _: Ctx) Result {
        try cmd("save_file", command.fmt(.{ "then", .{ "quit", .{} } }));
    }
    pub const wq_meta: Meta = .{ .description = "wq (write file and quit)" };

    pub fn @"wq!"(_: *void, _: Ctx) Result {
        cmd("save_file", .{}) catch {};
        try cmd("quit_without_saving", .{});
    }
    pub const @"wq!_meta": Meta = .{ .description = "wq! (write file and quit without saving)" };

    pub fn @"e!"(_: *void, _: Ctx) Result {
        try cmd("reload_file", .{});
    }
    pub const @"e!_meta": Meta = .{ .description = "e! (force reload current file)" };

    pub fn bd(_: *void, _: Ctx) Result {
        try cmd("close_file", .{});
    }
    pub const bd_meta: Meta = .{ .description = "bd (Close file)" };

    pub fn bw(_: *void, _: Ctx) Result {
        try cmd("delete_buffer", .{});
    }
    pub const bw_meta: Meta = .{ .description = "bw (Delete buffer)" };

    pub fn bnext(_: *void, _: Ctx) Result {
        try cmd("next_tab", .{});
    }
    pub const bnext_meta: Meta = .{ .description = "bnext (Next buffer/tab)" };

    pub fn bprevious(_: *void, _: Ctx) Result {
        try cmd("next_tab", .{});
    }
    pub const bprevious_meta: Meta = .{ .description = "bprevious (Previous buffer/tab)" };

    pub fn ls(_: *void, _: Ctx) Result {
        try cmd("switch_buffers", .{});
    }
    pub const ls_meta: Meta = .{ .description = "ls (List/switch buffers)" };

    pub fn move_begin_or_add_integer_argument_zero(_: *void, _: Ctx) Result {
        return if (@import("keybind").current_integer_argument()) |_|
            command.executeName("add_integer_argument_digit", command.fmt(.{0}))
        else
            command.executeName("move_begin", .{});
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
    pub const delete_line_meta: Meta = .{ .description = "Delete the current line without copying" };
};
