const fmt = @import("std").fmt;
const command = @import("command");

const tui = @import("../../tui.zig");
const Cursor = @import("../../editor.zig").Cursor;

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    cursor: Cursor = .{},
    part: enum { row, col } = .row,
};
pub const Separator = ':';

pub fn name(_: *Type) []const u8 {
    return "＃goto";
}

pub fn start(_: *Type) ValueType {
    const editor = tui.get_active_editor() orelse return .{};
    return .{ .cursor = editor.get_primary().cursor };
}

pub fn process_digit(self: *Type, digit: u8) void {
    const part = if (self.input) |input| input.part else .row;
    switch (part) {
        .row => switch (digit) {
            0 => {
                if (self.input) |*input| input.cursor.row = input.cursor.row * 10;
            },
            1...9 => {
                if (self.input) |*input| {
                    input.cursor.row = input.cursor.row * 10 + digit;
                } else {
                    self.input = .{ .cursor = .{ .row = digit } };
                }
            },
            else => unreachable,
        },
        .col => if (self.input) |*input| {
            input.cursor.col = input.cursor.col * 10 + digit;
        },
    }
}

pub fn process_separator(self: *Type) void {
    if (self.input) |*input| switch (input.part) {
        .row => input.part = .col,
        else => {},
    };
}

pub fn delete(self: *Type, input: *ValueType) void {
    switch (input.part) {
        .row => {
            const newval = if (input.cursor.row < 10) 0 else input.cursor.row / 10;
            if (newval == 0) self.input = null else input.cursor.row = newval;
        },
        .col => {
            const newval = if (input.cursor.col < 10) 0 else input.cursor.col / 10;
            if (newval == 0) {
                input.part = .row;
                input.cursor.col = 0;
            } else input.cursor.col = newval;
        },
    }
}

pub fn format_value(_: *Type, input: ?ValueType, buf: []u8) []const u8 {
    return if (input) |value| blk: {
        switch (value.part) {
            .row => break :blk fmt.bufPrint(buf, "{d}", .{value.cursor.row}) catch "",
            .col => if (value.cursor.col == 0)
                break :blk fmt.bufPrint(buf, "{d}:", .{value.cursor.row}) catch ""
            else
                break :blk fmt.bufPrint(buf, "{d}:{d}", .{ value.cursor.row, value.cursor.col }) catch "",
        }
    } else "";
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

fn goto(self: *Type, _: command.Context) void {
    send_goto(if (self.input) |input| input.cursor else self.start.cursor);
}

fn send_goto(cursor: Cursor) void {
    command.executeName("goto_line_and_column", command.fmt(.{ cursor.row, cursor.col })) catch {};
}
