//! OSC 7501 program status reports, spec revision 0.4 (2026-10-10)
//! https://www.superlogical.com/rex/docs/build/program-status

const std = @import("std");

pub const State = enum { idle, working, done, blocked, @"error", clear };
pub const Kind = enum { permission, question, auth };

pub const max_sequence = 4096;
pub const max_key = 16;
pub const max_msg = 2048;
pub const max_msg_encoded = 2732;
pub const max_title = 192;
pub const max_title_encoded = 256;
pub const max_app = 32;
pub const max_id = 128;
pub const max_segment = 32;
pub const max_depth = 8;
pub const max_records = 256;

pub const feature_reply = "\x1b]7501;?\x1b\\";

pub const Report = struct {
    state: State,
    kind: ?Kind = null,
    progress: ?u8 = null,
    app: []const u8 = "",
    id: []const u8 = "",
    title: []const u8 = "",
    msg: []const u8 = "",
};

pub const Event = union(enum) {
    report: Report,
    prompt,
    reset,
};

pub const DecodeBuffer = struct {
    title: [max_title]u8 = undefined,
    msg: [max_msg]u8 = undefined,
};

pub fn is_query(payload: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, payload, " \t"), "?");
}

pub fn parse(payload: []const u8, buf: *DecodeBuffer) ?Report {
    if (payload.len + "\x1b]7501;\x1b\\".len > max_sequence) return null;
    const Raw = struct { state: ?[]const u8 = null, kind: ?[]const u8 = null, progress: ?[]const u8 = null, app: ?[]const u8 = null, id: ?[]const u8 = null, title: ?[]const u8 = null, msg: ?[]const u8 = null };
    var raw: Raw = .{};
    var it = std.mem.splitScalar(u8, payload, ':');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eq], " \t");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (key.len > max_key) return null;
        if (key.len == 0 or !valid_key(key) or !valid_value(value)) continue;
        inline for (@typeInfo(Raw).@"struct".field_names) |name| {
            if (std.mem.eql(u8, key, name)) @field(raw, name) = value;
        }
    }

    const state = std.meta.stringToEnum(State, raw.state orelse return null) orelse return null;
    if (state == .clear) {
        const id = raw.id orelse "";
        if (raw.id != null and !valid_id(id)) return null;
        return .{ .state = .clear, .id = id };
    }
    var report: Report = .{ .state = state };
    if (state == .blocked) if (raw.kind) |v| {
        report.kind = std.meta.stringToEnum(Kind, v);
    };
    if (state == .working or state == .blocked) if (raw.progress) |v| {
        const progress = std.fmt.parseUnsigned(u8, v, 10) catch null;
        report.progress = if (progress) |p| if (p <= 100) p else null else null;
    };
    if (raw.app) |app| {
        if (app.len > max_app) return null;
        report.app = app;
    }
    if (raw.id) |id| {
        if (!valid_id(id)) return null;
        report.id = id;
    }
    if (raw.title) |title| report.title = decode_text(title, max_title_encoded, &buf.title) orelse return null;
    if (raw.msg) |msg| report.msg = decode_text(msg, max_msg_encoded, &buf.msg) orelse return null;
    return report;
}

pub fn from_osc_9_4(params: []const u8) ?Report {
    var it = std.mem.splitScalar(u8, params, ';');
    const state = std.fmt.parseUnsigned(u8, it.next() orelse return null, 10) catch return null;
    const progress: ?u8 = if (std.fmt.parseUnsigned(u8, it.next() orelse "", 10)) |p| @min(p, 100) else |_| null;
    return switch (state) {
        0 => .{ .state = .clear },
        1, 4 => .{ .state = .working, .progress = progress },
        2 => .{ .state = .@"error" },
        3 => .{ .state = .working },
        else => null,
    };
}

fn valid_key(key: []const u8) bool {
    for (key) |c| if (c < 'a' or c > 'z') return false;
    return true;
}

fn valid_value(value: []const u8) bool {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', ',', '+', '/', '=', '-' => {},
        else => return false,
    };
    return true;
}

fn valid_id(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id) return false;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, id, '/');
    while (it.next()) |segment| {
        depth += 1;
        if (depth > max_depth or segment.len == 0 or segment.len > max_segment) return false;
        for (segment) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '+', '-' => {},
            else => return false,
        };
    }
    return true;
}

fn decode_text(encoded: []const u8, max_encoded: usize, out: []u8) ?[]const u8 {
    if (encoded.len > max_encoded) return null;
    const unpadded = std.mem.trimEnd(u8, encoded, "=");
    if (encoded.len - unpadded.len > 2) return null;
    const decoder = std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(unpadded) catch return null;
    if (size > out.len) return null;
    decoder.decode(out[0..size], unpadded) catch return null;
    const text = out[0..size];
    var view = std.unicode.Utf8View.init(text) catch return null;
    var cps = view.iterator();
    while (cps.nextCodepoint()) |cp| switch (cp) {
        0x00...0x1f, 0x7f...0x9f => return null,
        else => {},
    };
    return text;
}

