const std = @import("std");
const tp = @import("thespian");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const editor_mod = @import("../../editor.zig");
const Editor = editor_mod.Editor;
const Cursor = editor_mod.Cursor;

const Allocator = std.mem.Allocator;

const Self = @This();

const Commands = command.Collection(cmds);

allocator: Allocator,
commands: Commands = undefined,
extend: bool,

pub fn create(allocator: Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
    const editor = tui.get_active_editor() orelse return error.EditorNotAvailable;

    const labels = editor.compute_jump_labels() orelse return error.NoWordsFound;
    editor.set_jump_labels(labels);

    const extend = if (editor.get_primary().selection) |_| true else false;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .extend = extend,
    };
    try self.commands.init(self);
    var mode = try keybind.mode("mini/get_char", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = "⇢ goto word" } };
}

pub fn deinit(self: *Self) void {
    if (tui.get_active_editor()) |editor| {
        editor.clear_jump_labels();
    }
    self.commands.deinit();
    self.allocator.destroy(self);
}

pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
    return false;
}

fn process_egc(self: *Self, egc: []const u8) command.Result {
    if (egc.len != 1) return cancel(self);

    const ch = egc[0];
    var valid = false;
    for (Editor.jump_label_alphabet) |c| {
        if (c == ch) {
            valid = true;
            break;
        }
    }
    if (!valid) return cancel(self);

    const editor = tui.get_active_editor() orelse return cancel(self);

    if (editor.jump_label_first_char) |first_char| {
        const labels = editor.jump_labels orelse return cancel(self);
        for (labels) |jl| {
            if (jl.label[0] == first_char and jl.label[1] == ch) {
                return jump_to_label(self, editor, jl);
            }
        }
        return cancel(self);
    } else {
        const labels = editor.jump_labels orelse return cancel(self);
        for (labels) |jl| {
            if (jl.label[0] == ch) {
                editor.jump_label_first_char = ch;
                return;
            }
        }
        return cancel(self);
    }
}

fn jump_to_label(self: *Self, editor: *Editor, jl: Editor.JumpLabel) command.Result {
    editor.send_editor_jump_source() catch {};

    const root = editor.buf_root() catch return cancel(self);
    const primary = editor.get_primary();

    if (self.extend) {
        const sel = primary.enable_selection_normal();
        const target = Cursor{ .row = jl.row, .col = jl.col, .target = jl.col };
        if (target.right_of(sel.end)) {
            sel.end = target;
        } else {
            sel.begin = target;
        }
        primary.cursor = target;
        primary.check_selection(root, editor.metrics);
    } else {
        primary.selection = null;
        primary.cursor.move_to(root, jl.row, jl.col, editor.metrics) catch {};
    }

    if (editor.view.is_visible(&primary.cursor))
        editor.clamp()
    else
        editor.scroll_view_center(.{}) catch {};
    editor.send_editor_jump_destination() catch {};
    editor.need_render();

    command.executeName("exit_mini_mode", .{}) catch {};
}

fn cancel(_: *Self) command.Result {
    command.executeName("exit_mini_mode", .{}) catch {};
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var code_point: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&code_point)}))
            return error.InvalidGotoWordInsertCodePointArgument;
        var buf: [6]u8 = undefined;
        const bytes = input.ucs32_to_utf8(&[_]u32{code_point}, &buf) catch return error.InvalidGotoWordCodePoint;
        return process_egc(self, buf[0..bytes]);
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidGotoWordInsertBytesArgument;
        const egc = tui.egc_last(bytes);
        var buf: [6]u8 = undefined;
        @memcpy(buf[0..egc.len], egc);
        return process_egc(self, buf[0..egc.len]);
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_cancel(self: *Self, _: Ctx) Result {
        return cancel(self);
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel goto word" };
};
