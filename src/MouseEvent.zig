const std = @import("std");
const vaxis = @import("vaxis");
const cbor = @import("cbor");
const Writer = std.Io.Writer;

pub const Type = enum {
    press,
    release,
    motion,
    drag,

    pub fn to_vaxis(self: @This()) vaxis.Mouse.Type {
        return @bitCast(self);
    }
    pub fn from_vaxis(mods: vaxis.Mouse.Type) Button {
        return @bitCast(mods);
    }
};

pub const Button = enum(u8) {
    left,
    middle,
    right,
    none,
    wheel_up = 64,
    wheel_down = 65,
    wheel_right = 66,
    wheel_left = 67,
    button_8 = 128,
    button_9 = 129,
    button_10 = 130,
    button_11 = 131,
    _,

    pub fn to_vaxis(self: @This()) vaxis.Mouse.Button {
        return @bitCast(self);
    }
    pub fn from_vaxis(mods: vaxis.Mouse.Button) Button {
        return @bitCast(mods);
    }
};

pub const Modifiers = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
        try cbor.writeValue(writer, @as(u3, @bitCast(self)));
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        var value: u3 = 0;
        if (try cbor.matchValue(iter, cbor.extract(&value))) {
            self.* = @bitCast(value);
            return true;
        }
        return false;
    }

    pub fn to_vaxis(self: @This()) vaxis.Mouse.Modifiers {
        return @bitCast(self);
    }
    pub fn from_vaxis(mods: vaxis.Mouse.Modifiers) Modifiers {
        return @bitCast(mods);
    }
};

pub const Event = struct {
    Type,
    Button,
    Coord,
    Modifiers,
};

pub const Coord = struct {
    x: i32,
    y: i32,

    pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
        try cbor.writeValue(writer, .{ self.x, self.y });
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{ cbor.extract(&self.x), cbor.extract(&self.y) });
    }

    pub fn to_cell(self: @This(), geom: Geometry) Cell {
        const cw: i32 = @max(1, geom.cell_width);
        const ch: i32 = @max(1, geom.cell_height);
        const dx = self.x - geom.origin_x;
        const dy = self.y - geom.origin_y;
        return .{
            .col = @divFloor(dx, cw),
            .row = @divFloor(dy, ch),
            .xoffset = @intCast(@mod(dx, cw)),
            .yoffset = @intCast(@mod(dy, ch)),
        };
    }

    /// Like `to_cell`, but rounds horizontally to the nearest cell boundary
    /// Used for beam cursor placement
    pub fn to_cell_nearest_x(self: @This(), geom: Geometry) Cell {
        var cell = self.to_cell(geom);
        const cw: i32 = @max(1, geom.cell_width);
        if (cell.xoffset > @as(u16, @intCast(@divTrunc(cw, 2)))) {
            cell.col += 1;
            cell.xoffset = 0;
        }
        return cell;
    }
};

pub const Geometry = struct {
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    cell_width: u16,
    cell_height: u16,
};

