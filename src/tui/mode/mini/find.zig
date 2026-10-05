const tp = @import("thespian");
const cbor = @import("cbor");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");
const Buffer = @import("Buffer");
const Mode = Buffer.FindMode;

const tui = @import("../../tui.zig");
const ed = @import("../../editor.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const ArrayList = std.ArrayList;
const Timestamp = std.Io.Timestamp;

const Self = @This();

const Commands = command.Collection(cmds);

allocator: Allocator,
mini_editor: *tui.MiniEditor,
find_mode: Mode,
last_input: ArrayList(u8),
start_view: ed.View,
start_cursor: ed.Cursor,
editor: *ed.Editor,
history_pos: ?usize = null,
commands: Commands = undefined,

pub fn create(allocator: Allocator, ctx: command.Context) !struct { tui.Mode, tui.MiniMode } {
    const editor = tui.get_active_editor() orelse return error.NotFound;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const mini_editor = try tui.MiniEditor.create(allocator);
    errdefer mini_editor.destroy();
    self.* = .{
        .allocator = allocator,
        .mini_editor = mini_editor,
        .find_mode = editor.find_mode orelse default_find_mode(),
        .last_input = .empty,
        .start_view = editor.view,
        .start_cursor = editor.get_primary().cursor,
        .editor = editor,
    };
    try self.commands.init(self);
    var query: []const u8 = undefined;
    if (ctx.args.match(.{ cbor.extract(&self.find_mode), cbor.extract(&query) }) catch false) {
        editor.find_mode = self.find_mode;
        try self.mini_editor.buffer.set_text(query);
    } else {
        if (ctx.args.match(.{cbor.extract(&self.find_mode)}) catch false) {
            editor.find_mode = self.find_mode;
        }
        switch (tui.config().initial_find_query) {
            .empty => {},
            .selection => try self.set_from_current_selection(editor),
            .last_query => self.find_history_prev(),
            .selection_or_last_query => {
                try self.set_from_current_selection(editor);
                if (self.mini_editor.bytes().len == 0) self.find_history_prev();
            },
        }
        self.mini_editor.buffer.select_all();
    }
    var mode = try keybind.mode("mini/find", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = find_mode_name(self.find_mode), .mini_editor = self.mini_editor } };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.mini_editor.destroy();
    self.last_input.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn default_find_mode() Mode {
    return tui.config().find_mode;
}

fn find_mode_name(find_mode: Mode) []const u8 {
    const base = "󱎸 find";
    return switch (find_mode) {
        .auto => base,
        .exact => base ++ "  ",
        .case_folded => base ++ "  ",
        .regex_auto => base ++ " 󰑑 ",
        .regex => base ++ " 󰑑   ",
        .regex_case_folded => base ++ " 󰑑  ",
    };
}

fn set_from_current_selection(self: *Self, editor: *ed.Editor) !void {
    if (editor.get_primary().selection) |sel| ret: {
        const text = editor.get_selection(sel, self.allocator) catch break :ret;
        defer self.allocator.free(text);
        try self.mini_editor.buffer.set_text(text);
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var text: []const u8 = undefined;

    const ctx: command.Context = .empty();
    if (try m.match(.{"F"})) {
        self.flush_input(ctx.now) catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.mini_editor.buffer.paste(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn flush_input(self: *Self, now: Timestamp) !void {
    self.editor.find_mode = self.find_mode;
    const pattern = self.mini_editor.bytes();
    if (pattern.len > 0) {
        if (eql(u8, pattern, self.last_input.items))
            return;
        self.last_input.clearRetainingCapacity();
        try self.last_input.appendSlice(self.allocator, pattern);
        self.editor.find_operation = .goto_next_match;
        const primary = self.editor.get_primary();
        primary.selection = null;
        primary.cursor = self.start_cursor;
        try self.editor.find_in_buffer(pattern, .find, self.find_mode, .empty());
    } else {
        self.reset(now);
    }
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.flush_input(ctx.now) catch {};
    return command.executeName(name_, ctx);
}

fn reset(self: *Self, now: Timestamp) void {
    self.editor.get_primary().selection = null;
    self.editor.get_primary().cursor = self.start_cursor;
    self.editor.scroll_to(self.start_view.row, now);
    self.editor.clear_matches();
}

fn cancel(self: *Self, ctx: command.Context) void {
    self.reset(ctx.now);
    command.executeName("exit_mini_mode", ctx) catch {};
}

fn find_history_prev(self: *Self) void {
    if (self.editor.find_history) |*history| {
        if (self.history_pos) |pos| {
            if (pos > 0) self.history_pos = pos - 1;
        } else {
            self.history_pos = history.items.len - 1;
            if (self.mini_editor.bytes().len > 0)
                self.editor.push_find_history(self.editor.allocator.dupe(u8, self.mini_editor.bytes()) catch return);
            if (eql(u8, history.items[self.history_pos.?], self.mini_editor.bytes()) and self.history_pos.? > 0)
                self.history_pos = self.history_pos.? - 1;
        }
        self.load_history(self.history_pos.?);
    }
}

fn find_history_next(self: *Self) void {
    if (self.editor.find_history) |*history| if (self.history_pos) |pos| {
        if (pos < history.items.len - 1) {
            self.history_pos = pos + 1;
            self.load_history(self.history_pos.?);
        }
    };
}

fn load_history(self: *Self, pos: usize) void {
    if (self.editor.find_history) |*history| {
        self.mini_editor.buffer.set_text(history.items[pos]) catch {};
    }
}

fn toggle_find_mode(self: *Self, ctx: cmds.Ctx, new_find_mode: Mode) cmds.Result {
    const a = self.allocator;
    const query = try a.dupe(u8, self.mini_editor.bytes());
    defer a.free(query);
    self.find_mode = new_find_mode;
    self.editor.find_mode = new_find_mode;
    self.cancel(ctx);
    tui.config_mut().find_mode = new_find_mode;
    try tui.save_config();
    command.executeName("find", command.fmt(.{ new_find_mode, query })) catch {};
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn toggle_find_mode_case_folded(self: *Self, ctx: Ctx) Result {
        const new_find_mode = Buffer.find_mode.toggleCase(self.find_mode);
        return toggle_find_mode(self, ctx, new_find_mode);
    }
    pub const toggle_find_mode_case_folded_meta: Meta = .{ .description = "Toggle case folded find mode" };

    pub fn toggle_find_mode_regex(self: *Self, ctx: Ctx) Result {
        const new_find_mode = Buffer.find_mode.toggleRegex(self.find_mode);
        return toggle_find_mode(self, ctx, new_find_mode);
    }
    pub const toggle_find_mode_regex_meta: Meta = .{ .description = "Toggle regex find mode" };

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        try self.mini_editor.buffer.clear();
    }
    pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(self: *Self, ctx: Ctx) Result {
        self.cancel(ctx);
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

    pub fn mini_mode_select(self: *Self, ctx: Ctx) Result {
        self.editor.push_find_history(self.mini_editor.bytes());
        self.cmd("exit_mini_mode", ctx) catch {};
    }
    pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidFindInsertCodePointArgument;
        try self.mini_editor.buffer.insert_code_point(@intCast(egc));
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidFindInsertBytesArgument;
        try self.mini_editor.buffer.insert(bytes);
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
        try self.mini_editor.buffer.delete_backward();
    }
    pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

    pub fn mini_mode_delete_word_left(self: *Self, _: Ctx) Result {
        try self.mini_editor.buffer.delete_word_left();
    }
    pub const mini_mode_delete_word_left_meta: Meta = .{ .description = "Delete word to the left" };

    pub fn mini_mode_history_prev(self: *Self, _: Ctx) Result {
        self.find_history_prev();
    }
    pub const mini_mode_history_prev_meta: Meta = .{ .description = "History previous" };

    pub fn mini_mode_history_next(self: *Self, _: Ctx) Result {
        self.find_history_next();
    }
    pub const mini_mode_history_next_meta: Meta = .{ .description = "History next" };

    pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidFindPasteArgument;
        try self.mini_editor.buffer.paste(bytes);
    }
    pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
};
