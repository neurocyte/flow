const tp = @import("thespian");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const FileList = @import("../../FileList.zig");

const Allocator = @import("std").mem.Allocator;
const eql = @import("std").mem.eql;

const Self = @This();
const name = "󰥨 find";

const Commands = command.Collection(cmds);

const max_query_size = 1024;

allocator: Allocator,
mini_editor: *tui.MiniEditor,
last_buf: [max_query_size]u8 = undefined,
last_input: []u8 = "",
list_id: ?FileList.Id = null,
commands: Commands = undefined,

pub fn create(allocator: Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const mini_editor = try tui.MiniEditor.create(allocator);
    errdefer mini_editor.destroy();
    self.* = .{ .allocator = allocator, .mini_editor = mini_editor };
    try self.commands.init(self);
    if (tui.get_active_selection(self.allocator)) |text| {
        defer self.allocator.free(text);
        try self.mini_editor.buffer.set_text(text);
    }
    var mode = try keybind.mode("mini/find_in_files", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = name, .mini_editor = self.mini_editor } };
}

pub fn deinit(self: *Self) void {
    if (self.list_id) |list_id|
        if (tui.mainview()) |mv| mv.set_find_in_files_label(list_id, self.last_input);
    self.commands.deinit();
    self.mini_editor.destroy();
    self.allocator.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var text: []const u8 = undefined;

    if (try m.match(.{"F"})) {
        self.start_query() catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.mini_editor.buffer.paste(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn start_query(self: *Self) !void {
    const query = self.mini_editor.bytes();
    if (query.len < 2 or query.len > max_query_size or eql(u8, query, self.last_input))
        return;
    @memcpy(self.last_buf[0..query.len], query);
    self.last_input = self.last_buf[0..query.len];
    if (self.list_id == null)
        if (tui.mainview()) |mv| {
            self.list_id = mv.new_filelist(.find_in_files) catch null;
        };
    if (self.list_id) |list_id|
        try command.executeName("find_in_files_query", command.fmt(.{ query, list_id }))
    else
        try command.executeName("find_in_files_query", command.fmt(.{query}));
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        try self.mini_editor.buffer.clear();
    }
    pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(self: *Self, ctx: Ctx) Result {
        if (self.list_id) |list_id| {
            command.executeName("filelist_close", command.fmt(.{list_id})) catch {};
            self.list_id = null;
        }
        command.executeName("exit_mini_mode", ctx) catch {};
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

    pub fn mini_mode_select(_: *Self, ctx: Ctx) Result {
        command.executeName("goto_selected_file", ctx) catch {};
        return command.executeName("exit_mini_mode", ctx);
    }
    pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

    pub fn mini_mode_select_alternate(_: *Self, ctx: Ctx) Result {
        command.executeName("goto_selected_file_alternate", ctx) catch {};
        return command.executeName("exit_mini_mode", ctx);
    }
    pub const mini_mode_select_alternate_meta: Meta = .{ .description = "Select alternate" };

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidFindInFilesInsertCodePointArgument;
        try self.mini_editor.buffer.insert_code_point(@intCast(egc));
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidFindInFilesInsertBytesArgument;
        try self.mini_editor.buffer.insert(bytes);
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_delete_word_left(self: *Self, _: Ctx) Result {
        try self.mini_editor.buffer.delete_word_left();
    }
    pub const mini_mode_delete_word_left_meta: Meta = .{ .description = "Delete word to the left" };

    pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
        try self.mini_editor.buffer.delete_backward();
    }
    pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

    pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidFindInFilesPasteArgument;
        try self.mini_editor.buffer.paste(bytes);
    }
    pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
};
