const tp = @import("thespian");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

const Allocator = @import("std").mem.Allocator;
const eql = @import("std").mem.eql;

const Self = @This();
const name = "󰥨 find";

const Commands = command.Collection(cmds);

const max_query_size = 1024;

allocator: Allocator,
buf: [max_query_size]u8 = undefined,
input_: []u8 = "",
last_buf: [max_query_size]u8 = undefined,
last_input: []u8 = "",
commands: Commands = undefined,

pub fn create(allocator: Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator };
    try self.commands.init(self);
    if (tui.get_active_selection(self.allocator)) |text| {
        defer self.allocator.free(text);
        @memcpy(self.buf[0..text.len], text);
        self.input_ = self.buf[0..text.len];
    }
    var mode = try keybind.mode("mini/find_in_files", allocator, .{
        .insert_command = "mini_mode_insert_bytes",
    });
    mode.event_handler = EventHandler.to_owned(self);
    return .{ mode, .{ .name = name } };
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
    self.allocator.destroy(self);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var text: []const u8 = undefined;

    defer self.update_mini_mode_text();

    if (try m.match(.{"F"})) {
        self.start_query() catch |e| return tp.exit_error(e, @errorReturnTrace());
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn insert_code_point(self: *Self, c: u32) !void {
    if (self.input_.len + 6 >= self.buf.len)
        return;
    const bytes = try input.ucs32_to_utf8(&[_]u32{c}, self.buf[self.input_.len..]);
    self.input_ = self.buf[0 .. self.input_.len + bytes];
}

fn insert_bytes(self: *Self, bytes_: []const u8) !void {
    const bytes = bytes_[0..@min(self.buf.len - self.input_.len, bytes_.len)];
    const newlen = self.input_.len + bytes.len;
    @memcpy(self.buf[self.input_.len..newlen], bytes);
    self.input_ = self.buf[0..newlen];
}

fn start_query(self: *Self) !void {
    if (self.input_.len < 2 or eql(u8, self.input_, self.last_input))
        return;
    @memcpy(self.last_buf[0..self.input_.len], self.input_);
    self.last_input = self.last_buf[0..self.input_.len];
    try command.executeName("find_in_files_query", command.fmt(.{self.input_}));
}

fn update_mini_mode_text(self: *Self) void {
    if (tui.mini_mode()) |mini_mode| {
        mini_mode.text = self.input_;
        mini_mode.cursor = tui.egc_chunk_width(self.input_, 0, 1);
    }
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        self.input_ = "";
        self.update_mini_mode_text();
    }
    pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
        command.executeName("close_find_in_files_results", .{}) catch {};
        command.executeName("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

    pub fn mini_mode_select(_: *Self, _: Ctx) Result {
        command.executeName("goto_selected_file", .{}) catch {};
        return command.executeName("exit_mini_mode", .{});
    }
    pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

    pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
        var egc: u32 = 0;
        if (!try ctx.args.match(.{tp.extract(&egc)}))
            return error.InvalidFindInFilesInsertCodePointArgument;
        self.insert_code_point(egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.update_mini_mode_text();
    }
    pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
        var bytes: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&bytes)}))
            return error.InvalidFindInFilesInsertBytesArgument;
        self.insert_bytes(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.update_mini_mode_text();
    }
    pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

    pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
        self.input_ = self.input_[0 .. self.input_.len - tui.egc_last(self.input_).len];
        self.update_mini_mode_text();
    }
    pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

    pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
        return mini_mode_insert_bytes(self, ctx);
    }
    pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
};
