const fmt = @import("std").fmt;
const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = @import("../../editor.zig").Cursor;

pub fn name(_: *Type) []const u8 {
    return "＃goto";
}

pub fn start(_: *Type) ValueType {
    const editor = tui.get_active_editor() orelse return .{};
    return editor.get_primary().cursor;
}

pub fn process_digit(self: *Type, digit: u8) void {
    switch (digit) {
        0 => {
            if (self.input) |*x| x.row = x.row * 10;
        },
        1...9 => {
            if (self.input) |*x| {
                x.row = x.row * 10 + digit;
            } else {
                self.input = .{ .row = digit };
            }
        },
        else => unreachable,
    }
}

pub fn delete(self: *Type, input: *ValueType) void {
    const newval = if (input.row < 10) 0 else input.row / 10;
    if (newval == 0) self.input = null else input.row = newval;
}

pub fn format_value(_: *Type, input: ?ValueType, buf: []u8) []const u8 {
    return if (input) |value|
        (fmt.bufPrint(buf, "{d}", .{value.row}) catch "")
    else
        "";
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

fn goto(self: *Type, _: command.Context) void {
    if (self.input) |input| {
        command.executeName("goto_line", command.fmt(.{input.row})) catch {};
    } else {
        command.executeName("goto_line_and_column", command.fmt(.{ self.start.row, self.start.col })) catch {};
    }
}
