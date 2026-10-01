const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");

const Menu = @This();

label: []const u8 = "",
items: []const Item,

pub const Item = union(enum) {
    command: Command,
    separator,
    submenu: *const Menu,
};

pub const Command = struct {
    command: []const u8,
    args: []const u8 = args(.{}),
    label: []const u8 = "",

    pub fn id(self: *const Command) ?command.ID {
        return command.get_id(self.command);
    }

    pub fn send(self: *const Command) tp.result {
        return tp.self_pid().send(.{ "cmd", self.command, cbor.Raw{ .bytes = self.args } });
    }

    pub fn get_label(self: *const Command) []const u8 {
        if (self.label.len > 0) return self.label;
        const id_ = self.id() orelse return self.command;
        const description = command.get_description(id_) orelse return self.command;
        return if (description.len > 0) description else self.command;
    }

    pub fn get_icon(self: *const Command) ?[]const u8 {
        return command.get_icon(self.id() orelse return null);
    }
};

pub fn args(comptime value: anytype) []const u8 {
    const encoded = comptime blk: {
        var buf: [4096]u8 = undefined;
        const bytes = cbor.fmt(&buf, value);
        break :blk bytes[0..bytes.len].*;
    };
    return &encoded;
}
