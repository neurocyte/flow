const cbor = @import("cbor");
const command = @import("command");

const tui = @import("../../tui.zig");

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub fn name(_: *Type) []const u8 {
    return " tab size";
}

pub fn start(self: *Type) usize {
    const tab_width = if (tui.get_active_editor()) |editor| editor.tab_width else tui.config().tab_width;
    self.input = tab_width;
    return tab_width;
}

const default_cmd = "set_editor_tab_width";

pub const cancel = preview;

pub fn preview(self: *Type, _: command.Context) void {
    command.executeName(default_cmd, command.fmt(.{self.input orelse self.start})) catch {};
}

pub fn apply(self: *Type, ctx: command.Context) void {
    var cmd: []const u8 = undefined;
    if (!(ctx.args.match(.{cbor.extract(&cmd)}) catch false))
        cmd = default_cmd;
    command.executeName(cmd, command.fmt(.{self.input orelse self.start})) catch {};
}
