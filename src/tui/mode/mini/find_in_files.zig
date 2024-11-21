const tp = @import("thespian");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");

const Allocator = @import("std").mem.Allocator;
const eql = @import("std").mem.eql;

const Self = @This();
const name = "󰥨 find";

const Commands = command.Collection(cmds);

allocator: Allocator,
buf: [1024]u8 = undefined,
input: []u8 = "",
last_buf: [1024]u8 = undefined,
last_input: []u8 = "",
mainview: *mainview,
commands: Commands = undefined,

pub fn create(allocator: Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
    const self: *Self = try allocator.create(Self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv| {
        self.* = .{
            .allocator = allocator,
            .mainview = mv,
        };
        try self.commands.init(self);
        if (mv.get_editor()) |editor| if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.allocator) catch break :ret;
            defer self.allocator.free(text);
            @memcpy(self.buf[0..text.len], text);
            self.input = self.buf[0..text.len];
        };
        const input_handler, const keybind_hints = try keybind.mode.mini.find_in_files.create(allocator, .{
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
    }
    return error.NotFound;
}

pub fn deinit(self: *Self) void {
    self.commands.deinit();
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
    if (self.input.len + 16 > self.buf.len)
        try self.flush_input();
    const bytes = try input.ucs32_to_utf8(&[_]u32{c}, self.buf[self.input.len..]);
    self.input = self.buf[0 .. self.input.len + bytes];
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    if (self.input.len + 16 > self.buf.len)
        try self.flush_input();
    const newlen = self.input.len + bytes.len;
    @memcpy(self.buf[self.input.len..newlen], bytes);
    self.input = self.buf[0..newlen];
}

fn flush_input(self: *Self) !void {
    if (self.input.len > 2) {
        if (eql(u8, self.input, self.last_input))
            return;
        @memcpy(self.last_buf[0..self.input.len], self.input);
        self.last_input = self.last_buf[0..self.input.len];
        try self.mainview.find_in_files(self.input);
    }
}

fn update_mini_mode_text(self: *Self) void {
    if (tui.current().mini_mode) |*mini_mode| {
        mini_mode.text = self.input;
        mini_mode.cursor = self.input.len;
    }
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
        self.flush_input() catch {};
        self.input = "";
        self.update_mini_mode_text();
    }
    pub const mini_mode_reset_meta = .{ .description = "Clear input" };

    pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
        command.executeName("exit_mini_mode", .{}) catch {};
    }
    pub const mini_mode_cancel_meta = .{ .description = "Cancel input" };

    pub fn mini_mode_select(_: *Self, _: Ctx) Result {
        command.executeName("goto_selected_file", .{}) catch {};
        return command.executeName("exit_mini_mode", .{});
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
        if (self.input.len > 0) {
            self.input = self.input[0 .. self.input.len - 1];
        }
    }
    pub const mini_mode_delete_backwards_meta = .{ .description = "Delete backwards" };
};
