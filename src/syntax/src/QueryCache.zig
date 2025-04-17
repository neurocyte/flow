const std = @import("std");
const build_options = @import("build_options");

const treez = if (build_options.use_tree_sitter)
    @import("treez")
else
    @import("treez_dummy.zig");

const Self = @This();

pub const tss = @import("ts_serializer.zig");
pub const FileType = @import("file_type.zig");
const Query = treez.Query;

allocator: std.mem.Allocator,
mutex: ?std.Thread.Mutex,
highlights: std.StringHashMapUnmanaged(*CacheEntry) = .{},
injections: std.StringHashMapUnmanaged(*CacheEntry) = .{},
ref_count: usize = 1,

const CacheEntry = struct {
    mutex: ?std.Thread.Mutex,
    query: ?*Query,
    query_arena: ?*std.heap.ArenaAllocator,
    query_type: QueryType,
    file_type: *const FileType,

    fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.query_arena) |a| {
            a.deinit();
            allocator.destroy(a);
        } else if (self.query) |q|
            q.destroy();
        self.query_arena = null;
        self.query = null;
    }
};

pub const QueryType = enum {
    highlights,
    injections,
};

const QueryParseError = error{
    InvalidSyntax,
    InvalidNodeType,
    InvalidField,
    InvalidCapture,
    InvalidStructure,
    InvalidLanguage,
};

const CacheError = error{
    NotFound,
    OutOfMemory,
};

pub const Error = CacheError || QueryParseError || QuerySerializeError;

pub fn create(allocator: std.mem.Allocator, opts: struct { lock: bool = false }) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .mutex = if (opts.lock) .{} else null,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.release_ref_unlocked_and_maybe_destroy();
}

fn add_ref_locked(self: *Self) void {
    std.debug.assert(self.ref_count > 0);
    self.ref_count += 1;
}

fn release_ref_unlocked_and_maybe_destroy(self: *Self) void {
    {
        if (self.mutex) |*mtx| mtx.lock();
        defer if (self.mutex) |*mtx| mtx.unlock();
        self.ref_count -= 1;
        if (self.ref_count > 0) return;
    }

    var iter_highlights = self.highlights.iterator();
    while (iter_highlights.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.destroy(self.allocator);
        self.allocator.destroy(p.value_ptr.*);
    }
    var iter_injections = self.injections.iterator();
    while (iter_injections.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.destroy(self.allocator);
        self.allocator.destroy(p.value_ptr.*);
    }
    self.highlights.deinit(self.allocator);
    self.injections.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn get_cache_entry(self: *Self, file_type: *const FileType, comptime query_type: QueryType) CacheError!*CacheEntry {
    if (self.mutex) |*mtx| mtx.lock();
    defer if (self.mutex) |*mtx| mtx.unlock();

    const hash = switch (query_type) {
        .highlights => &self.highlights,
        .injections => &self.injections,
    };

    return if (hash.get(file_type.name)) |entry| entry else blk: {
        const entry_ = try hash.getOrPut(self.allocator, try self.allocator.dupe(u8, file_type.name));

        const q = try self.allocator.create(CacheEntry);
        q.* = .{
            .query = null,
            .query_arena = null,
            .mutex = if (self.mutex) |_| .{} else null,
            .file_type = file_type,
            .query_type = query_type,
        };
        entry_.value_ptr.* = q;

        break :blk q;
    };
}

fn get_cached_query(self: *Self, entry: *CacheEntry) Error!?*Query {
    if (entry.mutex) |*mtx| mtx.lock();
    defer if (entry.mutex) |*mtx| mtx.unlock();

    return if (entry.query) |query| query else blk: {
        const lang = entry.file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {s}", .{entry.file_type.name});
        const queries = FileType.queries.get(entry.file_type.name) orelse return null;
        const query_bin = switch (entry.query_type) {
            .highlights => queries.highlights_bin,
            .injections => queries.injections_bin orelse return null,
        };
        const query, const arena = try deserialize_query(query_bin, lang, self.allocator);
        entry.query = query;
        entry.query_arena = arena;
        break :blk entry.query.?;
    };
}

fn pre_load_internal(self: *Self, file_type: *const FileType, comptime query_type: QueryType) Error!void {
    _ = try self.get_cached_query(try self.get_cache_entry(file_type, query_type));
}

pub fn pre_load(self: *Self, lang_name: []const u8) Error!void {
    const file_type = FileType.get_by_name(lang_name) orelse return;
    _ = try self.pre_load_internal(file_type, .highlights);
    _ = try self.pre_load_internal(file_type, .injections);
}

fn ReturnType(comptime query_type: QueryType) type {
    return switch (query_type) {
        .highlights => *Query,
        .injections => ?*Query,
    };
}

pub fn get(self: *Self, file_type: *const FileType, comptime query_type: QueryType) Error!ReturnType(query_type) {
    const query = try self.get_cached_query(try self.get_cache_entry(file_type, query_type));
    self.add_ref_locked();
    return switch (@typeInfo(ReturnType(query_type))) {
        .optional => |_| query,
        else => query.?,
    };
}

pub fn release(self: *Self, query: *Query, comptime query_type: QueryType) void {
    _ = query;
    _ = query_type;
    self.release_ref_unlocked_and_maybe_destroy();
}

pub const QuerySerializeError = (tss.SerializeError || tss.DeserializeError);

fn deserialize_query(query_bin: []const u8, language: ?*const treez.Language, allocator: std.mem.Allocator) QuerySerializeError!struct { *Query, *std.heap.ArenaAllocator } {
    var ts_query_out, const arena = try tss.fromCbor(query_bin, allocator);
    ts_query_out.language = @intFromPtr(language);

    const query_out: *Query = @alignCast(@ptrCast(ts_query_out));
    return .{ query_out, arena };
}
