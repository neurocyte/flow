const tp = @import("thespian");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = @import("std").fmt;

pub fn Create(options: type) type {
    return struct {
        const Self = @This();

        const Commands = command.Collection(cmds);

        const ValueType = if (@hasDecl(options, "ValueType")) options.ValueType else usize;

        allocator: Allocator,
        mini_editor: *tui.MiniEditor,
        input: ?ValueType = null,
        start: ValueType,
        ctx: command.Context,
        commands: Commands = undefined,

        pub fn create(allocator: Allocator, ctx: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const mini_editor = try tui.MiniEditor.create(allocator);
            errdefer mini_editor.destroy();
            self.* = .{
                .allocator = allocator,
                .mini_editor = mini_editor,
                .ctx = .{ .io = ctx.io, .now = ctx.now, .args = try ctx.args.clone(allocator) },
                .start = if (@hasDecl(options, "ValueType")) ValueType{} else 0,
            };
            self.start = options.start(self);
            if (!@hasDecl(options, "ValueType")) if (self.input) |value| {
                var buf: [32]u8 = undefined;
                try mini_editor.buffer.set_text(fmt.bufPrint(&buf, "{d}", .{value}) catch "");
                mini_editor.buffer.clear_history();
                mini_editor.buffer.select_all();
            };
            mini_editor.on_change = .bind(self, on_input_change);
            try self.commands.init(self);
            var mode = try keybind.mode("mini/numeric", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self), .mini_editor = self.mini_editor } };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.ctx.args.buf);
            self.commands.deinit();
            self.mini_editor.destroy();
            self.allocator.destroy(self);
        }

        pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
            return false;
        }

        fn parse_value(text: []const u8) ?ValueType {
            return fmt.parseInt(ValueType, text, 10) catch null;
        }

        fn update(self: *Self) void {
            const text = self.mini_editor.bytes();
            self.input = if (@hasDecl(options, "parse_value")) options.parse_value(text) else parse_value(text);
        }

        fn on_input_change(self: *Self) void {
            self.update();
            options.preview(self, self.ctx);
        }

        fn is_valid(self: *Self, char: u8) bool {
            return switch (char) {
                '0'...'9' => true,
                else => @hasDecl(options, "Separator") and char == options.Separator and
                    std.mem.indexOfScalar(u8, self.mini_editor.bytes(), char) == null,
            };
        }

        fn insert_bytes(self: *Self, bytes: []const u8) !void {
            for (bytes) |c| if (self.is_valid(c)) try self.mini_editor.buffer.insert(&.{c});
            self.update();
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                try self.mini_editor.buffer.clear();
                self.update();
            }
            pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(self: *Self, ctx: Ctx) Result {
                self.input = null;
                options.cancel(self, self.ctx);
                command.executeName("exit_mini_mode", ctx) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                try self.mini_editor.buffer.delete_backward();
                self.on_input_change();
            }
            pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var keypress: usize = 0;
                if (!try ctx.args.match(.{tp.extract(&keypress)}))
                    return error.InvalidGotoInsertCodePointArgument;
                if (keypress < 0x80) try self.insert_bytes(&.{@intCast(keypress)});
                options.preview(self, self.ctx);
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidGotoInsertBytesArgument;
                try self.insert_bytes(bytes);
                options.preview(self, self.ctx);
            }
            pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                return mini_mode_insert_bytes(self, ctx);
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_select(self: *Self, ctx: Ctx) Result {
                options.apply(self, self.ctx);
                command.executeName("exit_mini_mode", ctx) catch {};
            }
            pub const mini_mode_select_meta: Meta = .{ .description = "Select" };
        };
    };
}
