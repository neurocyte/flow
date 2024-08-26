const std = @import("std");
const tp = @import("thespian");
const log = @import("log");

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

const Self = @This();

a: std.mem.Allocator,
file_path: std.ArrayList(u8),
query: std.ArrayList(u8),
query_pending: bool = false,
complete_trigger_count: usize = 0,

pub fn create(a: std.mem.Allocator, _: command.Context) !*Self {
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .file_path = std.ArrayList(u8).init(a),
        .query = std.ArrayList(u8).init(a),
    };
    try tui.current().message_filters.add(MessageFilter.bind(self, receive_project_manager));
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        if (editor.is_dirty()) return tp.exit("unsaved changes");
        if (editor.file_path) |old_path|
            if (std.mem.lastIndexOf(u8, old_path, "/")) |pos|
                try self.file_path.appendSlice(old_path[0 .. pos + 1]);
        if (editor.get_primary().selection) |sel| ret: {
            const text = editor.get_selection(sel, self.a) catch break :ret;
            defer self.a.free(text);
            if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
                self.file_path.clearRetainingCapacity();
            try self.file_path.appendSlice(text);
        }
    };
    return self;
}

pub fn deinit(self: *Self) void {
    tui.current().message_filters.remove_ptr(self);
    self.query.deinit();
    self.file_path.deinit();
    self.a.destroy(self);
}

pub fn handler(self: *Self) EventHandler {
    return EventHandler.to_owned(self);
}

pub fn name(_: *Self) []const u8 {
    return " open";
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
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        0 => switch (keypress) {
            key.TAB => self.try_complete_file(),
            key.ESC => self.cancel(),
            key.ENTER => self.navigate(),
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

fn navigate(self: *Self) void {
    if (self.file_path.items.len > 0)
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = self.file_path.items } }) catch {};
    command.executeName("exit_mini_mode", .{}) catch {};
}

fn try_complete_file(self: *Self) !void {
    self.complete_trigger_count += 1;
    if (self.complete_trigger_count == 1) {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.file_path.items);
    }
    if (self.query_pending) return;
    self.query_pending = true;
    try project_manager.query_recent_files(self.complete_trigger_count, self.query.items);
}

fn receive_project_manager(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
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
    var file_name: []const u8 = undefined;
    var query: []const u8 = undefined;
    if (try m.match(.{ "PRJ", "recent", tp.any, tp.extract(&file_name), tp.any })) {
        self.file_path.clearRetainingCapacity();
        try self.file_path.appendSlice(file_name);
        tui.need_render();
    } else if (try m.match(.{ "PRJ", "recent", tp.any, tp.extract(&file_name) })) {
        self.file_path.clearRetainingCapacity();
        try self.file_path.appendSlice(file_name);
        tui.need_render();
    } else if (try m.match(.{ "PRJ", "recent_done", tp.any, tp.extract(&query) })) {
        self.query_pending = false;
        if (!std.mem.eql(u8, self.query.items, query))
            try self.try_complete_file();
    } else {
        log.logger("open_recent").err("receive", tp.unexpected(m));
    }
}

fn delete_to_previous_path_segment(self: *Self) void {
    self.complete_trigger_count = 0;
    if (self.file_path.items.len == 0) return;
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
