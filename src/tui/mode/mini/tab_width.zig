const command = @import("command");

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub fn name(_: *Type) []const u8 {
    return " tab size";
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

fn goto(self: *Type) void {
    command.executeName("set_tab_width", command.fmt(.{self.input orelse self.start})) catch {};
}
