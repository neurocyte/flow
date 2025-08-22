const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub fn name(_: *Type) []const u8 {
    return "＃goto";
}

pub fn start(_: *Type) usize {
    const editor = tui.get_active_editor() orelse return 1;
    return editor.get_primary().cursor.row + 1;
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

fn goto(self: *Type, _: command.Context) void {
    command.executeName("goto_line", command.fmt(.{self.input orelse self.start})) catch {};
}
