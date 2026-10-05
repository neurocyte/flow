const std = @import("std");
const command = @import("command");
const Plane = @import("renderer").Plane;

const Widget = @import("Widget.zig");
const MiniBuffer = @import("MiniBuffer.zig");
const tui = @import("tui.zig");

const Allocator = std.mem.Allocator;

allocator: Allocator,
buffer: MiniBuffer,
prefix: std.ArrayList(u8) = .empty,
view_col: usize = 0,
on_change: ?OnChange = null,
commands: Commands = undefined,

const Self = @This();
const Commands = command.Collection(cmds);

pub const OnChange = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque) void,

    pub fn bind(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) OnChange {
        const Ctx = @TypeOf(ctx);
        return .{ .ctx = ctx, .f = struct {
            fn call(ctx_: *anyopaque) void {
                f(@as(Ctx, @ptrCast(@alignCast(ctx_))));
            }
        }.call };
    }
};

pub fn create(allocator: Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .buffer = .init(allocator) };
    try self.commands.init(self);
    return self;
}

pub fn destroy(self: *Self) void {
    self.commands.deinit();
    self.buffer.deinit();
    self.prefix.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.buffer.bytes();
}

pub fn set_prefix(self: *Self, prefix: []const u8) !void {
    self.prefix.clearRetainingCapacity();
    try self.prefix.appendSlice(self.allocator, prefix);
}

pub fn width(self: *const Self) usize {
    return tui.egc_chunk_width(self.prefix.items, 0, 1) + tui.egc_chunk_width(self.buffer.bytes(), 0, 1);
}

pub const RenderOptions = struct {
    y: c_int = 0,
    x: c_int = 0,
    width: usize,
    style: Widget.Theme.Style,
    style_selection: Widget.Theme.Style,
};

pub fn render(self: *Self, plane: *Plane, opts: RenderOptions) void {
    const prefix_width = plane.egc_chunk_width(self.prefix.items, 0, 1);
    if (opts.width <= prefix_width) return;
    const view_width = opts.width - prefix_width;
    const x = opts.x + @as(c_int, @intCast(prefix_width));
    plane.set_style(opts.style);
    plane.cursor_move_yx(opts.y, opts.x);
    _ = plane.putstr_unicode(self.prefix.items) catch {};

    const text = self.buffer.bytes();
    const cursor_col = plane.egc_chunk_width(text[0..self.buffer.cursor], 0, 1);
    const total = plane.egc_chunk_width(text, 0, 1) + 1;
    self.view_col = if (total <= view_width) 0 else @min(self.view_col, total - view_width);
    if (cursor_col < self.view_col) self.view_col = cursor_col;
    if (cursor_col >= self.view_col + view_width) self.view_col = cursor_col + 1 - view_width;

    const sel = self.buffer.selection();
    var pos: usize = 0;
    var col: usize = 0;
    while (pos < text.len) {
        var cols: usize = 0;
        const len = plane.egc_length(text[pos..], &cols, col, 1);
        defer {
            pos += len;
            col += cols;
        }
        if (col < self.view_col) continue;
        if (col + cols > self.view_col + view_width) break;
        const selected = if (sel) |s| pos >= s.begin and pos < s.end else false;
        plane.set_style(if (selected) opts.style_selection else opts.style);
        plane.cursor_move_yx(opts.y, x + @as(c_int, @intCast(col - self.view_col)));
        _ = plane.putstr_unicode(text[pos .. pos + len]) catch {};
    }
    plane.set_style(opts.style);
    plane.cursor_enable(opts.y, x + @as(c_int, @intCast(cursor_col - self.view_col)), tui.get_cursor_shape());
}

fn moved(_: *Self) void {
    tui.need_render(@src());
}

fn changed(self: *Self) void {
    if (self.on_change) |cb| cb.f(cb.ctx);
    tui.need_render(@src());
}

