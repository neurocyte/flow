const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");

const Allocator = @import("std").mem.Allocator;
const json = @import("std").json;
const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;

const Self = @This();

allocator: Allocator,
key: [6]u8 = undefined,
direction: Direction,
operation: Operation,

const Direction = enum {
    left,
    right,
};

const Operation = enum {
    move,
    select,
};

pub fn create(allocator: Allocator, ctx: command.Context) !*Self {
    var right: bool = true;
    const select = if (tui.current().mainview.dynamic_cast(mainview)) |mv| if (mv.get_editor()) |editor| if (editor.get_primary().selection) |_| true else false else false else false;
    _ = ctx.args.match(.{tp.extract(&right)}) catch return error.NotFound;
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .direction = if (right) .right else .left,
        .operation = if (select) .select else .move,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(self: *Self) []const u8 {
    return switch (self.operation) {
        .move => switch (self.direction) {
            .left => "↶ move",
            .right => "↷ move",
        },
        .select => switch (self.direction) {
            .left => "󰒅 ↶ select",
            .right => "󰒅 ↷ select",
        },
    };
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var modifiers: u32 = undefined;
    var egc: u32 = undefined;
    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) }))
        try self.mapEvent(evtype, keypress, egc, modifiers);
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) tp.result {
    switch (evtype) {
        event_type.PRESS => try self.mapPress(keypress, egc, modifiers),
        else => {},
    }
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    switch (keypress) {
        key.LSUPER, key.RSUPER => return,
        key.LSHIFT, key.RSHIFT => return,
        key.LCTRL, key.RCTRL => return,
        key.LALT, key.RALT => return,
        else => {},
    }
    return switch (modifiers) {
        mod.SHIFT => if (!key.synthesized_p(keypress)) self.execute_operation(egc) else self.cancel(),
        0 => switch (keypress) {
            key.ESC => self.cancel(),
            key.ENTER => self.cancel(),
            else => if (!key.synthesized_p(keypress)) self.execute_operation(egc) else self.cancel(),
        },
        else => self.cancel(),
    };
}

fn execute_operation(self: *Self, c: u32) void {
    const cmd = switch (self.direction) {
        .left => switch (self.operation) {
            .move => "move_to_char_left",
            .select => "select_to_char_left",
        },
        .right => switch (self.operation) {
            .move => "move_to_char_right",
            .select => "select_to_char_right",
        },
    };
    var buf: [6]u8 = undefined;
    const bytes = ucs32_to_utf8(&[_]u32{c}, &buf) catch return;
    command.executeName(cmd, command.fmt(.{buf[0..bytes]})) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}

fn cancel(_: *Self) void {
    command.executeName("exit_mini_mode", .{}) catch {};
}
