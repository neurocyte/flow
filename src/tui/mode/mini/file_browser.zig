const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const file_type_config = @import("file_type_config");
const root = @import("soft_root").root;

const input = @import("input");
const keybind = @import("keybind");
const project_manager = @import("project_manager");
const command = @import("command");
const EventHandler = @import("EventHandler");
const Buffer = @import("Buffer");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");

const max_complete_paths = 1024;

pub const SelectMode = enum {
    normal,
    alternate,
};

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mini_editor: *tui.MiniEditor,
        query: std.ArrayList(u8),
        match: std.ArrayList(u8),
        entries: std.ArrayList(Entry),
        complete_trigger_count: usize = 0,
        total_matches: usize = 0,
        matched_entry: usize = 0,
        select: SelectMode = .normal,
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
            const mini_editor = try tui.MiniEditor.create(allocator);
            errdefer mini_editor.destroy();
            self.* = .{
                .allocator = allocator,
                .mini_editor = mini_editor,
                .query = .empty,
                .match = .empty,
                .entries = .empty,
            };
            try self.commands.init(self);
            try tui.message_filters().add(MessageFilter.bind(self, receive_path_entry));
            try options.load_entries(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            self.mini_editor.buffer.clear_history();
            self.update_mini_mode_prefix();
            self.mini_editor.on_change = .bind(self, on_input_change);
            var mode = try keybind.mode("mini/file_browser", allocator, .{
                .insert_command = "mini_mode_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            return .{ mode, .{ .name = options.name(self), .mini_editor = self.mini_editor } };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            tui.message_filters().remove_ptr(self);
            self.clear_entries();
            self.entries.deinit(self.allocator);
            self.match.deinit(self.allocator);
            self.query.deinit(self.allocator);
            self.mini_editor.destroy();
            self.allocator.destroy(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var text: []const u8 = undefined;

            if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.complete_trigger_count = 0;
                self.mini_editor.buffer.paste(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            self.update_mini_mode_prefix();
            return false;
        }

        fn on_input_change(self: *Self) void {
            self.complete_trigger_count = 0;
            self.update_mini_mode_prefix();
        }

        pub fn file_path(self: *const Self) []const u8 {
            return self.mini_editor.bytes();
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
            const path = self.file_path();
            const probed = tui.probed(path) orelse {
                var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
                const complete: cbor.Raw = .{ .bytes = cbor.fmt(&buf, .{ "MINI", "probed", path }) };
                tui.probe(path, .{ .file = complete, .dir = complete, .other = complete });
                return;
            };
            self.complete_trigger_count += 1;
            if (self.complete_trigger_count == 1) {
                self.query.clearRetainingCapacity();
                self.match.clearRetainingCapacity();
                self.clear_entries();
                if (probed.kind == .dir) {
                    try self.query.appendSlice(self.allocator, path);
                } else if (path.len > 0) blk: {
                    const basename_begin = std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep) orelse {
                        try self.match.appendSlice(self.allocator, path);
                        break :blk;
                    };
                    try self.query.appendSlice(self.allocator, path[0 .. basename_begin + 1]);
                    try self.match.appendSlice(self.allocator, path[basename_begin + 1 ..]);
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
                if (self.match.items.len > 0) {
                    try self.construct_path(self.query.items, self.match.items, .file, 0);
                } else {
                    try self.mini_editor.buffer.set_text(self.query.items);
                }
                self.update_mini_mode_prefix();
                return;
            }
            self.complete_trigger_count -= 1;
            try self.do_complete();
        }

        fn receive_path_entry(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
            var path: []const u8 = undefined;
            if (try cbor.match(m.buf, .{ "MINI", "probed", tp.extract(&path) })) {
                if (std.mem.eql(u8, path, self.file_path()))
                    self.try_complete_file() catch {};
                return true;
            }
            if (try cbor.match(m.buf, .{ "PRJ", tp.more }))
                return self.process_project_manager(m);
            if (try cbor.match(m.buf, .{ "exit", "error.FileNotFound" })) {
                message("path not found", .{});
                return true;
            }
            return false;
        }

        fn process_project_manager(self: *Self, m: tp.message) MessageFilter.Error!bool {
            var count: usize = undefined;
            if (try cbor.match(m.buf, .{ "PRJ", "path_entry", tp.more })) {
                defer self.update_mini_mode_prefix();
                try self.process_path_entry(m);
            } else if (try cbor.match(m.buf, .{ "PRJ", "path_done", tp.any, tp.any, tp.extract(&count) })) {
                defer self.update_mini_mode_prefix();
                try self.do_complete();
            } else return false;
            return true;
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
            tui.need_render(@src());
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
            var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = project_manager.normalize_file_path(path_, &file_path_buf);
            var new_path: std.ArrayList(u8) = .empty;
            defer new_path.deinit(self.allocator);
            try new_path.appendSlice(self.allocator, path);
            if (path.len > 0 and path[path.len - 1] != std.fs.path.sep)
                try new_path.append(self.allocator, std.fs.path.sep);
            try new_path.appendSlice(self.allocator, entry_name);
            if (entry_type == .dir)
                try new_path.append(self.allocator, std.fs.path.sep);
            try self.mini_editor.buffer.set_text(new_path.items);
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
            const icase_prefix = Buffer.unicode.case_fold(allocator, prefix) catch try allocator.dupe(u8, prefix);
            defer allocator.free(icase_prefix);
            const icase_str = Buffer.unicode.case_fold(allocator, str) catch try allocator.dupe(u8, str);
            defer allocator.free(icase_str);
            if (icase_str.len < icase_prefix.len) return false;
            return std.mem.eql(u8, icase_prefix, icase_str[0..icase_prefix.len]);
        }

        fn delete_to_previous_path_segment(self: *Self) !void {
            self.complete_trigger_count = 0;
            const file_path_ = self.file_path();
            if (file_path_.len < 2) return self.mini_editor.buffer.truncate(0);
            const path = if (file_path_[file_path_.len - 1] == std.fs.path.sep)
                file_path_[0 .. file_path_.len - 2]
            else
                file_path_;
            return self.mini_editor.buffer.truncate(if (std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep)) |pos| pos + 1 else 0);
        }

        fn message(comptime fmt: anytype, args: anytype) void {
            var buf: [256]u8 = undefined;
            tp.self_pid().send(.{ "message", std.fmt.bufPrint(&buf, fmt, args) catch @panic("too large") }) catch {};
        }

        fn update_mini_mode_prefix(self: *Self) void {
            const icon = if (self.entries.items.len > 0 and self.complete_trigger_count > 0)
                self.entries.items[self.complete_trigger_count - 1].icon
            else
                " ";
            var buf: [64]u8 = undefined;
            self.mini_editor.set_prefix(std.fmt.bufPrint(&buf, "{s}  ", .{icon}) catch "") catch {};
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn mini_mode_reset(self: *Self, _: Ctx) Result {
                self.complete_trigger_count = 0;
                try self.mini_editor.buffer.clear();
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_reset_meta: Meta = .{ .description = "Clear input" };

            pub fn mini_mode_cancel(_: *Self, ctx: Ctx) Result {
                command.executeName("exit_mini_mode", ctx) catch {};
            }
            pub const mini_mode_cancel_meta: Meta = .{ .description = "Cancel input" };

            pub fn mini_mode_delete_to_previous_path_segment(self: *Self, _: Ctx) Result {
                try self.delete_to_previous_path_segment();
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_delete_to_previous_path_segment_meta: Meta = .{ .description = "Delete to previous path segment" };

            pub fn mini_mode_delete_backwards(self: *Self, _: Ctx) Result {
                self.complete_trigger_count = 0;
                try self.mini_editor.buffer.delete_backward();
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn mini_mode_try_complete_file(self: *Self, _: Ctx) Result {
                self.try_complete_file() catch |e| return tp.exit_error(e, @errorReturnTrace());
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_try_complete_file_meta: Meta = .{ .description = "Complete file" };

            pub fn mini_mode_try_complete_file_forward(self: *Self, ctx: Ctx) Result {
                self.complete_trigger_count = 0;
                return mini_mode_try_complete_file(self, ctx);
            }
            pub const mini_mode_try_complete_file_forward_meta: Meta = .{ .description = "Complete file forward" };

            pub fn mini_mode_reverse_complete_file(self: *Self, _: Ctx) Result {
                self.reverse_complete_file() catch |e| return tp.exit_error(e, @errorReturnTrace());
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_reverse_complete_file_meta: Meta = .{ .description = "Reverse complete file" };

            pub fn mini_mode_insert_code_point(self: *Self, ctx: Ctx) Result {
                var egc: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&egc)}))
                    return error.InvalidFileBrowserInsertCodePointArgument;
                self.complete_trigger_count = 0;
                try self.mini_editor.buffer.insert_code_point(@intCast(egc));
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn mini_mode_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidFileBrowserInsertBytesArgument;
                self.complete_trigger_count = 0;
                try self.mini_editor.buffer.insert(bytes);
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn mini_mode_select(self: *Self, _: Ctx) Result {
                options.select(self);
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_select_meta: Meta = .{ .description = "Select" };

            pub fn mini_mode_select_alternate(self: *Self, _: Ctx) Result {
                self.select = .alternate;
                options.select(self);
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_select_alternate_meta: Meta = .{ .description = "Select alternate" };

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidFileBrowserPasteArgument;
                self.complete_trigger_count = 0;
                try self.mini_editor.buffer.paste(bytes);
                self.update_mini_mode_prefix();
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
        };
    };
}
