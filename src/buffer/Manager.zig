const std = @import("std");
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

pub fn open_scratch(self: *Self, file_path: []const u8, content: []const u8) Buffer.LoadFromStringError!*Buffer {
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
    return buffer;
}

pub fn get_buffer_for_file(self: *Self, file_path: []const u8) ?*Buffer {
    return self.buffers.get(file_path);
}

pub fn delete_buffer(self: *Self, file_path: []const u8) bool {
    const buffer = self.buffers.get(file_path) orelse return false;
    buffer.deinit();
    return self.buffers.remove(file_path);
}

pub fn retire(_: *Self, _: *Buffer) void {}

pub fn list_most_recently_used(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}![]*Buffer {
    const result = try self.list_unordered(allocator);

    std.mem.sort(*Buffer, result, {}, struct {
        fn less_fn(_: void, lhs: *Buffer, rhs: *Buffer) bool {
            return lhs.utime > rhs.utime;
        }
    }.less_fn);

    return result;
}

pub fn list_unordered(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}![]*Buffer {
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

pub fn is_buffer_dirty(self: *const Self, file_path: []const u8) bool {
    return if (self.buffers.get(file_path)) |buffer| buffer.is_dirty() else false;
}

pub fn save_all(self: *const Self) Buffer.StoreToFileError!void {
    var i = self.buffers.iterator();
    while (i.next()) |kv| {
        const buffer = kv.value_ptr.*;
        try buffer.store_to_file_and_clean(buffer.file_path);
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
