/// This file *MUST* be kept in sync with tree-sitter/lib/src/query.c
/// It exactly represents the C structures in memory and must produce
/// the exact same results as the C tree-sitter library version used.
///
/// Yes,... it is not a public API! Here be dragons!
///
const std = @import("std");
const cbor = @import("cbor");
const build_options = @import("build_options");
const treez = if (build_options.use_tree_sitter) @import("treez") else @import("treez_dummy.zig");

pub const Slice = extern struct {
    offset: u32,
    length: u32,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extract(&self.offset),
            cbor.extract(&self.length),
        });
    }
};

pub fn Array(T: type) type {
    return extern struct {
        contents: ?*T,
        size: u32,
        capacity: u32,

        pub fn cborEncode(self: *const @This(), writer: anytype) !void {
            if (self.contents) |contents| {
                const arr: []T = @as([*]T, @ptrCast(contents))[0..self.size];
                try cbor.writeValue(writer, arr);
                return;
            }
            try cbor.writeValue(writer, null);
        }

        pub fn cborExtract(self: *@This(), iter: *[]const u8, allocator: std.mem.Allocator) cbor.Error!bool {
            var iter_ = iter.*;
            if (cbor.matchValue(&iter_, cbor.null_) catch false) {
                iter.* = iter_;
                self.contents = null;
                self.size = 0;
                self.capacity = 0;
                return true;
            }

            if (T == u8) {
                var arr: []const u8 = undefined;
                if (try cbor.matchValue(iter, cbor.extract(&arr))) {
                    self.contents = @constCast(@ptrCast(arr.ptr));
                    self.size = @intCast(arr.len);
                    self.capacity = @intCast(arr.len);
                    return true;
                }
                return false;
            }

            var i: usize = 0;
            var n = try cbor.decodeArrayHeader(iter);
            var arr: []T = try allocator.alloc(T, n);
            while (n > 0) : (n -= 1) {
                if (comptime cbor.isExtractableAlloc(T)) {
                    if (!(cbor.matchValue(iter, cbor.extractAlloc(&arr[i], allocator)) catch return false))
                        return false;
                } else {
                    if (!(cbor.matchValue(iter, cbor.extract(&arr[i])) catch return false))
                        return false;
                }
                i += 1;
            }
            self.contents = @constCast(@ptrCast(arr.ptr));
            self.size = @intCast(arr.len);
            self.capacity = @intCast(arr.len);
            return true;
        }
    };
}

pub const SymbolTable = extern struct {
    characters: Array(u8),
    slices: Array(Slice),

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8, allocator: std.mem.Allocator) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extractAlloc(&self.characters, allocator),
            cbor.extractAlloc(&self.slices, allocator),
        });
    }
};
pub const CaptureQuantifiers = Array(u8);
pub const PatternEntry = extern struct {
    step_index: u16,
    pattern_index: u16,
    is_rooted: bool,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extract(&self.step_index),
            cbor.extract(&self.pattern_index),
            cbor.extract(&self.is_rooted),
        });
    }
};
pub const QueryPattern = extern struct {
    steps: Slice,
    predicate_steps: Slice,
    start_byte: u32,
    end_byte: u32,
    is_non_local: bool,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8, allocator: std.mem.Allocator) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extractAlloc(&self.steps, allocator),
            cbor.extractAlloc(&self.predicate_steps, allocator),
            cbor.extract(&self.start_byte),
            cbor.extract(&self.end_byte),
            cbor.extract(&self.is_non_local),
        });
    }
};
pub const StepOffset = extern struct {
    byte_offset: u32,
    step_index: u16,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extract(&self.byte_offset),
            cbor.extract(&self.step_index),
        });
    }
};

pub const MAX_STEP_CAPTURE_COUNT = 3;

pub const TSSymbol = u16;
pub const TSFieldId = u16;

