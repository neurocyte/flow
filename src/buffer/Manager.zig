const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const Buffer = @import("Buffer.zig");

const Self = @This();

allocator: std.mem.Allocator,
buffers: std.StringHashMapUnmanaged(*Buffer),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .buffers = .{},
    };
}

pub fn deinit(self: *Self) void {
    var i = self.buffers.iterator();
    while (i.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.deinit();
    }
    self.buffers.deinit(self.allocator);
}

pub fn open_file(self: *Self, file_path: []const u8) Buffer.LoadFromFileError!*Buffer {
    const buffer = if (self.buffers.get(file_path)) |buffer| buffer else blk: {
        var buffer = try Buffer.create(self.allocator);
        errdefer buffer.deinit();
        try buffer.load_from_file_and_update(file_path);
        try self.buffers.put(self.allocator, try self.allocator.dupe(u8, file_path), buffer);
        break :blk buffer;
    };
    buffer.update_last_used_time();
    buffer.hidden = false;
    return buffer;
}

pub fn open_scratch(self: *Self, file_path: []const u8, content: []const u8) Buffer.LoadError!*Buffer {
    const buffer = if (self.buffers.get(file_path)) |buffer| buffer else blk: {
        var buffer = try Buffer.create(self.allocator);
        errdefer buffer.deinit();
        try buffer.load_from_string_and_update(file_path, content);
        buffer.file_exists = true;
        try self.buffers.put(self.allocator, try self.allocator.dupe(u8, file_path), buffer);
        break :blk buffer;
    };
    buffer.update_last_used_time();
    buffer.hidden = false;
    buffer.ephemeral = true;
    return buffer;
}

pub fn write_state(self: *const Self, writer: *std.Io.Writer) error{ Stop, OutOfMemory, WriteFailed }!void {
    const buffers = self.list_unordered(self.allocator) catch return;
    defer self.allocator.free(buffers);
    try cbor.writeArrayHeader(writer, buffers.len);
    for (buffers) |buffer| {
        tp.trace(tp.channel.debug, .{ @typeName(Self), "write_state", buffer.get_file_path(), buffer.file_type_name });
        buffer.write_state(writer) catch |e| {
            tp.trace(tp.channel.debug, .{ @typeName(Self), "write_state", "failed", e });
            return;
        };
    }
}

pub fn extract_state(self: *Self, iter: *[]const u8) !void {
    var len = try cbor.decodeArrayHeader(iter);
    tp.trace(tp.channel.debug, .{ @typeName(Self), "extract_state", len });
    while (len > 0) : (len -= 1) {
        var buffer = try Buffer.create(self.allocator);
        errdefer |e| {
            tp.trace(tp.channel.debug, .{ "buffer", "extract", "failed", buffer.get_file_path(), e });
            buffer.deinit();
        }
        try buffer.extract_state(iter);
        try self.buffers.put(self.allocator, try self.allocator.dupe(u8, buffer.get_file_path()), buffer);
        tp.trace(tp.channel.debug, .{ "buffer", "extract", buffer.get_file_path(), buffer.file_type_name });
    }
}

pub fn get_buffer_for_file(self: *const Self, file_path: []const u8) ?*Buffer {
    return self.buffers.get(file_path);
}

pub fn delete_buffer(self: *Self, file_path: []const u8) bool {
    const buffer = self.buffers.get(file_path) orelse return false;
    const did_remove = self.buffers.remove(file_path);
    buffer.deinit();
    return did_remove;
}

pub fn retire(_: *Self, buffer: *Buffer, meta: ?[]const u8) void {
    if (meta) |buf| buffer.set_meta(buf) catch {};
    tp.trace(tp.channel.debug, .{ "buffer", "retire", buffer.get_file_path(), "hidden", buffer.hidden, "ephemeral", buffer.ephemeral });
    if (meta) |buf| tp.trace(tp.channel.debug, tp.message{ .buf = buf });
}

