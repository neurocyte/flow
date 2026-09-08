const std = @import("std");
const cbor = @import("cbor");
const editor = @import("editor.zig");

const Self = @This();

pub const ActivateMode = enum { normal, alternate };
pub const State = enum { idle, adding, done };
pub const Direction = enum { forwards, backwards };

pub const Entry = struct {
    path: []const u8,
    begin_line: usize,
    begin_pos: usize,
    end_line: usize,
    end_pos: usize,
    lines: []const u8,
    severity: editor.Diagnostic.Severity = .Information,
    pos_type: editor.PosType,
};

pub const name_diagnostics = "diagnostics";
pub const name_references = "references";
pub const name_find_in_files = "find_in_files";
pub const name_terminal_links = "terminal_links";

allocator: std.mem.Allocator,
name: []const u8, // owned
label: []const u8, // owned
entries: std.ArrayList(Entry) = .empty,
view_pos: usize = 0,
selected: ?usize = null,
state: State = .done,
next_command: ?[]const u8 = null,
prev_command: ?[]const u8 = null,

fn label_for(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, name_diagnostics)) return "Diagnostics";
    if (std.mem.eql(u8, name, name_references)) return "References";
    if (std.mem.eql(u8, name, name_find_in_files)) return "Find";
    if (std.mem.eql(u8, name, name_terminal_links)) return "Links";
    return name;
}

pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .label = try allocator.dupe(u8, label_for(name)),
    };
    if (std.mem.eql(u8, name, name_diagnostics)) {
        self.next_command = "goto_next_diagnostic";
        self.prev_command = "goto_prev_diagnostic";
    }
    return self;
}

pub fn deinit(self: *Self) void {
    self.free_entries();
    self.entries.deinit(self.allocator);
    self.allocator.free(self.name);
    self.allocator.free(self.label);
    self.allocator.destroy(self);
}

fn free_entries(self: *Self) void {
    for (self.entries.items) |entry| {
        self.allocator.free(entry.path);
        self.allocator.free(entry.lines);
    }
}

pub fn reset(self: *Self) void {
    self.free_entries();
    self.entries.clearRetainingCapacity();
    self.view_pos = 0;
    self.selected = null;
    self.state = .done;
}

fn entry_less_than(_: void, a: Entry, b: Entry) bool {
    const path_order = std.mem.order(u8, a.path, b.path);
    if (path_order != .eq) return path_order == .lt;
    if (a.begin_line != b.begin_line) return a.begin_line < b.begin_line;
    return a.begin_pos < b.begin_pos;
}

pub fn add(self: *Self, entry_: Entry) !void {
    const path = try self.allocator.dupe(u8, entry_.path);
    errdefer self.allocator.free(path);
    const lines = try self.allocator.dupe(u8, entry_.lines);
    errdefer self.allocator.free(lines);
    const entry = try self.entries.addOne(self.allocator);
    entry.* = entry_;
    entry.path = path;
    entry.lines = lines;
    std.mem.sort(Entry, self.entries.items, {}, entry_less_than);
}

pub fn len(self: *const Self) usize {
    return self.entries.items.len;
}

pub fn is_empty(self: *const Self) bool {
    return self.entries.items.len == 0;
}

pub fn write_state(self: *Self, writer: *std.Io.Writer) !void {
    try cbor.writeArrayHeader(writer, 4);
    try cbor.writeValue(writer, self.name);
    try cbor.writeValue(writer, self.view_pos);
    try cbor.writeValue(writer, self.selected);
    try cbor.writeArrayHeader(writer, self.entries.items.len);
    for (self.entries.items) |entry| {
        try cbor.writeValue(writer, .{
            entry.path,
            entry.begin_line,
            entry.begin_pos,
            entry.end_line,
            entry.end_pos,
            entry.lines,
            @intFromEnum(entry.severity),
            @intFromEnum(entry.pos_type),
        });
    }
}

pub fn restore_state(self: *Self, iter: *[]const u8) !void {
    self.reset();
    var view_pos: usize = 0;
    var selected: ?usize = null;
    if (!try cbor.matchValue(iter, cbor.extract(&view_pos)) or
        !try cbor.matchValue(iter, cbor.extract(&selected)))
        return error.InvalidFileListState;
    var count = try cbor.decodeArrayHeader(iter);
    while (count > 0) : (count -= 1) {
        var path: []const u8 = undefined;
        var begin_line: usize = undefined;
        var begin_pos: usize = undefined;
        var end_line: usize = undefined;
        var end_pos: usize = undefined;
        var lines: []const u8 = undefined;
        var severity: usize = undefined;
        var pos_type: usize = undefined;
        if (!try cbor.matchValue(iter, .{
            cbor.extract(&path),
            cbor.extract(&begin_line),
            cbor.extract(&begin_pos),
            cbor.extract(&end_line),
            cbor.extract(&end_pos),
            cbor.extract(&lines),
            cbor.extract(&severity),
            cbor.extract(&pos_type),
        })) {
            try cbor.skipValue(iter);
            continue;
        }
        try self.add(.{
            .path = path,
            .begin_line = begin_line,
            .begin_pos = begin_pos,
            .end_line = end_line,
            .end_pos = end_pos,
            .lines = lines,
            .severity = if (severity <= @intFromEnum(editor.Diagnostic.Severity.Hint))
                @enumFromInt(severity)
            else
                .Information,
            .pos_type = if (pos_type <= @intFromEnum(editor.PosType.byte))
                @enumFromInt(pos_type)
            else
                .byte,
        });
    }
    self.view_pos = view_pos;
    self.selected = if (selected) |s| (if (s < self.entries.items.len) s else null) else null;
    self.state = .done;
}

