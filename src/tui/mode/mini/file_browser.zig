const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("root");

const input = @import("input");
const keybind = @import("keybind");
const project_manager = @import("project_manager");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");

const max_complete_paths = 1024;

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        file_path: std.ArrayList(u8),
        query: std.ArrayList(u8),
        match: std.ArrayList(u8),
        entries: std.ArrayList(Entry),
        complete_trigger_count: usize = 0,
        matched_entry: usize = 0,
        commands: Commands = undefined,

        const Commands = command.Collection(cmds);
        const Self = @This();

        const Entry = struct {
            name: []const u8,
            type: enum { dir, file, link },
        };

        pub fn create(allocator: std.mem.Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self: *Self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .file_path = std.ArrayList(u8).init(allocator),
                .query = std.ArrayList(u8).init(allocator),
                .match = std.ArrayList(u8).init(allocator),
                .entries = std.ArrayList(Entry).init(allocator),
            };
            try self.commands.init(self);
            try tui.current().message_filters.add(MessageFilter.bind(self, receive_path_entry));
            try options.load_entries(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            const input_handler, const keybind_hints = try keybind.mode.mini.file_browser.create(allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            return .{
                .{
                    .input_handler = input_handler,
                    .event_handler = EventHandler.to_owned(self),
                    .keybind_hints = keybind_hints,
                },
                .{
                    .name = options.name(self),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            tui.current().message_filters.remove_ptr(self);
            self.clear_entries();
            self.entries.deinit();
            self.match.deinit();
            self.query.deinit();
            self.file_path.deinit();
            self.allocator.destroy(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var text: []const u8 = undefined;

            if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.file_path.appendSlice(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            self.update_mini_mode_text();
            return false;
        }

        fn clear_entries(self: *Self) void {
            for (self.entries.items) |entry| self.allocator.free(entry.name);
            self.entries.clearRetainingCapacity();
        }

        fn try_complete_file(self: *Self) project_manager.Error!void {
            self.complete_trigger_count += 1;
            if (self.complete_trigger_count == 1) {
                self.query.clearRetainingCapacity();
                self.match.clearRetainingCapacity();
                self.clear_entries();
                if (root.is_directory(self.file_path.items)) {
                    try self.query.appendSlice(self.file_path.items);
                } else if (self.file_path.items.len > 0) blk: {
                    const basename_begin = std.mem.lastIndexOfScalar(u8, self.file_path.items, std.fs.path.sep) orelse {
                        try self.match.appendSlice(self.file_path.items);
                        break :blk;
                    };
                    try self.query.appendSlice(self.file_path.items[0 .. basename_begin + 1]);
                    try self.match.appendSlice(self.file_path.items[basename_begin + 1 ..]);
                }
                // log.logger("file_browser").print("query: '{s}' match: '{s}'", .{ self.query.items, self.match.items });
                try project_manager.request_path_files(max_complete_paths, self.query.items);
            } else {
                try self.do_complete();
            }
        }

        fn reverse_complete_file(self: *Self) error{OutOfMemory}!void {
            if (self.complete_trigger_count < 2) {
                self.complete_trigger_count = 0;
                self.file_path.clearRetainingCapacity();
                if (self.match.items.len > 0) {
                    try self.construct_path(self.query.items, .{ .name = self.match.items, .type = .file }, 0);
                } else {
                    try self.file_path.appendSlice(self.query.items);
                }
                if (tui.current().mini_mode) |*mini_mode| {
                    mini_mode.text = self.file_path.items;
                    mini_mode.cursor = self.file_path.items.len;
                }
                return;
            }
            self.complete_trigger_count -= 1;
            try self.do_complete();
        }

        fn receive_path_entry(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
            if (try cbor.match(m.buf, .{ "PRJ", tp.more })) {
                try self.process_project_manager(m);
                return true;
            }
            if (try cbor.match(m.buf, .{ "exit", "error.FileNotFound" })) {
                message("path not found", .{});
                return true;
            }
            return false;
        }

        fn process_project_manager(self: *Self, m: tp.message) MessageFilter.Error!void {
            defer {
                if (tui.current().mini_mode) |*mini_mode| {
                    mini_mode.text = self.file_path.items;
                    mini_mode.cursor = self.file_path.items.len;
                }
            }
            var count: usize = undefined;
            if (try cbor.match(m.buf, .{ "PRJ", "path_entry", tp.more })) {
                return self.process_path_entry(m);
            } else if (try cbor.match(m.buf, .{ "PRJ", "path_done", tp.any, tp.any, tp.extract(&count) })) {
                try self.do_complete();
            } else {
                log.logger("file_browser").err("receive", tp.unexpected(m));
            }
        }

        fn process_path_entry(self: *Self, m: tp.message) MessageFilter.Error!void {
            var path: []const u8 = undefined;
            var file_name: []const u8 = undefined;
            if (try cbor.match(m.buf, .{ tp.any, tp.any, tp.any, tp.extract(&path), "DIR", tp.extract(&file_name) })) {
                (try self.entries.addOne()).* = .{ .name = try self.allocator.dupe(u8, file_name), .type = .dir };
            } else if (try cbor.match(m.buf, .{ tp.any, tp.any, tp.any, tp.extract(&path), "LINK", tp.extract(&file_name) })) {
                (try self.entries.addOne()).* = .{ .name = try self.allocator.dupe(u8, file_name), .type = .link };
            } else if (try cbor.match(m.buf, .{ tp.any, tp.any, tp.any, tp.extract(&path), "FILE", tp.extract(&file_name) })) {
                (try self.entries.addOne()).* = .{ .name = try self.allocator.dupe(u8, file_name), .type = .file };
            } else {
                log.logger("file_browser").err("receive", tp.unexpected(m));
            }
            tui.need_render();
        }

        fn do_complete(self: *Self) !void {
            self.complete_trigger_count = @min(self.complete_trigger_count, self.entries.items.len);
            self.file_path.clearRetainingCapacity();
            if (self.match.items.len > 0) {
                try self.match_path();
            } else if (self.entries.items.len > 0) {
                try self.construct_path(self.query.items, self.entries.items[self.complete_trigger_count - 1], self.complete_trigger_count - 1);
            } else {
                try self.construct_path(self.query.items, .{ .name = "", .type = .file }, 0);
            }
            message("{d}/{d}", .{ self.matched_entry + 1, self.entries.items.len });
        }

        fn construct_path(self: *Self, path_: []const u8, entry: Entry, entry_no: usize) error{OutOfMemory}!void {
            self.matched_entry = entry_no;
            const path = project_manager.normalize_file_path(path_);
            try self.file_path.appendSlice(path);
            if (path.len > 0 and path[path.len - 1] != std.fs.path.sep)
                try self.file_path.append(std.fs.path.sep);
            try self.file_path.appendSlice(entry.name);
            if (entry.type == .dir)
                try self.file_path.append(std.fs.path.sep);
        }

        fn match_path(self: *Self) !void {
            var matched: usize = 0;
            var last: ?Entry = null;
            var last_no: usize = 0;
            for (self.entries.items, 0..) |entry, i| {
                if (entry.name.len >= self.match.items.len and
                    std.mem.eql(u8, self.match.items, entry.name[0..self.match.items.len]))
                {
                    matched += 1;
                    if (matched == self.complete_trigger_count) {
                        try self.construct_path(self.query.items, entry, i);
                        return;
                    }
                    last = entry;
                    last_no = i;
                }
            }
            if (last) |entry| {
                try self.construct_path(self.query.items, entry, last_no);
                self.complete_trigger_count = matched;
            } else {
                message("no match for '{s}'", .{self.match.items});
                try self.construct_path(self.query.items, .{ .name = self.match.items, .type = .file }, 0);
            }
        }

        fn delete_to_previous_path_segment(self: *Self) void {
            self.complete_trigger_count = 0;
            if (self.file_path.items.len == 0) return;
            if (self.file_path.items.len == 1) {
                self.file_path.clearRetainingCapacity();
                return;
            }
            const path = if (self.file_path.items[self.file_path.items.len - 1] == std.fs.path.sep)
                self.file_path.items[0 .. self.file_path.items.len - 2]
            else
                self.file_path.items;
            if (std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep)) |pos| {
                self.file_path.items.len = pos + 1;
            } else {
                self.file_path.clearRetainingCapacity();
            }
        }

        fn message(comptime fmt: anytype, args: anytype) void {
            var buf: [256]u8 = undefined;
            tp.self_pid().send(.{ "message", std.fmt.bufPrint(&buf, fmt, args) catch @panic("too large") }) catch {};
        }

        fn update_mini_mode_text(self: *Self) void {
            if (tui.current().mini_mode) |*mini_mode| {
                mini_mode.text = self.file_path.items;
                mini_mode.cursor = self.file_path.items.len;
            }
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                self.complete_trigger_count = 0;
                self.file_path.clearRetainingCapacity();
                self.update_mini_mode_text();
            }
            pub const mini_mode_reset_meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
                command.executeName("exit_mini_mode", .{}) catch {};
            }
            pub const mini_mode_cancel_meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_to_previous_path_segment(self: *Self, _: Ctx) Result {
                self.delete_to_previous_path_segment();
                self.update_mini_mode_text();
            }
            pub const mini_mode_delete_to_previous_path_segment_meta = .{ .description = "Delete to previous path segment" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                if (self.file_path.items.len > 0) {
                    self.complete_trigger_count = 0;
                    self.file_path.shrinkRetainingCapacity(self.file_path.items.len - 1);
                }
                self.update_mini_mode_text();
            }
            pub const mini_mode_delete_backwards_meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_try_complete_file(self: *Self, _: Ctx) Result {
                self.try_complete_file() catch |e| return tp.exit_error(e, @errorReturnTrace());
                self.update_mini_mode_text();
            }
            pub const mini_mode_try_complete_file_meta = .{ .description = "Complete file" };

            pub fn mini_mode_try_complete_file_forward(self: *Self, ctx: Ctx) Result {
                self.complete_trigger_count = 0;
                return mini_mode_try_complete_file(self, ctx);
            }
            pub const mini_mode_try_complete_file_forward_meta = .{ .description = "Complete file forward" };

            pub fn mini_mode_reverse_complete_file(self: *Self, _: Ctx) Result {
                self.reverse_complete_file() catch |e| return tp.exit_error(e, @errorReturnTrace());
                self.update_mini_mode_text();
            }
            pub const mini_mode_reverse_complete_file_meta = .{ .description = "Reverse complete file" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var egc: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&egc)}))
                    return error.InvalidArgument;
                self.complete_trigger_count = 0;
                var buf: [32]u8 = undefined;
                const bytes = try input.ucs32_to_utf8(&[_]u32{egc}, &buf);
                try self.file_path.appendSlice(buf[0..bytes]);
                self.update_mini_mode_text();
            }
            pub const mini_mode_insert_code_point_meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidArgument;
                self.complete_trigger_count = 0;
                try self.file_path.appendSlice(bytes);
                self.update_mini_mode_text();
            }
            pub const mini_mode_insert_bytes_meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_select(self: *Self, _: Ctx) Result {
                options.select(self);
                self.update_mini_mode_text();
            }
            pub const mini_mode_select_meta = .{ .description = "Select" };

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                return mini_mode_insert_bytes(self, ctx);
            }
            pub const mini_mode_paste_meta = .{ .arguments = &.{.string} };
        };
    };
}