pub const Cell = struct {
    col: i32,
    row: i32,
    xoffset: u16 = 0,
    yoffset: u16 = 0,
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn fmt(buf: []u8, value: Event) error{WriteFailed}!cbor.Raw {
    var writer: std.Io.Writer = .fixed(buf);
    try cbor.writeValue(&writer, value);
    return .{ .bytes = writer.buffered() };
}

test "cbor round-trip preserves every field" {
    const cases = [_]Event{
        .{ .motion, .none, .{ .x = 12, .y = 34 }, .{} },
        .{ .press, .left, .{ .x = 100, .y = 200 }, .{ .ctrl = true } },
        .{ .release, .right, .{ .x = -5, .y = 7 }, .{ .alt = true, .shift = true } },
        .{ .drag, .middle, .{ .x = 0, .y = 0 }, .{} },
        .{ .press, .wheel_up, .{ .x = 9, .y = 9 }, .{} },
    };
    for (cases) |ev| {
        var buf: [64]u8 = undefined;
        const encoded = try fmt(&buf, ev);
        var decoded: Event = undefined;
        try expect(try cbor.match(encoded.bytes, cbor.extract(&decoded)));
        try expectEqual(ev.@"0", decoded.@"0");
        try expectEqual(ev.@"1", decoded.@"1");
        try expectEqual(ev.@"2".x, decoded.@"2".x);
        try expectEqual(ev.@"2".y, decoded.@"2".y);
        try expectEqual(ev.@"3", decoded.@"3");
    }
}

test "literal type/button can be matched directly" {
    const ev: Event = .{ .press, .left, .{ .x = 3, .y = 4 }, .{} };
    var buf: [64]u8 = undefined;
    const encoded = try fmt(&buf, ev);
    try expect(try cbor.match(encoded.bytes, .{ Type.press, Button.left, cbor.more }));
    try expect(!try cbor.match(encoded.bytes, .{ Type.release, Button.left, cbor.more }));
}

test "to_cell maps pixels into a grid at the origin" {
    const ev: Event = .{ .motion, .none, .{ .x = 25, .y = 45 }, .{} };
    const cell = ev.@"2".to_cell(.{ .cell_width = 10, .cell_height = 20 });
    try expectEqual(@as(i32, 2), cell.col);
    try expectEqual(@as(i32, 2), cell.row);
    try expectEqual(@as(u16, 5), cell.xoffset);
    try expectEqual(@as(u16, 5), cell.yoffset);
}

test "to_cell respects a layer origin off the screen grid" {
    // A layer whose top-left sits at pixel (8, 3) and whose cells are 7x11 -
    // deliberately not aligned to any global cell size.
    const geom: Geometry = .{ .origin_x = 8, .origin_y = 3, .cell_width = 7, .cell_height = 11 };
    const ev: Event = .{ .press, .left, .{ .x = 8 + 7 * 3 + 2, .y = 3 + 11 * 4 + 5 }, .{} };
    const cell = ev.@"2".to_cell(geom);
    try expectEqual(@as(i32, 3), cell.col);
    try expectEqual(@as(i32, 4), cell.row);
    try expectEqual(@as(u16, 2), cell.xoffset);
    try expectEqual(@as(u16, 5), cell.yoffset);
}

test "to_cell terminal degenerate case: a pixel is a cell" {
    const ev: Event = .{ .motion, .none, .{ .x = 42, .y = 7 }, .{} };
    const cell = ev.@"2".to_cell(.{ .cell_width = 1, .cell_height = 1 });
    try expectEqual(@as(i32, 42), cell.col);
    try expectEqual(@as(i32, 7), cell.row);
    try expectEqual(@as(u16, 0), cell.xoffset);
    try expectEqual(@as(u16, 0), cell.yoffset);
}

test "to_cell handles points left/above the origin" {
    const geom: Geometry = .{ .origin_x = 100, .origin_y = 100, .cell_width = 10, .cell_height = 10 };
    const ev: Event = .{ .motion, .none, .{ .x = 95, .y = 88 }, .{} };
    const cell = ev.@"2".to_cell(geom);
    // dx = -5 -> floor(-5/10) = -1, mod = 5 ; dy = -12 -> floor = -2, mod = 8
    try expectEqual(@as(i32, -1), cell.col);
    try expectEqual(@as(i32, -2), cell.row);
    try expectEqual(@as(u16, 5), cell.xoffset);
    try expectEqual(@as(u16, 8), cell.yoffset);
}

test "to_cell_nearest_x rounds to the next column past the half cell" {
    const geom: Geometry = .{ .cell_width = 10, .cell_height = 10 };
    // left half stays put
    try expectEqual(@as(i32, 2), (Coord{ .x = 24, .y = 0 }).to_cell_nearest_x(geom).col);
    // exactly half stays put (offset 5 is not > 5)
    try expectEqual(@as(i32, 2), (Coord{ .x = 25, .y = 0 }).to_cell_nearest_x(geom).col);
    // right half rounds up
    try expectEqual(@as(i32, 3), (Coord{ .x = 26, .y = 0 }).to_cell_nearest_x(geom).col);
}
