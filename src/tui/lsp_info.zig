allocator: std.mem.Allocator,
table: Table,

const Table = std.StringHashMapUnmanaged(Info);

pub const Info = struct {
    trigger_characters: std.ArrayList([]const u8) = .empty,
};

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{
        .allocator = allocator,
        .table = .empty,
    };
}

pub fn deinit(self: *@This()) void {
    var iter = self.table.iterator();
    while (iter.next()) |item| {
        for (item.value_ptr.trigger_characters.items) |char|
            self.allocator.free(char);
        item.value_ptr.trigger_characters.deinit(self.allocator);
        self.allocator.free(item.key_ptr.*);
    }
    self.table.deinit(self.allocator);
}

pub fn add_from_event(self: *@This(), cbor_buf: []const u8) error{ InvalidTriggersArray, OutOfMemory }!void {
    var iter = cbor_buf;
    var project: []const u8 = undefined;
    var lsp_arg0: []const u8 = undefined;
    var trigger_characters: []const u8 = undefined;
    if (!(cbor.matchValue(&iter, .{
        cbor.any,
        cbor.any,
        cbor.extract(&project),
        .{ cbor.extract(&lsp_arg0), cbor.more },
        cbor.extract_cbor(&trigger_characters),
    }) catch return)) return;
    try self.add(lsp_arg0, &trigger_characters);
}

fn add(self: *@This(), lsp_arg0: []const u8, iter: *[]const u8) error{ InvalidTriggersArray, OutOfMemory }!void {
    const key = try self.allocator.dupe(u8, lsp_arg0);
    errdefer self.allocator.free(key);

    const p = try self.table.getOrPut(self.allocator, key);
    const value = p.value_ptr;
    if (p.found_existing) {
        for (value.trigger_characters.items) |char|
            self.allocator.free(char);
        value.trigger_characters.clearRetainingCapacity();
    } else {
        value.* = .{};
    }

    var len = cbor.decodeArrayHeader(iter) catch return error.InvalidTriggersArray;
    while (len > 0) : (len -= 1) {
        var char: []const u8 = undefined;
        if (!(cbor.matchValue(iter, cbor.extract(&char)) catch return error.InvalidTriggersArray)) return error.InvalidTriggersArray;
        (try value.trigger_characters.addOne(self.allocator)).* = try self.allocator.dupe(u8, char);
    }
}

pub fn write_state(self: *@This(), writer: *std.Io.Writer) error{WriteFailed}!void {
    try cbor.writeArrayHeader(writer, self.table.count());
    var iter = self.table.iterator();
    while (iter.next()) |item| {
        try cbor.writeArrayHeader(writer, 2);
        try cbor.writeValue(writer, item.key_ptr.*);
        try cbor.writeArrayHeader(writer, item.value_ptr.trigger_characters.items.len);
        for (item.value_ptr.trigger_characters.items) |char| try cbor.writeValue(writer, char);
    }
}

pub fn extract_state(self: *@This(), iter: *[]const u8) error{ InvalidTriggersArray, OutOfMemory }!void {
    var lsp_arg0: []const u8 = undefined;
    var trigger_characters: []const u8 = undefined;
    var len = cbor.decodeArrayHeader(iter) catch return;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(iter, .{ cbor.extract(&lsp_arg0), cbor.extract_cbor(&trigger_characters) }) catch false) {
            try self.add(lsp_arg0, &trigger_characters);
        } else {
            cbor.skipValue(iter) catch return error.InvalidTriggersArray;
        }
    }
}

const std = @import("std");
const cbor = @import("cbor");