pub const Event = enum { none, rebuild, append_one };

pub const Manager = struct {
    allocator: std.mem.Allocator,
    lists: std.StringArrayHashMapUnmanaged(*Self) = .empty,
    active_: ?[]const u8 = null, // owned by list
    panel_open: bool = false,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.lists.values()) |fl| fl.deinit();
        self.lists.deinit(self.allocator);
    }

    pub fn get(self: *Manager, name: []const u8) ?*Self {
        return self.lists.get(name);
    }

    pub fn get_or_create(self: *Manager, name: []const u8) !*Self {
        if (self.lists.get(name)) |fl| return fl;
        const fl = try Self.init(self.allocator, name);
        errdefer fl.deinit();
        try self.lists.put(self.allocator, fl.name, fl);
        return fl;
    }

    pub fn active(self: *Manager) ?*Self {
        return if (self.active_) |a| self.lists.get(a) else null;
    }

    pub fn set_active(self: *Manager, name: []const u8) void {
        if (self.lists.get(name)) |fl| self.active_ = fl.name;
    }

    pub fn clear(self: *Manager, name: []const u8) void {
        if (self.lists.get(name)) |fl| fl.reset();
    }

    pub fn clear_all(self: *Manager) void {
        for (self.lists.values()) |fl| fl.reset();
    }

    pub fn reset(self: *Manager) void {
        for (self.lists.values()) |fl| fl.deinit();
        self.lists.clearRetainingCapacity();
        self.active_ = null;
        self.panel_open = false;
    }

    pub fn count(self: *Manager) usize {
        var n: usize = 0;
        for (self.lists.values()) |fl| if (!fl.is_empty()) {
            n += 1;
        };
        return n;
    }

    pub fn begin_ingest(self: *Manager, name: []const u8) !void {
        const fl = try self.get_or_create(name);
        fl.state = .idle;
    }

    pub fn add_item(self: *Manager, name: []const u8, entry: Entry, take_focus: bool) !Event {
        const fl = try self.get_or_create(name);
        const fresh = fl.state != .adding;
        if (fresh) {
            fl.reset();
            fl.state = .adding;
        }
        var event: Event = .none;
        if (take_focus) {
            const was_active = self.active() == fl;
            self.set_active(fl.name);
            event = if (fresh or !was_active) .rebuild else .append_one;
        }
        try fl.add(entry);
        return event;
    }

    pub fn end_ingest(self: *Manager, name: []const u8, clear_if_empty: bool) void {
        const fl = self.lists.get(name) orelse return;
        if (clear_if_empty and fl.state == .idle) fl.reset();
        fl.state = .done;
    }

    pub fn next(self: *Manager, from: ?*Self, dir: Direction) ?*Self {
        const values = self.lists.values();
        if (values.len == 0) return null;
        const start: usize = if (from) |f| (self.lists.getIndex(f.name) orelse 0) else 0;
        var i: usize = 0;
        while (i < values.len) : (i += 1) {
            const idx = switch (dir) {
                .forwards => (start + 1 + i) % values.len,
                .backwards => (start + values.len - 1 - i) % values.len,
            };
            const fl = values[idx];
            if (!fl.is_empty()) return fl;
        }
        return null;
    }

    pub fn write_state(self: *Manager, writer: *std.Io.Writer) !void {
        try cbor.writeArrayHeader(writer, 3);
        try cbor.writeValue(writer, self.active_);
        try cbor.writeValue(writer, self.panel_open);
        try cbor.writeArrayHeader(writer, self.count());
        for (self.lists.values()) |fl| {
            if (fl.is_empty()) continue;
            try fl.write_state(writer);
        }
    }

    pub fn restore_state(self: *Manager, iter: *[]const u8) !void {
        if (iter.len == 0) return; // session with no file-list section
        var active_: ?[]const u8 = null;
        var panel_open: bool = false;

        const header = try cbor.decodeArrayHeader(iter);
        if (header != 3) return error.InvalidFileListState;
        _ = try cbor.matchValue(iter, cbor.extract(&active_));
        _ = try cbor.matchValue(iter, cbor.extract(&panel_open));
        var count_ = try cbor.decodeArrayHeader(iter);
        while (count_ > 0) : (count_ -= 1) {
            const pair = try cbor.decodeArrayHeader(iter);
            if (pair < 4) return error.InvalidFileListState;
            var name: []const u8 = undefined;
            if (!try cbor.matchValue(iter, cbor.extract(&name))) {
                try cbor.skipValue(iter);
                continue;
            }
            const fl = try self.get_or_create(name);
            try fl.restore_state(iter);
        }
        self.panel_open = panel_open;
        if (active_) |a| self.set_active(a);
    }
};
