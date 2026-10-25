//! a structured document
//!
//! An element is `[tag, attrs, child...]`. `tag` is an HTML element name.
//! `attrs` is a map that always holds `sloc` (`[start_byte, end_byte]` in
//! the source) and a child is a text string or an element.

const std = @import("std");
const cbor = @import("cbor");

const Allocator = std.mem.Allocator;

/// `["body", attrs, child...]`
raw: cbor.Raw = .empty,

const SDoc = @This();

pub const Value = union(enum) {
    uint: u64,
    boolean: bool,
    string: []const u8,
};

pub const Attr = struct {
    name: []const u8,
    value: Value,
};

pub const Child = union(enum) {
    text: std.ArrayList(u8),
    elem: *ElementBuilder,
};

/// an element under construction
pub const ElementBuilder = struct {
    tag: []const u8,
    sloc: [2]usize,
    attrs: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(Child) = .empty,

    pub fn create(arena: Allocator, tag: []const u8, start: usize, end: usize) error{OutOfMemory}!*@This() {
        const self = try arena.create(@This());
        self.* = .{ .tag = tag, .sloc = .{ start, end } };
        return self;
    }

    pub fn add_elem(self: *@This(), arena: Allocator, tag: []const u8, start: usize, end: usize) error{OutOfMemory}!*@This() {
        const elem = try create(arena, tag, start, end);
        try self.children.append(arena, .{ .elem = elem });
        return elem;
    }

    pub fn add_text(self: *@This(), arena: Allocator, text: []const u8) error{OutOfMemory}!void {
        if (text.len == 0) return;
        if (self.children.items.len > 0) switch (self.children.items[self.children.items.len - 1]) {
            .text => |*t| return t.appendSlice(arena, text),
            .elem => {},
        };
        var t: std.ArrayList(u8) = .empty;
        try t.appendSlice(arena, text);
        try self.children.append(arena, .{ .text = t });
    }

    pub fn set(self: *@This(), arena: Allocator, name: []const u8, value: Value) error{OutOfMemory}!void {
        try self.attrs.append(arena, .{ .name = name, .value = value });
    }

    pub fn is(self: *const @This(), tag: []const u8) bool {
        return std.mem.eql(u8, self.tag, tag);
    }

    /// encode the tree under this element, clamping `sloc` to `limit`
    pub fn encode(self: *const @This(), allocator: Allocator, limit: usize) error{OutOfMemory}!SDoc {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        self.write(&out.writer, limit) catch return error.OutOfMemory;
        return .{ .raw = .{ .bytes = out.toOwnedSlice() catch return error.OutOfMemory } };
    }

    pub fn write(self: *const @This(), writer: *std.Io.Writer, limit: usize) std.Io.Writer.Error!void {
        try cbor.writeArrayHeader(writer, 2 + self.children.items.len);
        try cbor.writeValue(writer, self.tag);
        try cbor.writeMapHeader(writer, 1 + self.attrs.items.len);
        try cbor.writeValue(writer, "sloc");
        try cbor.writeValue(writer, [2]usize{ @min(self.sloc[0], limit), @min(self.sloc[1], limit) });
        for (self.attrs.items) |attr| {
            try cbor.writeValue(writer, attr.name);
            switch (attr.value) {
                inline else => |v| try cbor.writeValue(writer, v),
            }
        }
        for (self.children.items) |child| switch (child) {
            .text => |t| try cbor.writeValue(writer, t.items),
            .elem => |e| try e.write(writer, limit),
        };
    }
};

// reader

pub const Element = struct {
    tag: []const u8,
    attrs: cbor.Raw,
    children: cbor.Raw,
    child_count: usize,

    pub fn iterate(self: @This()) Iterator {
        return .{ .iter = self.children.bytes, .remaining = self.child_count };
    }

    pub fn attr(self: @This(), name: []const u8) ?cbor.Raw {
        var iter = self.attrs.bytes;
        var len = cbor.decodeMapHeader(&iter) catch return null;
        while (len > 0) : (len -= 1) {
            var key: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &key) catch return null)) return null;
            var value: cbor.Raw = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract(&value)) catch return null)) return null;
            if (std.mem.eql(u8, key, name)) return value;
        }
        return null;
    }

    pub fn attr_string(self: @This(), name: []const u8) ?[]const u8 {
        var iter = (self.attr(name) orelse return null).bytes;
        var value: []const u8 = undefined;
        return if (cbor.matchString(&iter, &value) catch false) value else null;
    }

    pub fn attr_uint(self: @This(), name: []const u8) ?u64 {
        var iter = (self.attr(name) orelse return null).bytes;
        var value: u64 = undefined;
        return if (cbor.matchInt(u64, &iter, &value) catch false) value else null;
    }

    pub fn attr_bool(self: @This(), name: []const u8) ?bool {
        var iter = (self.attr(name) orelse return null).bytes;
        var value: bool = undefined;
        return if (cbor.matchBool(&iter, &value) catch false) value else null;
    }

    pub fn sloc(self: @This()) ?[2]usize {
        var iter = (self.attr("sloc") orelse return null).bytes;
        var start: usize = 0;
        var end: usize = 0;
        return if (cbor.matchValue(&iter, .{ cbor.extract(&start), cbor.extract(&end) }) catch false) .{ start, end } else null;
    }

    pub fn is(self: @This(), tag: []const u8) bool {
        return std.mem.eql(u8, self.tag, tag);
    }

    pub fn read(iter: *[]const u8) error{InvalidSDoc}!Element {
        const len = cbor.decodeArrayHeader(iter) catch return error.InvalidSDoc;
        if (len < 2) return error.InvalidSDoc;
        var tag: []const u8 = undefined;
        if (!(cbor.matchString(iter, &tag) catch return error.InvalidSDoc)) return error.InvalidSDoc;
        var attrs: cbor.Raw = undefined;
        if (!(cbor.matchValue(iter, cbor.extract(&attrs)) catch return error.InvalidSDoc)) return error.InvalidSDoc;
        const start = iter.*;
        for (0..len - 2) |_| cbor.skipValue(iter) catch return error.InvalidSDoc;
        return .{ .tag = tag, .attrs = attrs, .children = .{ .bytes = start[0 .. start.len - iter.len] }, .child_count = len - 2 };
    }

    pub fn root(doc: SDoc) error{InvalidSDoc}!Element {
        var iter = doc.raw.bytes;
        return read(&iter);
    }
};

pub const Content = union(enum) {
    text: []const u8,
    element: Element,

    pub fn read(iter: *[]const u8) error{InvalidSDoc}!Content {
        if (iter.len == 0) return error.InvalidSDoc;
        if (iter.*[0] >> 5 == 3) {
            var s: []const u8 = undefined;
            if (!(cbor.matchString(iter, &s) catch return error.InvalidSDoc)) return error.InvalidSDoc;
            return .{ .text = s };
        }
        return .{ .element = try Element.read(iter) };
    }
};

pub const Iterator = struct {
    iter: []const u8,
    remaining: usize,

    pub fn next(self: *@This()) error{InvalidSDoc}!?Content {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try Content.read(&self.iter);
    }
};
