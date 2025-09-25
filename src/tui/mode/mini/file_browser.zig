const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const file_type_config = @import("file_type_config");
const root = @import("root");

const input = @import("input");
const keybind = @import("keybind");
const project_manager = @import("project_manager");
const command = @import("command");
const EventHandler = @import("EventHandler");
const Buffer = @import("Buffer");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");

const max_complete_paths = 1024;

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        file_path: std.ArrayList(u8),
        rendered_mini_buffer: std.ArrayListUnmanaged(u8) = .empty,
        query: std.ArrayList(u8),
        match: std.ArrayList(u8),
        entries: std.ArrayList(Entry),
        complete_trigger_count: usize = 0,
        total_matches: usize = 0,
        matched_entry: usize = 0,
        commands: Commands = undefined,

        const Commands = command.Collection(cmds);
        const Self = @This();

        const Entry = struct {
            name: []const u8,
            type: EntryType,
            file_type: []const u8,
            icon: []const u8,
            color: u24,
        };
        const EntryType = enum { dir, file, link };

        pub fn create(allocator: std.mem.Allocator, _: command.Context) !struct { tui.Mode, tui.MiniMode } {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .file_path = .empty,
                .query = .empty,
                .match = .empty,
                .entries = .empty,
            };
            try self.commands.init(self);
            try tui.message_filters().add(MessageFilter.bind(self, receive_path_entry));
            try options.load_entries(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            var mode = try keybind.mode("mini/file_browser", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self) } };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            tui.message_filters().remove_ptr(self);
            self.clear_entries();
            self.entries.deinit(self.allocator);
            self.match.deinit(self.allocator);
            self.query.deinit(self.allocator);
            self.file_path.deinit(self.allocator);
            self.rendered_mini_buffer.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var text: []const u8 = undefined;

            if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.file_path.appendSlice(self.allocator, text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            self.update_mini_mode_text();
            return false;
        }

        fn clear_entries(self: *Self) void {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.file_type);
                self.allocator.free(entry.icon);
            }
            self.entries.clearRetainingCapacity();
        }

        fn try_complete_file(self: *Self) project_manager.Error!void {
            self.complete_trigger_count += 1;
            if (self.complete_trigger_count == 1) {
                self.query.clearRetainingCapacity();
                self.match.clearRetainingCapacity();
                self.clear_entries();
                if (root.is_directory(self.file_path.items)) {
                    try self.query.appendSlice(self.allocator, self.file_path.items);
                } else if (self.file_path.items.len > 0) blk: {
                    const basename_begin = std.mem.lastIndexOfScalar(u8, self.file_path.items, std.fs.path.sep) orelse {
                        try self.match.appendSlice(self.allocator, self.file_path.items);
                        break :blk;
                    };
                    try self.query.appendSlice(self.allocator, self.file_path.items[0 .. basename_begin + 1]);
                    try self.match.appendSlice(self.allocator, self.file_path.items[basename_begin + 1 ..]);
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
                    try self.construct_path(self.query.items, self.match.items, .file, 0);
                } else {
                    try self.file_path.appendSlice(self.allocator, self.query.items);
                }
                self.update_mini_mode_text();
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
            defer self.update_mini_mode_text();
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
            var file_type: []const u8 = undefined;
            var icon: []const u8 = undefined;
            var color: u24 = undefined;
            if (try cbor.match(m.buf, .{ tp.any, tp.any, tp.any, tp.extract(&path), "DIR", tp.extract(&file_name), tp.extract(&file_type), tp.extract(&icon), tp.extract(&color) })) {
                try self.add_entry(file_name, .dir, file_type, icon, color);
            } else if (try cbor.match(m.buf, .{ tp.any, tp.any, tp.any, tp.extract(&path), "LINK", tp.extract(&file_name), tp.extract(&file_type), tp.extract(&icon), tp.extract(&color) })) {
                try self.add_entry(file_name, .link, file_type, icon, color);
            } else if (try cbor.match(m.buf, .{ tp.any, tp.any, tp.any, tp.extract(&path), "FILE", tp.extract(&file_name), tp.extract(&file_type), tp.extract(&icon), tp.extract(&color) })) {
                try self.add_entry(file_name, .file, file_type, icon, color);
            } else {
                log.logger("file_browser").err("receive", tp.unexpected(m));
            }
            tui.need_render();
        }

        fn add_entry(self: *Self, file_name: []const u8, entry_type: EntryType, file_type: []const u8, icon: []const u8, color: u24) !void {
            (try self.entries.addOne(self.allocator)).* = .{
                .name = try self.allocator.dupe(u8, file_name),
                .type = entry_type,
                .file_type = try self.allocator.dupe(u8, file_type),
                .icon = try self.allocator.dupe(u8, icon),
                .color = color,
            };
        }

        fn do_complete(self: *Self) !void {
            self.complete_trigger_count = @min(self.complete_trigger_count, self.entries.items.len);
            self.file_path.clearRetainingCapacity();
            const match_number = self.complete_trigger_count;
            if (self.match.items.len > 0) {
                try self.match_path();
                if (self.total_matches == 1)
                    self.complete_trigger_count = 0;
            } else if (self.entries.items.len > 0) {
                const entry = self.entries.items[self.complete_trigger_count - 1];
                try self.construct_path(self.query.items, entry.name, entry.type, self.complete_trigger_count - 1);
            } else {
                try self.construct_path(self.query.items, "", .file, 0);
            }
            if (self.match.items.len > 0)
                if (self.total_matches > 1)
                    message("{d}/{d} ({d}/{d} matches)", .{ self.matched_entry + 1, self.entries.items.len, match_number, self.total_matches })
                else
                    message("{d}/{d} ({d} match)", .{ self.matched_entry + 1, self.entries.items.len, self.total_matches })
            else
                message("{d}/{d}", .{ self.matched_entry + 1, self.entries.items.len });
        }

        fn construct_path(self: *Self, path_: []const u8, entry_name: []const u8, entry_type: EntryType, entry_no: usize) error{OutOfMemory}!void {
            self.matched_entry = entry_no;
            const path = project_manager.normalize_file_path(path_);
            try self.file_path.appendSlice(self.allocator, path);
            if (path.len > 0 and path[path.len - 1] != std.fs.path.sep)
                try self.file_path.append(self.allocator, std.fs.path.sep);
            try self.file_path.appendSlice(self.allocator, entry_name);
            if (entry_type == .dir)
                try self.file_path.append(self.allocator, std.fs.path.sep);
        }

        fn match_path(self: *Self) !void {
            var found_match: ?usize = null;
            var matched: usize = 0;
            var last: ?Entry = null;
            var last_no: usize = 0;
            for (self.entries.items, 0..) |entry, i| {
                if (try prefix_compare_icase(self.allocator, self.match.items, entry.name)) {
                    matched += 1;
                    if (matched == self.complete_trigger_count) {
                        try self.construct_path(self.query.items, entry.name, entry.type, i);
                        found_match = i;
                    }
                    last = entry;
                    last_no = i;
                }
            }
            self.total_matches = matched;
            if (found_match) |_| return;
            if (last) |entry| {
                try self.construct_path(self.query.items, entry.name, entry.type, last_no);
                self.complete_trigger_count = matched;
            } else {
                message("no match for '{s}'", .{self.match.items});
                try self.construct_path(self.query.items, self.match.items, .file, 0);
            }
        }

        fn prefix_compare_icase(allocator: std.mem.Allocator, prefix: []const u8, str: []const u8) error{OutOfMemory}!bool {
            const icase_prefix = Buffer.unicode.get_letter_casing().toLowerStr(allocator, prefix) catch try allocator.dupe(u8, prefix);
            defer allocator.free(icase_prefix);
            const icase_str = Buffer.unicode.get_letter_casing().toLowerStr(allocator, str) catch try allocator.dupe(u8, str);
            defer allocator.free(icase_str);
            if (icase_str.len < icase_prefix.len) return false;
            return std.mem.eql(u8, icase_prefix, icase_str[0..icase_prefix.len]);
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
            if (tui.mini_mode()) |mini_mode| {
                const icon = if (self.entries.items.len > 0 and self.complete_trigger_count > 0)
                    self.entries.items[self.complete_trigger_count - 1].icon
                else
                    " ";
                self.rendered_mini_buffer.clearRetainingCapacity();
                const writer = self.rendered_mini_buffer.writer(self.allocator);
                writer.print("{s}  {s}", .{ icon, self.file_path.items }) catch {};
                mini_mode.text = self.rendered_mini_buffer.items;
                mini_mode.cursor = tui.egc_chunk_width(self.file_path.items, 0, 1) + 3;
            }
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                self.complete_trigger_count = 0;
                self.file_path.clearRetainingCapacity();
                self.update_mini_mode_text();
            }
            pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(_: *Self, _: Ctx) Result {
                command.executeName("exit_mini_mode", .{}) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_to_previous_path_segment(self: *Self, _: Ctx) Result {
                self.delete_to_previous_path_segment();
                self.update_mini_mode_text();
            }
            pub const mini_mode_delete_to_previous_path_segment_meta: Meta = .{ .description = "Delete to previous path segment" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                if (self.file_path.items.len > 0) {
                    self.complete_trigger_count = 0;
                    self.file_path.shrinkRetainingCapacity(self.file_path.items.len - tui.egc_last(self.file_path.items).len);
                }
                self.update_mini_mode_text();
            }
            pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_try_complete_file(self: *Self, _: Ctx) Result {
                self.try_complete_file() catch |e| return tp.exit_error(e, @errorReturnTrace());
                self.update_mini_mode_text();
            }
            pub const mini_mode_try_complete_file_meta: Meta = .{ .description = "Complete file" };

            pub fn mini_mode_try_complete_file_forward(self: *Self, ctx: Ctx) Result {
                self.complete_trigger_count = 0;
                return mini_mode_try_complete_file(self, ctx);
            }
            pub const mini_mode_try_complete_file_forward_meta: Meta = .{ .description = "Complete file forward" };

            pub fn mini_mode_reverse_complete_file(self: *Self, _: Ctx) Result {
                self.reverse_complete_file() catch |e| return tp.exit_error(e, @errorReturnTrace());
                self.update_mini_mode_text();
            }
            pub const mini_mode_reverse_complete_file_meta: Meta = .{ .description = "Reverse complete file" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var egc: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&egc)}))
                    return error.InvalidFileBrowserInsertCodePointArgument;
                self.complete_trigger_count = 0;
                var buf: [32]u8 = undefined;
                const bytes = try input.ucs32_to_utf8(&[_]u32{egc}, &buf);
                try self.file_path.appendSlice(self.allocator, buf[0..bytes]);
                self.update_mini_mode_text();
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidFileBrowserInsertBytesArgument;
                self.complete_trigger_count = 0;
                try self.file_path.appendSlice(self.allocator, bytes);
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
