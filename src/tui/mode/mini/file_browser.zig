const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const root = @import("root");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const mainview = @import("../../mainview.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
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

        const Self = @This();

        const Entry = struct {
            name: []const u8,
            type: enum { dir, file, link },
        };

        pub fn create(allocator: std.mem.Allocator, _: command.Context) !*Self {
            const self: *Self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .file_path = std.ArrayList(u8).init(allocator),
                .query = std.ArrayList(u8).init(allocator),
                .match = std.ArrayList(u8).init(allocator),
                .entries = std.ArrayList(Entry).init(allocator),
            };
            try tui.current().message_filters.add(MessageFilter.bind(self, receive_path_entry));
            try options.load_entries(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            return self;
        }

        pub fn deinit(self: *Self) void {
            tui.current().message_filters.remove_ptr(self);
            self.clear_entries();
            self.entries.deinit();
            self.match.deinit();
            self.query.deinit();
            self.file_path.deinit();
            self.allocator.destroy(self);
        }

        pub fn handler(self: *Self) EventHandler {
            return EventHandler.to_owned(self);
        }

        pub fn name(self: *Self) []const u8 {
            return options.name(self);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var evtype: u32 = undefined;
            var keypress: u32 = undefined;
            var egc: u32 = undefined;
            var modifiers: u32 = undefined;

            defer {
                if (tui.current().mini_mode) |*mini_mode| {
                    mini_mode.text = self.file_path.items;
                    mini_mode.cursor = self.file_path.items.len;
                }
            }

            if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
                self.mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            return false;
        }

        fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
            switch (evtype) {
                event_type.PRESS => try self.mapPress(keypress, egc, modifiers),
                event_type.REPEAT => try self.mapPress(keypress, egc, modifiers),
                event_type.RELEASE => try self.mapRelease(keypress, egc, modifiers),
                else => {},
            }
        }

        fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) !void {
            const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
            return switch (modifiers) {
                mod.CTRL => switch (keynormal) {
                    'Q' => self.cmd("quit", .{}),
                    'V' => self.cmd("system_paste", .{}),
                    'U' => self.file_path.clearRetainingCapacity(),
                    'G' => self.cancel(),
                    'C' => self.cancel(),
                    'L' => self.cmd("scroll_view_center", .{}),
                    'I' => self.insert_bytes("\t"),
                    key.SPACE => self.cancel(),
                    key.BACKSPACE => self.delete_to_previous_path_segment(),
                    else => {},
                },
                mod.ALT => switch (keynormal) {
                    'V' => self.cmd("system_paste", .{}),
                    else => {},
                },
                mod.ALT | mod.SHIFT => switch (keynormal) {
                    'V' => self.cmd("system_paste", .{}),
                    else => {},
                },
                mod.SHIFT => switch (keypress) {
                    key.TAB => self.reverse_complete_file(),
                    else => if (!key.synthesized_p(keypress))
                        self.insert_code_point(egc)
                    else {},
                },
                0 => switch (keypress) {
                    key.UP => self.reverse_complete_file(),
                    key.DOWN => self.try_complete_file(),
                    key.TAB => self.try_complete_file(),
                    key.ESC => self.cancel(),
                    key.ENTER => self.select(),
                    key.BACKSPACE => if (self.file_path.items.len > 0) {
                        self.complete_trigger_count = 0;
                        self.file_path.shrinkRetainingCapacity(self.file_path.items.len - 1);
                    },
                    else => if (!key.synthesized_p(keypress))
                        self.insert_code_point(egc)
                    else {},
                },
                else => {},
            };
        }

        fn mapRelease(_: *Self, _: u32, _: u32, _: u32) !void {}

        fn insert_code_point(self: *Self, c: u32) !void {
            self.complete_trigger_count = 0;
            var buf: [32]u8 = undefined;
            const bytes = try ucs32_to_utf8(&[_]u32{c}, &buf);
            try self.file_path.appendSlice(buf[0..bytes]);
        }

        fn insert_bytes(self: *Self, bytes: []const u8) !void {
            self.complete_trigger_count = 0;
            try self.file_path.appendSlice(bytes);
        }

        fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
            self.complete_trigger_count = 0;
            return command.executeName(name_, ctx);
        }

        fn cancel(_: *Self) void {
            command.executeName("exit_mini_mode", .{}) catch {};
        }

        fn select(self: *Self) void {
            options.select(self);
        }

        fn clear_entries(self: *Self) void {
            for (self.entries.items) |entry| self.allocator.free(entry.name);
            self.entries.clearRetainingCapacity();
        }

        fn try_complete_file(self: *Self) !void {
            self.complete_trigger_count += 1;
            if (self.complete_trigger_count == 1) {
                self.query.clearRetainingCapacity();
                self.match.clearRetainingCapacity();
                self.clear_entries();
                if (try root.is_directory(self.file_path.items)) {
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

        fn reverse_complete_file(self: *Self) !void {
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

        fn receive_path_entry(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            if (try m.match(.{ "PRJ", tp.more })) {
                self.process_project_manager(m) catch |e| return tp.exit_error(e, @errorReturnTrace());
                return true;
            }
            return false;
        }

        fn process_project_manager(self: *Self, m: tp.message) !void {
            defer {
                if (tui.current().mini_mode) |*mini_mode| {
                    mini_mode.text = self.file_path.items;
                    mini_mode.cursor = self.file_path.items.len;
                }
            }
            var count: usize = undefined;
            if (try m.match(.{ "PRJ", "path_entry", tp.more })) {
                return self.process_path_entry(m);
            } else if (try m.match(.{ "PRJ", "path_done", tp.any, tp.any, tp.extract(&count) })) {
                try self.do_complete();
            } else {
                log.logger("file_browser").err("receive", tp.unexpected(m));
            }
        }

        fn process_path_entry(self: *Self, m: tp.message) !void {
            var path: []const u8 = undefined;
            var file_name: []const u8 = undefined;
            if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&path), "DIR", tp.extract(&file_name) })) {
                (try self.entries.addOne()).* = .{ .name = try self.allocator.dupe(u8, file_name), .type = .dir };
            } else if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&path), "LINK", tp.extract(&file_name) })) {
                (try self.entries.addOne()).* = .{ .name = try self.allocator.dupe(u8, file_name), .type = .link };
            } else if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&path), "FILE", tp.extract(&file_name) })) {
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
            } else {
                try self.construct_path(self.query.items, self.entries.items[self.complete_trigger_count - 1], self.complete_trigger_count - 1);
            }
            log.logger("file_browser").print("{d}/{d}", .{ self.matched_entry + 1, self.entries.items.len });
        }

        fn construct_path(self: *Self, path_: []const u8, entry: Entry, entry_no: usize) !void {
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
                log.logger("file_browser").print("no match for '{s}'", .{self.match.items});
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
    };
}
