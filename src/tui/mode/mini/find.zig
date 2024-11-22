const tp = @import("thespian");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const ed = @import("../../editor.zig");

const Allocator = @import("std").mem.Allocator;
const eql = @import("std").mem.eql;
const ArrayList = @import("std").ArrayList;

const Self = @This();
const name = "󱎸 find";

const Commands = command.Collection(cmds);

allocator: Allocator,
input: ArrayList(u8),
last_input: ArrayList(u8),
start_view: ed.View,
start_cursor: ed.Cursor,
editor: *ed.Editor,
history_pos: ?usize = null,
commands: Commands = undefined,

pub fn create(allocator: Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        const self: *Self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .input = ArrayList(u8).init(allocator),
            .last_input = ArrayList(u8).init(allocator),
            .start_view = editor.view,
            .start_cursor = editor.get_primary().cursor,
            .editor = editor,
        };
        try self.commands.init(self);
        if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.allocator) catch break :ret;
            defer self.allocator.free(text);
            try self.input.appendSlice(text);
        }
        const input_handler, const keybind_hints = try keybind.mode.mini.find.create(allocator, .{
            .insert_command = "mini_mode_insert_bytes",
        });
        return .{
            .{
                .input_handler = input_handler,
                .event_handler = EventHandler.to_owned(self),
                .keybind_hints = keybind_hints,
            },
            .{
                .name = name,
            },
        };
    };
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.input.deinit();
    self.last_input.deinit();
    self.allocator.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var text: []const u8 = undefined;

    defer self.update_mini_mode_text();

    if (try m.match(.{"F"})) {
        self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn insert_code_point(self: *Self, c: u32) !void {
    var buf: [16]u8 = undefined;
    const bytes = input.ucs32_to_utf8(&[_]u32{c}, &buf) catch |e| return tp.exit_error(e, @errorReturnTrace());
    try self.input.appendSlice(buf[0..bytes]);
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    try self.input.appendSlice(bytes);
}

fn flush_input(self: *Self) !void {
    if (self.input.items.len > 0) {
        if (eql(u8, self.input.items, self.last_input.items))
            return;
        self.last_input.clearRetainingCapacity();
        try self.last_input.appendSlice(self.input.items);
        self.editor.find_operation = .goto_next_match;
        const primary = self.editor.get_primary();
        primary.selection = null;
        primary.cursor = self.start_cursor;
        try self.editor.find_in_buffer(self.input.items);
    } else {
        self.editor.get_primary().selection = null;
        self.editor.init_matches_update();
    }
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.flush_input() catch {};
    return command.executeName(name_, ctx);
}

fn cancel(self: *Self) void {
    self.editor.get_primary().cursor = self.start_cursor;
    self.editor.scroll_to(self.start_view.row);
    command.executeName("exit_mini_mode", .{}) catch {};
}

fn find_history_prev(self: *Self) void {
    if (self.editor.find_history) |*history| {
        if (self.history_pos) |pos| {
            if (pos > 0) self.history_pos = pos - 1;
        } else {
            self.history_pos = history.items.len - 1;
            if (self.input.items.len > 0)
                self.editor.push_find_history(self.editor.allocator.dupe(u8, self.input.items) catch return);
            if (eql(u8, history.items[self.history_pos.?], self.input.items) and self.history_pos.? > 0)
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
        self.input.clearRetainingCapacity();
        self.input.appendSlice(history.items[pos]) catch {};
    }
}

fn update_mini_mode_text(self: *Self) void {
    if (tui.current().mini_mode) |*mini_mode| {
        mini_mode.text = self.input.items;
        mini_mode.cursor = self.input.items.len;
    }
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        self.input.clearRetainingCapacity();
        self.update_mini_mode_text();
    }
    pub const mini_mode_reset_meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(self: *Self, _: Ctx) Result {
        self.cancel();
    }
    pub const mini_mode_cancel_meta = .{ .description = "Cancel input" };

    pub fn mini_mode_select(self: *Self, _: Ctx) Result {
        self.editor.push_find_history(self.input.items);
        self.cmd("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_select_meta = .{ .description = "Select" };

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidArgument;
        self.insert_code_point(egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.update_mini_mode_text();
    }
    pub const mini_mode_insert_code_point_meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidArgument;
        self.insert_bytes(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.update_mini_mode_text();
    }
    pub const mini_mode_insert_bytes_meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
        _ = self.input.popOrNull();
        self.update_mini_mode_text();
    }
    pub const mini_mode_delete_backwards_meta = .{ .description = "Delete backwards" };

    pub fn mini_mode_history_prev(self: *Self, _: Ctx) Result {
        self.find_history_prev();
        self.update_mini_mode_text();
    }
    pub const mini_mode_history_prev_meta = .{ .description = "History previous" };

    pub fn mini_mode_history_next(self: *Self, _: Ctx) Result {
        self.find_history_next();
        self.update_mini_mode_text();
    }
    pub const mini_mode_history_next_meta = .{ .description = "History next" };

    pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
        return mini_mode_insert_bytes(self, ctx);
    }
    pub const mini_mode_paste_meta = .{ .arguments = &.{.string} };
};
