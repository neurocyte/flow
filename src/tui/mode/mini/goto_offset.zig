const fmt = @import("std").fmt;
const command = @import("command");

const tui = @import("../../tui.zig");
const Cursor = @import("../../editor.zig").Cursor;

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    cursor: Cursor = .{},
    offset: usize = 0,
};

pub fn name(_: *Type) []const u8 {
    return "＃goto byte";
}

pub fn start(_: *Type) ValueType {
    const editor = tui.get_active_editor() orelse return .{};
    return .{ .cursor = editor.get_primary().cursor };
}

pub fn process_digit(self: *Type, digit: u8) void {
    switch (digit) {
        0...9 => {
            if (self.input) |*input| {
                input.offset = input.offset * 10 + digit;
            } else {
                self.input = .{ .offset = digit };
            }
        },
        else => unreachable,
    }
}

pub fn delete(self: *Type, input: *ValueType) void {
    const newval = if (input.offset < 10) 0 else input.offset / 10;
    if (newval == 0) self.input = null else input.offset = newval;
}

pub fn format_value(_: *Type, input_: ?ValueType, buf: []u8) []const u8 {
    return if (input_) |input|
        fmt.bufPrint(buf, "{d}", .{input.offset}) catch ""
    else
        "";
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

fn goto(self: *Type, _: command.Context) void {
    if (self.input) |input|
        command.executeName("goto_byte_offset", command.fmt(.{input.offset})) catch {}
    else
        command.executeName("goto_line_and_column", command.fmt(.{ self.start.cursor.row, self.start.cursor.col })) catch {};
}
