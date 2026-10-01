const std = @import("std");
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

    pub fn is_visible(self: *const Item) bool {
        return switch (self.*) {
            .command => |*cmd| cmd.is_visible(),
            .separator => true,
            .submenu => |submenu| submenu.has_visible_items(),
        };
    }
};

pub fn visible(self: *const Menu) VisibleIterator {
    return .{ .items = self.items };
}

pub fn has_visible_items(self: *const Menu) bool {
    var it = self.visible();
    return it.next() != null;
}

pub const VisibleIterator = struct {
    items: []const Item,
    idx: usize = 0,
    separator: ?*const Item = null,
    started: bool = false,

    pub fn next(self: *VisibleIterator) ?*const Item {
        while (self.idx < self.items.len) {
            const item = &self.items[self.idx];
            if (item.* == .separator) {
                self.idx += 1;
                if (self.started) self.separator = item;
                continue;
            }
            if (!item.is_visible()) {
                self.idx += 1;
                continue;
            }
            if (self.separator) |separator| {
                self.separator = null;
                return separator;
            }
            self.idx += 1;
            self.started = true;
            return item;
        }
        return null;
    }
};

pub const Command = struct {
    command: []const u8,
    args: []const u8 = args(.{}),
    label: []const u8 = "",
    on_activate: enum { close_menu, keep_open } = .close_menu,

    pub fn id(self: *const Command) ?command.ID {
        return command.get_id(self.command);
    }

    pub fn is_visible(self: *const Command) bool {
        const id_ = self.id() orelse return false;
        const description = command.get_description(id_) orelse return false;
        return description.len > 0;
    }

    pub fn has_args(self: *const Command) bool {
        return !std.mem.eql(u8, self.args, args(.{}));
    }

    pub fn send(self: *const Command) tp.result {
        try tp.self_pid().send(.{ "cmd", self.command, cbor.Raw{ .bytes = self.args } });
        return tp.self_pid().send(.{"flush_input"});
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
