const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("root");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        input: std.ArrayList(u8),
        commands: Commands = undefined,

        const Commands = command.Collection(cmds);
        const Self = @This();

        pub fn create(allocator: std.mem.Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .input = .empty,
            };
            try self.commands.init(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            var mode = try keybind.mode("mini/buffer", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self) } };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            self.input.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var text: []const u8 = undefined;

            if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.input.appendSlice(self.allocator, text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            self.update_mini_mode_text();
            return false;
        }

        fn message(comptime fmt: anytype, args: anytype) void {
            var buf: [256]u8 = undefined;
            tp.self_pid().send(.{ "message", std.fmt.bufPrint(&buf, fmt, args) catch @panic("too large") }) catch {};
        }

        fn update_mini_mode_text(self: *Self) void {
            if (tui.mini_mode()) |mini_mode| {
                mini_mode.text = self.input.items;
                mini_mode.cursor = tui.egc_chunk_width(self.input.items, 0, 1);
            }
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                self.input.clearRetainingCapacity();
                self.update_mini_mode_text();
            }
            pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
                command.executeName("exit_mini_mode", .{}) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                if (self.input.items.len > 0) {
                    self.input.shrinkRetainingCapacity(self.input.items.len - tui.egc_last(self.input.items).len);
                }
                self.update_mini_mode_text();
            }
            pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var egc: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&egc)}))
                    return error.InvalidMiniBufferInsertCodePointArgument;
                var buf: [32]u8 = undefined;
                const bytes = try input.ucs32_to_utf8(&[_]u32{egc}, &buf);
                try self.input.appendSlice(self.allocator, buf[0..bytes]);
                self.update_mini_mode_text();
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidMiniBufferInsertBytesArgument;
                try self.input.appendSlice(self.allocator, bytes);
                self.update_mini_mode_text();
            }
            pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_select(self: *Self, _: Ctx) Result {
                options.select(self);
                self.update_mini_mode_text();
            }
            pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                return mini_mode_insert_bytes(self, ctx);
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
        };
    };
}
