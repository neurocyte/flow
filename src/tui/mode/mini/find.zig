const tp = @import("thespian");
const cbor = @import("cbor");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");
const Buffer = @import("Buffer");

const tui = @import("../../tui.zig");
const ed = @import("../../editor.zig");

const Allocator = @import("std").mem.Allocator;
const eql = @import("std").mem.eql;
const ArrayList = @import("std").ArrayList;
const Writer = @import("std").Io.Writer;

const Self = @This();
const name = "󱎸 find";
const name_auto = name;
const name_exact = name ++ "  ";
const name_case_folded = name ++ "  ";

const Commands = command.Collection(cmds);

const Mode = enum { auto, exact, case_folded };

allocator: Allocator,
input_: ArrayList(u8),
find_mode: Mode = .auto,
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
    self.* = .{
        .allocator = allocator,
        .input_ = .empty,
        .last_input = .empty,
        .start_view = editor.view,
        .start_cursor = editor.get_primary().cursor,
        .editor = editor,
    };
    try self.commands.init(self);
    _ = ctx.args.match(.{cbor.extract(&self.find_mode)}) catch {};
    var query: []const u8 = undefined;
    if (ctx.args.match(.{ cbor.extract(&self.find_mode), cbor.extract(&query) }) catch false) {
        try self.input_.appendSlice(self.allocator, query);
    } else switch (tui.config().initial_find_query) {
        .empty => {},
        .selection => try self.set_from_current_selection(editor),
        .last_query => self.find_history_prev(),
        .selection_or_last_query => {
            try self.set_from_current_selection(editor);
            if (self.input_.items.len == 0) self.find_history_prev();
        },
    }
    var mode = try keybind.mode("mini/find", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = switch (self.find_mode) {
        .auto => name_auto,
        .exact => name_exact,
        .case_folded => name_case_folded,
    } } };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.input_.deinit(self.allocator);
    self.last_input.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn set_from_current_selection(self: *Self, editor: *ed.Editor) !void {
    if (editor.get_primary().selection) |sel| ret: {
        const text = editor.get_selection(sel, self.allocator) catch break :ret;
        defer self.allocator.free(text);
        try self.input_.appendSlice(self.allocator, text);
    }
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
    try self.input_.appendSlice(self.allocator, buf[0..bytes]);
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    try self.input_.appendSlice(self.allocator, bytes);
}

fn flush_input(self: *Self) !void {
    if (self.input_.items.len > 0) {
        if (eql(u8, self.input_.items, self.last_input.items))
            return;
        self.last_input.clearRetainingCapacity();
        try self.last_input.appendSlice(self.allocator, self.input_.items);
        self.editor.find_operation = .goto_next_match;
        const primary = self.editor.get_primary();
        primary.selection = null;
        primary.cursor = self.start_cursor;
        try self.editor.find_in_buffer(self.input_.items, .find, switch (self.find_mode) {
            .auto => self.auto_detect_mode(),
            .exact => .exact,
            .case_folded => .case_folded,
        });
    } else {
        self.reset();
    }
}

fn auto_detect_mode(self: *Self) Buffer.FindMode {
    const pattern = self.input_.items;
    const folded = Buffer.unicode.case_fold(self.allocator, pattern) catch return .case_folded;
    defer self.allocator.free(folded);
    return if (eql(u8, pattern, folded)) .case_folded else .exact;
}

fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
    self.flush_input() catch {};
    return command.executeName(name_, ctx);
}

fn reset(self: *Self) void {
    self.editor.get_primary().selection = null;
    self.editor.get_primary().cursor = self.start_cursor;
    self.editor.scroll_to(self.start_view.row);
    self.editor.clear_matches();
}

fn cancel(self: *Self) void {
    self.reset();
    command.executeName("exit_mini_mode", .{}) catch {};
}

fn find_history_prev(self: *Self) void {
    if (self.editor.find_history) |*history| {
        if (self.history_pos) |pos| {
            if (pos > 0) self.history_pos = pos - 1;
        } else {
            self.history_pos = history.items.len - 1;
            if (self.input_.items.len > 0)
                self.editor.push_find_history(self.editor.allocator.dupe(u8, self.input_.items) catch return);
            if (eql(u8, history.items[self.history_pos.?], self.input_.items) and self.history_pos.? > 0)
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
        self.input_.clearRetainingCapacity();
        self.input_.appendSlice(self.allocator, history.items[pos]) catch {};
    }
}

fn update_mini_mode_text(self: *Self) void {
    if (tui.mini_mode()) |mini_mode| {
        mini_mode.text = self.input_.items;
        mini_mode.cursor = tui.egc_chunk_width(self.input_.items, 0, 1);
    }
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn toggle_find_mode(self: *Self, _: Ctx) Result {
        const new_find_mode: Buffer.FindMode = switch (self.find_mode) {
            .exact => .case_folded,
            .case_folded => .exact,
            .auto => if (Buffer.unicode.is_lowercase(self.input_.items))
                .exact
            else
                .case_folded,
        };
        const allocator = self.allocator;
        const query = try allocator.dupe(u8, self.input_.items);
        defer allocator.free(query);
        self.cancel();
        command.executeName("find", command.fmt(.{ new_find_mode, query })) catch {};
    }
    pub const toggle_find_mode_meta: Meta = .{ .description = "Toggle find mode" };

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        self.input_.clearRetainingCapacity();
        self.update_mini_mode_text();
    }
    pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(self: *Self, _: Ctx) Result {
        self.cancel();
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

    pub fn mini_mode_select(self: *Self, _: Ctx) Result {
        self.editor.push_find_history(self.input_.items);
        self.cmd("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidFindInsertCodePointArgument;
        self.insert_code_point(egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.update_mini_mode_text();
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidFindInsertBytesArgument;
        self.insert_bytes(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.update_mini_mode_text();
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
        self.input_.resize(self.allocator, self.input_.items.len - tui.egc_last(self.input_.items).len) catch {};
        self.update_mini_mode_text();
    }
    pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

    pub fn mini_mode_history_prev(self: *Self, _: Ctx) Result {
        self.find_history_prev();
        self.update_mini_mode_text();
    }
    pub const mini_mode_history_prev_meta: Meta = .{ .description = "History previous" };

    pub fn mini_mode_history_next(self: *Self, _: Ctx) Result {
        self.find_history_next();
        self.update_mini_mode_text();
    }
    pub const mini_mode_history_next_meta: Meta = .{ .description = "History next" };

    pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
        return mini_mode_insert_bytes(self, ctx);
    }
    pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
};
