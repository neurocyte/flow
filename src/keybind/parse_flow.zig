const std = @import("std");
const input = @import("input");

pub const ParseError = error{
    OutOfMemory,
    InvalidFormat,
};

var parse_error_buf: [256]u8 = undefined;
pub var parse_error_message: []const u8 = "";

fn parse_error_reset() void {
    parse_error_message = "";
}

fn parse_error(comptime format: anytype, args: anytype) ParseError {
    parse_error_message = std.fmt.bufPrint(&parse_error_buf, format, args) catch "error in parse_error";
    return error.InvalidFormat;
}

pub fn parse_key_events(allocator: std.mem.Allocator, str: []const u8) ParseError![]input.KeyEvent {
    parse_error_reset();
    if (str.len == 0) return parse_error("empty", .{});
    var result_events = std.ArrayList(input.KeyEvent).init(allocator);
    var iter_sequence = std.mem.tokenizeScalar(u8, str, ' ');
    while (iter_sequence.next()) |item| {
        var key: ?input.Key = null;
        var mods = input.ModSet{};
        var iter = std.mem.tokenizeScalar(u8, item, '+');
        loop: while (iter.next()) |part| {
            if (part.len == 0) return parse_error("empty part in '{s}'", .{str});
            const modsInfo = @typeInfo(input.ModSet).@"struct";
            inline for (modsInfo.fields) |field| {
                if (std.mem.eql(u8, part, field.name)) {
                    if (@field(mods, field.name)) return parse_error("duplicate modifier '{s}' in '{s}'", .{ part, str });
                    @field(mods, field.name) = true;
                    continue :loop;
                }
            }
            const alias_mods = .{
                .{ "cmd", "super" },
                .{ "command", "super" },
                .{ "opt", "alt" },
                .{ "option", "alt" },
                .{ "control", "ctrl" },
            };
            inline for (alias_mods) |pair| {
                if (std.mem.eql(u8, part, pair[0])) {
                    if (@field(mods, pair[1])) return parse_error("duplicate modifier '{s}' in '{s}'", .{ part, str });
                    @field(mods, pair[1]) = true;
                    continue :loop;
                }
            }

            if (key != null) return parse_error("multiple keys in '{s}'", .{str});
            key = input.key.name_map.get(part);
            if (key == null) key = name_map.get(part);
            if (key == null) unicode: {
                const view = std.unicode.Utf8View.init(part) catch break :unicode;
                var it = view.iterator();
                const cp = it.nextCodepoint() orelse break :unicode;
                if (it.nextCodepoint() != null) break :unicode;
                key = cp;
            }
            if (key == null) return parse_error("unknown key '{s}' in '{s}'", .{ part, str });
        }
        if (key) |k|
            try result_events.append(input.KeyEvent.from_key_modset(k, mods))
        else
            return parse_error("no key defined in '{s}'", .{str});
    }
    return result_events.toOwnedSlice();
}

pub const name_map = blk: {
    @setEvalBranchQuota(2000);
    break :blk std.StaticStringMap(u21).initComptime(.{
        .{ "tab", input.key.tab },
        .{ "enter", input.key.enter },
        .{ "escape", input.key.escape },
        .{ "space", input.key.space },
        .{ "backspace", input.key.backspace },
        .{ "lt", '<' },
        .{ "gt", '>' },
    });
};
