const std = @import("std");
const tp = @import("thespian");

const input = @import("input");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

const Allocator = @import("std").mem.Allocator;
const fmt = @import("std").fmt;

pub fn Create(options: type) type {
    return struct {
        const Self = @This();

        const Commands = command.Collection(cmds);

        const ValueType = if (@hasDecl(options, "ValueType")) options.ValueType else void;

        allocator: Allocator,
        input: ?ValueType = null,
        value: ValueType,
        ctx: command.Context,
        commands: Commands = undefined,

        pub fn create(allocator: Allocator, ctx: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .ctx = .{ .args = try ctx.args.clone(allocator) },
                .value = options.start(self),
            };
            try self.commands.init(self);
            var mode = try keybind.mode("mini/get_char", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self) } };
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(options, "deinit"))
                options.deinit(self);
            self.allocator.free(self.ctx.args.buf);
            self.commands.deinit();
            self.allocator.destroy(self);
        }

        pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
            return false;
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var code_point: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&code_point)}))
                    return error.InvalidMoveToCharInsertCodePointArgument;
                var buf: [6]u8 = undefined;
                const bytes = input.ucs32_to_utf8(&[_]u32{code_point}, &buf) catch return error.InvalidMoveToCharCodePoint;
                return options.process_egc(self, buf[0..bytes]);
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidMoveToCharInsertBytesArgument;
                const egc = tui.egc_last(bytes);
                var buf: [6]u8 = undefined;
                @memcpy(buf[0..egc.len], egc);
                return options.process_egc(self, buf[0..egc.len]);
            }
            pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
                command.executeName("exit_mini_mode", .{}) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };
        };
    };
}
