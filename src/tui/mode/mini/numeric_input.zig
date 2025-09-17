const tp = @import("thespian");

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

        const ValueType = if (@hasDecl(options, "ValueType")) options.ValueType else usize;

        allocator: Allocator,
        buf: [30]u8 = undefined,
        input: ?ValueType = null,
        start: ValueType,
        ctx: command.Context,
        commands: Commands = undefined,

        pub fn create(allocator: Allocator, ctx: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .ctx = .{ .args = try ctx.args.clone(allocator) },
                .start = if (@hasDecl(options, "ValueType")) ValueType{} else 0,
            };
            self.start = options.start(self);
            try self.commands.init(self);
            var mode = try keybind.mode("mini/numeric", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self) } };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.ctx.args.buf);
            self.commands.deinit();
            self.allocator.destroy(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
            self.update_mini_mode_text();
            return false;
        }

        fn update_mini_mode_text(self: *Self) void {
            if (tui.mini_mode()) |mini_mode| {
                if (@hasDecl(options, "format_value")) {
                    mini_mode.text = options.format_value(self, self.input, &self.buf);
                } else {
                    mini_mode.text = if (self.input) |linenum|
                        (fmt.bufPrint(&self.buf, "{d}", .{linenum}) catch "")
                    else
                        "";
                }
                mini_mode.cursor = tui.egc_chunk_width(mini_mode.text, 0, 1);
            }
        }

        fn insert_char(self: *Self, char: u8) void {
            const process_digit_ = if (@hasDecl(options, "process_digit")) options.process_digit else process_digit;
            if (@hasDecl(options, "Separator")) {
                switch (char) {
                    '0'...'9' => process_digit_(@intCast(char - '0')),
                    options.Separator => options.process_separator(self),
                    else => {},
                }
            } else {
                switch (char) {
                    '0'...'9' => process_digit_(self, @intCast(char - '0')),
                    else => {},
                }
            }
        }

        fn process_digit(self: *Self, digit: u8) void {
            self.input = switch (digit) {
                0 => if (self.input) |value| value * 10 else 0,
                1...9 => if (self.input) |x| x * 10 + digit else digit,
                else => unreachable,
            };
        }

        fn insert_bytes(self: *Self, bytes: []const u8) void {
            for (bytes) |c| self.insert_char(c);
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                self.input = null;
                self.update_mini_mode_text();
            }
            pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(self: *Self, _: Ctx) Result {
                self.input = null;
                self.update_mini_mode_text();
                options.cancel(self, self.ctx);
                command.executeName("exit_mini_mode", .{}) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                if (self.input) |*input| {
                    if (@hasDecl(options, "delete")) {
                        options.delete(self, input);
                    } else {
                        const newval = if (input.* < 10) 0 else input.* / 10;
                        self.input = if (newval == 0) null else newval;
                    }
                    self.update_mini_mode_text();
                    options.preview(self, self.ctx);
                }
            }
            pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var keypress: usize = 0;
                if (!try ctx.args.match(.{tp.extract(&keypress)}))
                    return error.InvalidGotoInsertCodePointArgument;
                switch (keypress) {
                    '0'...'9' => self.insert_char(@intCast(keypress)),
                    else => {},
                }
                self.update_mini_mode_text();
                options.preview(self, self.ctx);
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidGotoInsertBytesArgument;
                self.insert_bytes(bytes);
                self.update_mini_mode_text();
                options.preview(self, self.ctx);
            }
            pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                return mini_mode_insert_bytes(self, ctx);
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_select(self: *Self, _: Ctx) Result {
                options.apply(self, self.ctx);
                command.executeName("exit_mini_mode", .{}) catch {};
            }
            pub const mini_mode_select_meta: Meta = .{ .description = "Select" };
        };
    };
}