pub const Record = struct {
    id: []const u8,
    state: State,
    kind: ?Kind,
    progress: ?u8,
    app: []const u8,
    title: []const u8,
    msg: []const u8,
    updated: u64,

    fn deinit(self: Record, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.app);
        allocator.free(self.title);
        allocator.free(self.msg);
    }
};

pub const Change = union(enum) {
    set: *const Record,
    removed: []const u8,
};

pub const Records = struct {
    items: std.ArrayList(Record) = .empty,
    counter: u64 = 0,

    pub fn deinit(self: *Records, allocator: std.mem.Allocator) void {
        for (self.items.items) |r| r.deinit(allocator);
        self.items.deinit(allocator);
    }

    pub fn apply(self: *Records, allocator: std.mem.Allocator, event: Event, listener: anytype) error{OutOfMemory}!void {
        switch (event) {
            .report => |report| if (report.state == .clear)
                self.remove_matching(allocator, .{ .subtree = report.id }, listener)
            else
                try self.put(allocator, report, listener),
            .prompt => self.remove_matching(allocator, .transient, listener),
            .reset => self.remove_matching(allocator, .{ .subtree = "" }, listener),
        }
    }

    pub fn exited(self: *Records, allocator: std.mem.Allocator, listener: anytype) void {
        self.remove_matching(allocator, .transient, listener);
    }

    pub fn root(self: *const Records) ?*const Record {
        for (self.items.items) |*r| if (r.id.len == 0) return r;
        return null;
    }

    pub fn effective_app(self: *const Records, record: *const Record) []const u8 {
        if (record.app.len > 0) return record.app;
        var id = record.id;
        while (id.len > 0) {
            id = if (std.mem.lastIndexOfScalar(u8, id, '/')) |pos| id[0..pos] else "";
            if (self.find(id)) |r| if (r.app.len > 0) return r.app;
        }
        return "";
    }

    fn find(self: *const Records, id: []const u8) ?*const Record {
        for (self.items.items) |*r| if (std.mem.eql(u8, r.id, id)) return r;
        return null;
    }

    fn put(self: *Records, allocator: std.mem.Allocator, report: Report, listener: anytype) error{OutOfMemory}!void {
        self.counter += 1;
        var record: Record = .{
            .id = try allocator.dupe(u8, report.id),
            .state = report.state,
            .kind = report.kind,
            .progress = report.progress,
            .app = &.{},
            .title = &.{},
            .msg = &.{},
            .updated = self.counter,
        };
        errdefer record.deinit(allocator);
        record.app = try allocator.dupe(u8, report.app);
        record.title = try allocator.dupe(u8, report.title);
        record.msg = try allocator.dupe(u8, report.msg);

        const index = for (self.items.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, report.id)) break i;
        } else blk: {
            if (self.items.items.len >= max_records) {
                var oldest: usize = 0;
                for (self.items.items, 0..) |r, i| if (r.updated < self.items.items[oldest].updated) {
                    oldest = i;
                };
                self.remove_at(allocator, oldest, listener);
            }
            try self.items.append(allocator, record);
            break :blk self.items.items.len - 1;
        };
        if (self.items.items[index].updated != record.updated) {
            self.items.items[index].deinit(allocator);
            self.items.items[index] = record;
        }
        listener.changed(self, .{ .set = &self.items.items[index] });
    }

    const Match = union(enum) {
        transient,
        subtree: []const u8,
    };

    fn matches(record: *const Record, match: Match) bool {
        return switch (match) {
            .transient => switch (record.state) {
                .working, .blocked, .idle => true,
                else => false,
            },
            .subtree => |id| id.len == 0 or std.mem.eql(u8, record.id, id) or
                (std.mem.startsWith(u8, record.id, id) and record.id.len > id.len and record.id[id.len] == '/'),
        };
    }

    fn remove_matching(self: *Records, allocator: std.mem.Allocator, match: Match, listener: anytype) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (matches(&self.items.items[i], match)) self.remove_at(allocator, i, listener) else i += 1;
        }
    }

    fn remove_at(self: *Records, allocator: std.mem.Allocator, index: usize, listener: anytype) void {
        const record = self.items.orderedRemove(index);
        defer record.deinit(allocator);
        listener.changed(self, .{ .removed = record.id });
    }
};

pub const no_listener = struct {
    pub fn changed(_: @This(), _: *const Records, _: Change) void {}
}{};

const testing = std.testing;

fn rep(comptime c: u8, comptime n: usize) *const [n]u8 {
    const result: [n]u8 = @splat(c);
    return &result;
}

fn with_b64(out: []u8, prefix: []const u8, text: []const u8) []const u8 {
    @memcpy(out[0..prefix.len], prefix);
    const encoded = std.base64.standard.Encoder.encode(out[prefix.len..], text);
    return out[0 .. prefix.len + encoded.len];
}
