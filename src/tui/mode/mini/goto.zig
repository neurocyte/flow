const fmt = @import("std").fmt;
const splitScalar = @import("std").mem.splitScalar;
const cbor = @import("cbor");
const command = @import("command");

const tui = @import("../../tui.zig");
const Cursor = @import("../../editor.zig").Cursor;

pub const Type = @import("numeric_input.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    cursor: Cursor = .{},
};
pub const Separator = ':';

pub fn name(_: *Type) []const u8 {
    return "＃goto";
}

pub fn start(_: *Type) ValueType {
    const editor = tui.get_active_editor() orelse return .{};
    return .{ .cursor = editor.get_primary().cursor };
}

pub fn parse_value(text: []const u8) ?ValueType {
    var parts = splitScalar(u8, text, Separator);
    const row = fmt.parseInt(usize, parts.first(), 10) catch return null;
    if (row == 0) return null;
    const col = fmt.parseInt(usize, parts.rest(), 10) catch 0;
    return .{ .cursor = .{ .row = row, .col = col } };
}

pub const preview = goto;
pub const apply = goto;
pub const cancel = goto;

const Mode = enum {
    goto,
    select,
};

fn goto(self: *Type, ctx: command.Context) void {
    var mode: Mode = .goto;
    _ = ctx.args.match(.{cbor.extract(&mode)}) catch {};
    send_goto(mode, if (self.input) |input| input.cursor else .{
        .row = self.start.cursor.row + 1,
        .col = self.start.cursor.col + 1,
    });
}

fn send_goto(mode: Mode, cursor: Cursor) void {
    switch (mode) {
        .goto => command.executeName("goto_line_and_column", command.fmt(.{ cursor.row, cursor.col })) catch {},
        .select => command.executeName("select_to_line", command.fmt(.{cursor.row})) catch {},
    }
}
