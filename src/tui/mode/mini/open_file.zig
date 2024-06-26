const std = @import("std");
const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");

const Self = @This();

a: std.mem.Allocator,
file_path: std.ArrayList(u8),

pub fn create(a: std.mem.Allocator, _: command.Context) !*Self {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .file_path = std.ArrayList(u8).init(a),
    };
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        if (editor.is_dirty()) return tp.exit("unsaved changes");
        if (editor.file_path) |old_path|
            if (std.mem.lastIndexOf(u8, old_path, "/")) |pos|
                try self.file_path.appendSlice(old_path[0 .. pos + 1]);
        if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.a) catch break :ret;
            defer self.a.free(text);
            if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
                self.file_path.clearRetainingCapacity();
            try self.file_path.appendSlice(text);
        }
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.file_path.deinit();
    self.a.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(_: *Self) []const u8 {
    return " open";
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;

    defer {
        if (tui.current().mini_mode) |*mini_mode| {
            mini_mode.text = self.file_path.items;
            mini_mode.cursor = self.file_path.items.len;
        }
    }

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        self.mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
    switch (evtype) {
        event_type.PRESS => try self.mapPress(keypress, egc, modifiers),
        event_type.REPEAT => try self.mapPress(keypress, egc, modifiers),
        event_type.RELEASE => try self.mapRelease(keypress, egc, modifiers),
        else => {},
    }
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) !void {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'Q' => self.cmd("quit", .{}),
            'V' => self.cmd("system_paste", .{}),
            'U' => self.file_path.clearRetainingCapacity(),
            'G' => self.cancel(),
            'C' => self.cancel(),
            'L' => self.cmd("scroll_view_center", .{}),
            'I' => self.insert_bytes("\t"),
            key.SPACE => self.cancel(),
            key.BACKSPACE => self.file_path.clearRetainingCapacity(),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'V' => self.cmd("system_paste", .{}),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'V' => self.cmd("system_paste", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        0 => switch (keypress) {
            key.ESC => self.cancel(),
            key.ENTER => self.navigate(),
            key.BACKSPACE => if (self.file_path.items.len > 0) {
                self.file_path.shrinkRetainingCapacity(self.file_path.items.len - 1);
            },
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn mapRelease(_: *Self, _: u32, _: u32, _: u32) !void {}

fn insert_code_point(self: *Self, c: u32) !void {
    var buf: [32]u8 = undefined;
    const bytes = try ucs32_to_utf8(&[_]u32{c}, &buf);
    try self.file_path.appendSlice(buf[0..bytes]);
}

fn insert_bytes(self: *Self, bytes: []const u8) !void {
    try self.file_path.appendSlice(bytes);
}

fn cmd(_: *Self, name_: []const u8, ctx: command.Context) tp.result {
    return command.executeName(name_, ctx);
}

fn cancel(_: *Self) void {
    command.executeName("exit_mini_mode", .{}) catch {};
}

fn navigate(self: *Self) void {
    if (self.file_path.items.len > 0)
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = self.file_path.items } }) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}