pub fn close_buffer(self: *Self, buffer: *Buffer) void {
    buffer.hidden = true;
    tp.trace(tp.channel.debug, .{ "buffer", "close", buffer.get_file_path(), "hidden", buffer.hidden, "ephemeral", buffer.ephemeral });
    if (buffer.is_ephemeral()) {
        _ = self.buffers.remove(buffer.get_file_path());
        buffer.deinit();
    }
}

pub fn list_most_recently_used(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}![]*Buffer {
    const result = try self.list_unordered(allocator);

    std.mem.sort(*Buffer, result, {}, struct {
        fn less_fn(_: void, lhs: *Buffer, rhs: *Buffer) bool {
            return lhs.utime > rhs.utime;
        }
    }.less_fn);

    return result;
}

pub fn list_unordered(self: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}![]*Buffer {
    var buffers = try std.ArrayListUnmanaged(*Buffer).initCapacity(allocator, self.buffers.size);
    var i = self.buffers.iterator();
    while (i.next()) |kv|
        (try buffers.addOne(allocator)).* = kv.value_ptr.*;
    return buffers.toOwnedSlice(allocator);
}

pub fn is_dirty(self: *const Self) bool {
    var i = self.buffers.iterator();
    while (i.next()) |kv|
        if (kv.value_ptr.*.is_dirty())
            return true;
    return false;
}

pub fn number_of_dirties(self: *const Self) usize {
    var dirties: usize = 0;
    var i = self.buffers.iterator();

    while (i.next()) |p| {
        const buffer = p.value_ptr.*;
        if (!buffer.is_ephemeral() and buffer.is_dirty()) {
            dirties += 1;
        }
    }
    return dirties;
}

pub fn is_buffer_dirty(self: *const Self, file_path: []const u8) bool {
    return if (self.buffers.get(file_path)) |buffer| buffer.is_dirty() else false;
}

pub fn save_all(self: *const Self) Buffer.StoreToFileError!void {
    var i = self.buffers.iterator();
    while (i.next()) |kv| {
        const buffer = kv.value_ptr.*;
        if (buffer.is_ephemeral())
            buffer.mark_clean()
        else
            try buffer.store_to_file_and_clean(buffer.get_file_path());
    }
}

pub fn reload_all(self: *const Self) Buffer.LoadFromFileError!void {
    var i = self.buffers.iterator();
    while (i.next()) |kv| {
        const buffer = kv.value_ptr.*;
        if (buffer.is_ephemeral())
            buffer.mark_clean()
        else
            try buffer.refresh_from_file();
    }
}

pub fn delete_all(self: *Self) void {
    var i = self.buffers.iterator();
    while (i.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.deinit();
    }
    self.buffers.clearRetainingCapacity();
}

pub fn delete_others(self: *Self, protected: *Buffer) void {
    var i = self.buffers.iterator();
    while (i.next()) |p| {
        const buffer = p.value_ptr.*;
        if (buffer != protected) {
            buffer.reset_to_last_saved();
            self.close_buffer(buffer);
        }
    }
}

pub fn close_others(self: *Self, protected: *Buffer) usize {
    var remaining: usize = 0;
    var i = self.buffers.iterator();
    while (i.next()) |p| {
        const buffer = p.value_ptr.*;
        if (buffer != protected) {
            if (buffer.is_ephemeral() or !buffer.is_dirty()) {
                _ = self.buffers.remove(buffer.get_file_path());
                buffer.deinit();
            } else remaining += 1;
        }
    }
    return remaining;
}

pub fn buffer_from_ref(self: *Self, buffer_ref: usize) ?*Buffer {
    var i = self.buffers.iterator();
    while (i.next()) |p|
        if (@intFromPtr(p.value_ptr.*) == buffer_ref)
            return p.value_ptr.*;
    tp.trace(tp.channel.debug, .{ "buffer_from_ref", "failed", buffer_ref });
    return null;
}

pub fn buffer_to_ref(_: *Self, buffer: *Buffer) usize {
    return @intFromPtr(buffer);
}