pub const QueryStep = extern struct {
    symbol: TSSymbol,
    supertype_symbol: TSSymbol,
    field: TSFieldId,
    capture_ids: [MAX_STEP_CAPTURE_COUNT]u16,
    depth: u16,
    alternative_index: u16,
    negated_field_list_id: u16,
    // is_named: u1,
    // is_immediate: u1,
    // is_last_child: u1,
    // is_pass_through: u1,
    // is_dead_end: u1,
    // alternative_is_immediate: u1,
    // contains_captures: u1,
    // root_pattern_guaranteed: u1,
    flags8: u8,
    // parent_pattern_guaranteed: u1,
    flags16: u8,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extract(&self.symbol),
            cbor.extract(&self.supertype_symbol),
            cbor.extract(&self.field),
            cbor.extract(&self.capture_ids),
            cbor.extract(&self.depth),
            cbor.extract(&self.alternative_index),
            cbor.extract(&self.negated_field_list_id),
            cbor.extract(&self.flags8),
            cbor.extract(&self.flags16),
        });
    }
};

pub const PredicateStep = extern struct {
    pub const Type = enum(c_uint) {
        done,
        capture,
        string,
    };

    type: Type,
    value_id: u32,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extract(&self.type),
            cbor.extract(&self.value_id),
        });
    }
};

pub const TSQuery = extern struct {
    captures: SymbolTable,
    predicate_values: SymbolTable,
    capture_quantifiers: Array(CaptureQuantifiers),
    steps: Array(QueryStep),
    pattern_map: Array(PatternEntry),
    predicate_steps: Array(PredicateStep),
    patterns: Array(QueryPattern),
    step_offsets: Array(StepOffset),
    negated_fields: Array(TSFieldId),
    string_buffer: Array(u8),
    repeat_symbols_with_rootless_patterns: Array(TSSymbol),
    language: usize,
    // language: ?*const treez.Language,
    wildcard_root_pattern_count: u16,

    pub fn cborEncode(self: *const @This(), writer: anytype) !void {
        return cbor.writeArray(writer, self.*);
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8, allocator: std.mem.Allocator) cbor.Error!bool {
        const result = cbor.matchValue(iter, .{
            cbor.extractAlloc(&self.captures, allocator),
            cbor.extractAlloc(&self.predicate_values, allocator),
            cbor.extractAlloc(&self.capture_quantifiers, allocator),
            cbor.extractAlloc(&self.steps, allocator),
            cbor.extractAlloc(&self.pattern_map, allocator),
            cbor.extractAlloc(&self.predicate_steps, allocator),
            cbor.extractAlloc(&self.patterns, allocator),
            cbor.extractAlloc(&self.step_offsets, allocator),
            cbor.extractAlloc(&self.negated_fields, allocator),
            cbor.extractAlloc(&self.string_buffer, allocator),
            cbor.extractAlloc(&self.repeat_symbols_with_rootless_patterns, allocator),
            cbor.extract(&self.language),
            cbor.extract(&self.wildcard_root_pattern_count),
        });
        self.language = 0;
        return result;
    }
};

pub const SerializeError = error{OutOfMemory};

pub fn toCbor(query: *TSQuery, allocator: std.mem.Allocator) SerializeError![]const u8 {
    var cb: std.ArrayListUnmanaged(u8) = .empty;
    defer cb.deinit(allocator);
    try cbor.writeValue(cb.writer(allocator), query.*);
    return cb.toOwnedSlice(allocator);
}

pub const DeserializeError = error{
    OutOfMemory,
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    InvalidFloatType,
    InvalidArrayType,
    InvalidPIntType,
    JsonIncompatibleType,
    InvalidQueryCbor,
    NotAnObject,
    BadArrayAllocExtract,
};

pub fn fromCbor(cb: []const u8, allocator: std.mem.Allocator) DeserializeError!struct { *TSQuery, *std.heap.ArenaAllocator } {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const query = try arena.allocator().create(TSQuery);
    query.* = undefined;
    var iter: []const u8 = cb;
    if (!try cbor.matchValue(&iter, cbor.extractAlloc(query, arena.allocator())))
        return error.InvalidQueryCbor;
    return .{ query, arena };
}
