const std = @import("std");
const command = @import("command");
const tp = @import("thespian");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    keys: [3][6]u8 = undefined,
    lens: [3]usize = undefined,
    count: usize = 0,

    fn key(self: *const ValueType, i: usize) []const u8 {
        return self.keys[i][0..self.lens[i]];
    }
};

const Operation = enum { add, selection, delete, change };

pub fn start(_: *Type) ValueType {
    return .{};
}

pub fn name(self: *Type) []const u8 {
    if (is_helix(self)) return "󰅪 match";
    return switch (operation(self) orelse return "surround") {
        .add => "ys surround",
        .selection => "S surround",
        .delete => "ds surround",
        .change => "cs surround",
    };
}

pub fn keybind_mode(self: *Type) []const u8 {
    const helix = is_helix(self);
    return switch (operation(self) orelse return "mini/get_char") {
        .add => "mini/surround_motion",
        .selection => if (helix) "mini/match_with" else "mini/surround_with",
        .delete, .change => if (helix) "mini/match_pair" else "mini/surround_target",
    };
}

fn is_helix(self: *Type) bool {
    return self.ctx.args.match(.{ tp.string, tp.string }) catch false;
}

fn hint(mode: []const u8) command.Result {
    return command.executeName("switch_mode", .fmt(.{mode}));
}

fn operation(self: *Type) ?Operation {
    var op: []const u8 = undefined;
    if (!(self.ctx.args.match(.{ tp.extract(&op), tp.more }) catch false)) return null;
    return std.meta.stringToEnum(Operation, op);
}

fn action(self: *Type, default: []const u8) []const u8 {
    var name_: []const u8 = undefined;
    return if (self.ctx.args.match(.{ tp.string, tp.extract(&name_) }) catch false) name_ else default;
}

fn is_textobject_prefix(egc: []const u8) bool {
    return std.mem.eql(u8, egc, "i") or std.mem.eql(u8, egc, "a");
}

const single_key_motions = [_][]const u8{ "w", "W", "e", "$", "s" };

fn is_single_key_motion(egc: []const u8) bool {
    for (single_key_motions) |motion| if (std.mem.eql(u8, egc, motion)) return true;
    return false;
}

pub fn process_egc(self: *Type, egc: []const u8) command.Result {
    const op = operation(self) orelse return exit();
    var value = &self.value;
    if (egc.len > value.keys[0].len) return exit();
    @memcpy(value.keys[value.count][0..egc.len], egc);
    value.lens[value.count] = egc.len;
    value.count += 1;

    switch (op) {
        .selection => return run(action(self, "surround_add_vim"), .fmt(.{value.key(0)})),
        .delete => return run(action(self, "surround_delete_vim"), .fmt(.{value.key(0)})),
        .change => if (value.count == 2)
            return run(action(self, "surround_change_vim"), .fmt(.{ value.key(0), value.key(1) }))
        else
            return hint(if (is_helix(self)) "mini/match_with" else "mini/surround_with"),
        .add => switch (value.count) {
            1 => return if (is_textobject_prefix(egc))
                hint("mini/surround_object")
            else if (is_single_key_motion(egc))
                hint("mini/surround_with")
            else
                exit(),
            2 => if (is_textobject_prefix(value.key(0)))
                return hint("mini/surround_with")
            else
                return run(action(self, "surround_add_vim"), .fmt(.{ value.key(1), value.key(0) })),
            else => {
                var motion: [12]u8 = undefined;
                const motion_len = value.lens[0] + value.lens[1];
                @memcpy(motion[0..value.lens[0]], value.key(0));
                @memcpy(motion[value.lens[0]..motion_len], value.key(1));
                return run(action(self, "surround_add_vim"), .fmt(.{ value.key(2), motion[0..motion_len] }));
            },
        },
    }
}

fn run(command_name: []const u8, args: command.Context) command.Result {
    const result = command.executeName(command_name, args);
    try exit();
    return result;
}

fn exit() command.Result {
    return command.executeName("exit_mini_mode", .empty());
}