fn copy_selection(self: *Self) !void {
    const text = self.buffer.selected_text() orelse return;
    tui.clipboard_start_group();
    tui.clipboard_add_chunk(try tui.clipboard_allocator().dupe(u8, text));
    return tui.clipboard_send_to_system();
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn mini_editor_move_left(self: *Self, _: Ctx) Result {
        self.buffer.move_left(.move);
        self.moved();
    }
    pub const mini_editor_move_left_meta: Meta = .{ .description = "Move cursor left" };

    pub fn mini_editor_move_right(self: *Self, _: Ctx) Result {
        self.buffer.move_right(.move);
        self.moved();
    }
    pub const mini_editor_move_right_meta: Meta = .{ .description = "Move cursor right" };

    pub fn mini_editor_move_word_left(self: *Self, _: Ctx) Result {
        self.buffer.move_word_left(.move);
        self.moved();
    }
    pub const mini_editor_move_word_left_meta: Meta = .{ .description = "Move cursor left by word" };

    pub fn mini_editor_move_word_right(self: *Self, _: Ctx) Result {
        self.buffer.move_word_right(.move);
        self.moved();
    }
    pub const mini_editor_move_word_right_meta: Meta = .{ .description = "Move cursor right by word" };

    pub fn mini_editor_move_begin(self: *Self, _: Ctx) Result {
        self.buffer.move_begin(.move);
        self.moved();
    }
    pub const mini_editor_move_begin_meta: Meta = .{ .description = "Move cursor to beginning of input" };

    pub fn mini_editor_move_end(self: *Self, _: Ctx) Result {
        self.buffer.move_end(.move);
        self.moved();
    }
    pub const mini_editor_move_end_meta: Meta = .{ .description = "Move cursor to end of input" };

    pub fn mini_editor_select_left(self: *Self, _: Ctx) Result {
        self.buffer.move_left(.select);
        self.moved();
    }
    pub const mini_editor_select_left_meta: Meta = .{ .description = "Select left" };

    pub fn mini_editor_select_right(self: *Self, _: Ctx) Result {
        self.buffer.move_right(.select);
        self.moved();
    }
    pub const mini_editor_select_right_meta: Meta = .{ .description = "Select right" };

    pub fn mini_editor_select_word_left(self: *Self, _: Ctx) Result {
        self.buffer.move_word_left(.select);
        self.moved();
    }
    pub const mini_editor_select_word_left_meta: Meta = .{ .description = "Select left by word" };

    pub fn mini_editor_select_word_right(self: *Self, _: Ctx) Result {
        self.buffer.move_word_right(.select);
        self.moved();
    }
    pub const mini_editor_select_word_right_meta: Meta = .{ .description = "Select right by word" };

    pub fn mini_editor_select_begin(self: *Self, _: Ctx) Result {
        self.buffer.move_begin(.select);
        self.moved();
    }
    pub const mini_editor_select_begin_meta: Meta = .{ .description = "Select to beginning of input" };

    pub fn mini_editor_select_end(self: *Self, _: Ctx) Result {
        self.buffer.move_end(.select);
        self.moved();
    }
    pub const mini_editor_select_end_meta: Meta = .{ .description = "Select to end of input" };

    pub fn mini_editor_select_all(self: *Self, _: Ctx) Result {
        self.buffer.select_all();
        self.moved();
    }
    pub const mini_editor_select_all_meta: Meta = .{ .description = "Select all input" };

    pub fn mini_editor_delete_backward(self: *Self, _: Ctx) Result {
        try self.buffer.delete_backward();
        self.changed();
    }
    pub const mini_editor_delete_backward_meta: Meta = .{ .description = "Delete backwards" };

    pub fn mini_editor_delete_forward(self: *Self, _: Ctx) Result {
        try self.buffer.delete_forward();
        self.changed();
    }
    pub const mini_editor_delete_forward_meta: Meta = .{ .description = "Delete forwards" };

    pub fn mini_editor_delete_word_left(self: *Self, _: Ctx) Result {
        try self.buffer.delete_word_left();
        self.changed();
    }
    pub const mini_editor_delete_word_left_meta: Meta = .{ .description = "Delete word to the left" };

    pub fn mini_editor_delete_word_right(self: *Self, _: Ctx) Result {
        try self.buffer.delete_word_right();
        self.changed();
    }
    pub const mini_editor_delete_word_right_meta: Meta = .{ .description = "Delete word to the right" };

    pub fn mini_editor_delete_to_begin(self: *Self, _: Ctx) Result {
        try self.buffer.delete_to_begin();
        self.changed();
    }
    pub const mini_editor_delete_to_begin_meta: Meta = .{ .description = "Delete to beginning of input" };

    pub fn mini_editor_delete_to_end(self: *Self, _: Ctx) Result {
        try self.buffer.delete_to_end();
        self.changed();
    }
    pub const mini_editor_delete_to_end_meta: Meta = .{ .description = "Delete to end of input" };

    pub fn mini_editor_undo(self: *Self, _: Ctx) Result {
        try self.buffer.undo();
        self.changed();
    }
    pub const mini_editor_undo_meta: Meta = .{ .description = "Undo input edit" };

    pub fn mini_editor_redo(self: *Self, _: Ctx) Result {
        try self.buffer.redo();
        self.changed();
    }
    pub const mini_editor_redo_meta: Meta = .{ .description = "Redo input edit" };

    pub fn mini_editor_copy(self: *Self, _: Ctx) Result {
        try self.copy_selection();
    }
    pub const mini_editor_copy_meta: Meta = .{ .description = "Copy input selection to clipboard" };

    pub fn mini_editor_cut(self: *Self, _: Ctx) Result {
        try self.copy_selection();
        try self.buffer.delete_selection();
        self.changed();
    }
    pub const mini_editor_cut_meta: Meta = .{ .description = "Cut input selection to clipboard" };
};
