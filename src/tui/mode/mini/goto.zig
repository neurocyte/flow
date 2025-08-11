const command = @import("command");

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub fn name(_: *Type) []const u8 {
    return "＃goto";
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

fn goto(self: *Type) void {
    command.executeName("goto_line", command.fmt(.{self.input orelse self.start})) catch {};
}
