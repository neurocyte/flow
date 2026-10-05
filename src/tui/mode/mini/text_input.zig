const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");

const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mini_editor: *tui.MiniEditor,
        commands: Commands = undefined,

        const Commands = command.Collection(cmds);
        const Self = @This();

        pub fn create(allocator: std.mem.Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const mini_editor = try tui.MiniEditor.create(allocator);
            errdefer mini_editor.destroy();
            self.* = .{
                .allocator = allocator,
                .mini_editor = mini_editor,
            };
            try self.commands.init(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            var mode = try keybind.mode("mini/text_input", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self), .mini_editor = self.mini_editor } };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            self.mini_editor.destroy();
            self.allocator.destroy(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var text: []const u8 = undefined;

            if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.mini_editor.buffer.paste(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            return false;
        }

        fn message(comptime fmt: anytype, args: anytype) void {
            var buf: [256]u8 = undefined;
            tp.self_pid().send(.{ "message", std.fmt.bufPrint(&buf, fmt, args) catch @panic("too large") }) catch {};
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                try self.mini_editor.buffer.clear();
            }
            pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(_: *Self, ctx: Ctx) Result {
                command.executeName("exit_mini_mode", ctx) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                try self.mini_editor.buffer.delete_backward();
            }
            pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var egc: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&egc)}))
                    return error.InvalidTextInputInsertCodePointArgument;
                try self.mini_editor.buffer.insert_code_point(@intCast(egc));
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidTextInputInsertBytesArgument;
                try self.mini_editor.buffer.insert(bytes);
            }
            pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_select(self: *Self, _: Ctx) Result {
                options.select(self);
            }
            pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidTextInputPasteArgument;
                try self.mini_editor.buffer.paste(bytes);
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
        };
    };
}
