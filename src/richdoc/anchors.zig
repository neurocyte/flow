const std = @import("std");
const SDoc = @import("SDoc.zig");

const Allocator = std.mem.Allocator;

pub fn heading_row(allocator: Allocator, sdoc: SDoc, anchor: []const u8) error{ OutOfMemory, InvalidSDoc }!?usize {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var finder: Finder = .{ .arena = arena.allocator(), .anchor = anchor };
    return finder.element(try SDoc.Element.root(sdoc));
}

const Finder = struct {
    arena: Allocator,
    anchor: []const u8,
    seen: std.StringHashMapUnmanaged(usize) = .empty,

    fn element(self: *Finder, elem: SDoc.Element) error{ OutOfMemory, InvalidSDoc }!?usize {
        if (is_heading(elem.tag)) {
            var text: std.Io.Writer.Allocating = .init(self.arena);
            try plain_text(&text.writer, elem);
            const base = try slug(self.arena, text.written());
            const n = self.seen.get(base) orelse 0;
            try self.seen.put(self.arena, base, n + 1);
            const name = if (n == 0) base else try std.fmt.allocPrint(self.arena, "{s}-{d}", .{ base, n });
            return if (std.mem.eql(u8, name, self.anchor)) elem.src_row() else null;
        }
        var iter = elem.iterate();
        while (try iter.next()) |child| switch (child) {
            .element => |e| if (try self.element(e)) |row| return row,
            .text => {},
        };
        return null;
    }
};

fn is_heading(tag: []const u8) bool {
    return tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6';
}

fn plain_text(writer: *std.Io.Writer, elem: SDoc.Element) error{ OutOfMemory, InvalidSDoc }!void {
    var iter = elem.iterate();
    while (try iter.next()) |child| switch (child) {
        .text => |t| writer.writeAll(t) catch return error.OutOfMemory,
        .element => |e| try plain_text(writer, e),
    };
}

pub fn slug(allocator: Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, text, " \t")) |c| {
        if (c == ' ') {
            try out.append(allocator, '-');
        } else if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80) {
            try out.append(allocator, std.ascii.toLower(c));
        }
    }
    return out.toOwnedSlice(allocator);
}
