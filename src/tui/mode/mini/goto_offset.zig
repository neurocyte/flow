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

pub fn parse_value(text: []const u8) ?ValueType {
    return .{ .offset = fmt.parseInt(usize, text, 10) catch return null };
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
