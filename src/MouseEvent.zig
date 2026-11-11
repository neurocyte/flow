const std = @import("std");
const vaxis = @import("vaxis");
const cbor = @import("cbor");
const MouseModifier = @import("config").MouseModifier;
const Writer = std.Io.Writer;

pub const Type = enum {
    press,
    release,
    motion,
    drag,

    pub fn to_vaxis(self: @This()) vaxis.Mouse.Type {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }
    pub fn from_vaxis(t: vaxis.Mouse.Type) Type {
        return @fromBackingInt(@intCast(@backingInt(t)));
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
        return @fromBackingInt(@intCast(@backingInt(self)));
    }
    pub fn from_vaxis(b: vaxis.Mouse.Button) Button {
        return @fromBackingInt(@intCast(@backingInt(b)));
    }
};

pub const Modifiers = packed struct(u4) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
        try cbor.writeValue(writer, @as(u4, @bitCast(self)));
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        var value: u4 = 0;
        if (try cbor.matchValue(iter, cbor.extract(&value))) {
            self.* = @bitCast(value);
            return true;
        }
        return false;
    }

    pub fn has(self: @This(), mod: MouseModifier) bool {
        return switch (mod) {
            .none => false,
            .shift => self.shift,
            .alt => self.alt,
            .ctrl => self.ctrl,
            .super => self.super,
        };
    }

    pub fn to_vaxis(self: @This()) vaxis.Mouse.Modifiers {
        return .{ .shift = self.shift, .alt = self.alt, .ctrl = self.ctrl };
    }
    pub fn from_vaxis(mods: vaxis.Mouse.Modifiers) Modifiers {
        return .{ .shift = mods.shift, .alt = mods.alt, .ctrl = mods.ctrl };
    }
};

pub const Event = struct {
    Type,
    Button,
    Coord,
    Modifiers,
};

pub const Scroll = struct {
    coord: Coord,
    mods: Modifiers = .{},
    source: Source = .unknown,
    phase: Phase = .move,
    axis: Axis,
    amount: Amount = .{},

    pub const Amount = struct {
        step: Coord = .zero,
        delta: Coord = .zero,

        pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
            try cbor.writeValue(writer, .{ self.step, self.delta });
        }
        pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
            return cbor.matchValue(iter, .{ cbor.extract(&self.step), cbor.extract(&self.delta) });
        }
    };

    pub const Source = enum { unknown, wheel, finger, continuous };

    pub const Axis = enum { x, y };

    pub const Phase = enum {
        move,
        /// fingers left touchpad
        stop,
        /// motion (from OS) after a stop
        momentum,
    };

    pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
        try cbor.writeValue(writer, .{ self.coord, self.mods, self.source, self.phase, self.axis, self.amount });
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{
            cbor.extract(&self.coord),
            cbor.extract(&self.mods),
            cbor.extract(&self.source),
            cbor.extract(&self.phase),
            cbor.extract(&self.axis),
            cbor.extract(&self.amount),
        });
    }

    pub const Input = struct {
        coord: Coord,
        mods: Modifiers = .{},
        source: Source = .unknown,
        phase: Phase = .move,
        axis: Axis,
        unit: Unit,
        delta: CoordF32 = .zero,

        pub const Unit = enum { steps, pixels };

        pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
            try cbor.writeValue(writer, .{
                self.coord, self.mods, self.source,
                self.phase, self.axis, self.unit,
                self.delta,
            });
        }

        pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
            return cbor.matchValue(iter, .{
                cbor.extract(&self.coord), cbor.extract(&self.mods), cbor.extract(&self.source),
                cbor.extract(&self.phase), cbor.extract(&self.axis), cbor.extract(&self.unit),
                cbor.extract(&self.delta),
            });
        }
    };

    pub const Accumulator = struct {
        x: AxisState,
        y: AxisState,

        pub const init: @This() = .{ .x = .{}, .y = .{} };

        pub fn scroll(self: *@This(), unit: Input.Unit, delta: CoordF32, pixels_per_step: f32, delta_multiplier: f32) Amount {
            const x = self.x.scroll(unit, delta.x, pixels_per_step, delta_multiplier);
            const y = self.y.scroll(unit, delta.y, pixels_per_step, delta_multiplier);
            return .{
                .step = .{ .x = x.step, .y = y.step },
                .delta = .{ .x = x.delta, .y = y.delta },
            };
        }

        const AxisState = struct {
            step_rest: f32 = 0,
            delta_rest: f32 = 0,
            negative: bool = false,

            const AxisResult = struct { step: i32 = 0, delta: i32 = 0 };

            fn scroll(self: *@This(), unit: Input.Unit, delta: f32, pixels_per_step: f32, delta_multiplier: f32) AxisResult {
                return switch (unit) {
                    .steps => self.add(delta, delta * @max(1, pixels_per_step)),
                    .pixels => self.add(delta / @max(1, pixels_per_step), delta * delta_multiplier),
                };
            }

            fn add(self: *@This(), steps: f32, delta: f32) AxisResult {
                if (delta == 0) return .{};
                const negative = delta < 0;
                if (negative != self.negative) self.* = .{ .negative = negative };

                self.step_rest += steps;
                const step = @trunc(self.step_rest);
                self.step_rest -= step;

                self.delta_rest += delta;
                const whole = @trunc(self.delta_rest);
                self.delta_rest -= whole;

                return .{ .step = @intFromFloat(step), .delta = @intFromFloat(whole) };
            }
        };
    };
};

pub const Coord = struct {
    x: i32,
    y: i32,

    pub const zero: @This() = .{ .x = 0, .y = 0 };

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

pub const CoordF32 = struct {
    x: f32,
    y: f32,

    pub const zero: @This() = .{ .x = 0, .y = 0 };

    pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
        try cbor.writeValue(writer, .{ self.x, self.y });
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
        return cbor.matchValue(iter, .{ cbor.extract(&self.x), cbor.extract(&self.y) });
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

    pub fn from_vaxis(m: vaxis.Mouse) @This() {
        return .{
            .col = m.col,
            .row = m.row,
            .xoffset = m.xoffset,
            .yoffset = m.yoffset,
        };
    }

    pub fn to_coord(self: @This(), geom: Geometry) Coord {
        return .{
            .x = self.col * @as(i32, @max(1, geom.cell_width)) + self.xoffset,
            .y = self.row * @as(i32, @max(1, geom.cell_height)) + self.yoffset,
        };
    }
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

test "scroll cbor round-trip preserves every field" {
    const ev: Scroll = .{
        .coord = .{ .x = -3, .y = 40 },
        .mods = .{ .ctrl = true },
        .source = .finger,
        .phase = .momentum,
        .axis = .x,
        .amount = .{ .step = .{ .x = -1, .y = 2 }, .delta = .{ .x = -30, .y = 125 } },
    };
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try cbor.writeValue(&writer, .{ "scroll", ev });
    var decoded: Scroll = undefined;
    try expect(try cbor.match(writer.buffered(), .{ "scroll", cbor.extract(&decoded) }));
    try std.testing.expectEqualDeep(ev, decoded);
}

test "scroll input cbor round-trip preserves every field" {
    const ev: Scroll.Input = .{
        .coord = .{ .x = 7, .y = 9 },
        .mods = .{ .shift = true },
        .source = .wheel,
        .phase = .stop,
        .axis = .x,
        .unit = .pixels,
        .delta = .{ .x = -0.5, .y = 12.25 },
    };
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try cbor.writeValue(&writer, .{ "scroll_input", ev });
    var decoded: Scroll.Input = undefined;
    try expect(try cbor.match(writer.buffered(), .{ "scroll_input", cbor.extract(&decoded) }));
    try std.testing.expectEqualDeep(ev, decoded);
}

fn amount(step_x: i32, step_y: i32, delta_x: i32, delta_y: i32) Scroll.Amount {
    return .{ .step = .{ .x = step_x, .y = step_y }, .delta = .{ .x = delta_x, .y = delta_y } };
}

test "accumulator: whole steps give one step and pixels_per_step pixels each" {
    var acc: Scroll.Accumulator = .init;
    try std.testing.expectEqualDeep(amount(0, 1, 0, 60), acc.scroll(.steps, .{ .x = 0, .y = 1 }, 60, 1));
    try std.testing.expectEqualDeep(amount(-2, 0, -120, 0), acc.scroll(.steps, .{ .x = -2, .y = 0 }, 60, 1));
}

test "accumulator: fractional steps add up to a step" {
    var acc: Scroll.Accumulator = .init;
    try std.testing.expectEqualDeep(amount(0, 0, 0, 7), acc.scroll(.steps, .{ .x = 0, .y = 0.125 }, 60, 1));
    for (0..6) |_| _ = acc.scroll(.steps, .{ .x = 0, .y = 0.125 }, 60, 1);
    try std.testing.expectEqualDeep(amount(0, 1, 0, 8), acc.scroll(.steps, .{ .x = 0, .y = 0.125 }, 60, 1));
}

test "accumulator: pixels give a step per pixels_per_step" {
    var acc: Scroll.Accumulator = .init;
    try std.testing.expectEqualDeep(amount(0, 0, 0, 25), acc.scroll(.pixels, .{ .x = 0, .y = 25 }, 60, 1));
    try std.testing.expectEqualDeep(amount(0, 0, 0, 25), acc.scroll(.pixels, .{ .x = 0, .y = 25 }, 60, 1));
    try std.testing.expectEqualDeep(amount(0, 1, 0, 25), acc.scroll(.pixels, .{ .x = 0, .y = 25 }, 60, 1));
}

test "accumulator: the multiplier scales pixel deltas but not steps" {
    var acc: Scroll.Accumulator = .init;
    try std.testing.expectEqualDeep(amount(0, 0, 0, 50), acc.scroll(.pixels, .{ .x = 0, .y = 25 }, 60, 2));
    try std.testing.expectEqualDeep(amount(0, 0, 0, 50), acc.scroll(.pixels, .{ .x = 0, .y = 25 }, 60, 2));
    try std.testing.expectEqualDeep(amount(0, 1, 0, 50), acc.scroll(.pixels, .{ .x = 0, .y = 25 }, 60, 2));
    try std.testing.expectEqualDeep(amount(0, 1, 0, 60), acc.scroll(.steps, .{ .x = 0, .y = 1 }, 60, 2));
}

test "accumulator: fractional pixels add up to a pixel" {
    var acc: Scroll.Accumulator = .init;
    try std.testing.expectEqualDeep(amount(0, 0, 0, 0), acc.scroll(.pixels, .{ .x = 0, .y = 0.5 }, 60, 1));
    try std.testing.expectEqualDeep(amount(0, 0, 0, 1), acc.scroll(.pixels, .{ .x = 0, .y = 0.5 }, 60, 1));
}

test "accumulator: a direction change drops the rest" {
    var acc: Scroll.Accumulator = .init;
    _ = acc.scroll(.pixels, .{ .x = 0, .y = 59.5 }, 60, 1);
    try std.testing.expectEqualDeep(amount(0, 0, 0, -1), acc.scroll(.pixels, .{ .x = 0, .y = -1 }, 60, 1));
    try std.testing.expectEqualDeep(amount(0, -1, 0, -59), acc.scroll(.pixels, .{ .x = 0, .y = -59 }, 60, 1));
}

test "accumulator: the axes accumulate separately" {
    var acc: Scroll.Accumulator = .init;
    try std.testing.expectEqualDeep(amount(0, 0, 30, 30), acc.scroll(.pixels, .{ .x = 30, .y = 30 }, 60, 1));
    try std.testing.expectEqualDeep(amount(0, 1, -1, 30), acc.scroll(.pixels, .{ .x = -1, .y = 30 }, 60, 1));
}

test "accumulator: a zero delta keeps the rest" {
    var acc: Scroll.Accumulator = .init;
    _ = acc.scroll(.steps, .{ .x = 0, .y = 0.5 }, 60, 1);
    try std.testing.expectEqualDeep(amount(0, 0, 0, 0), acc.scroll(.pixels, .zero, 60, 1));
    try std.testing.expectEqualDeep(amount(0, 1, 0, 30), acc.scroll(.steps, .{ .x = 0, .y = 0.5 }, 60, 1));
}

test "has matches the configured modifier and ignores the others" {
    const mods: Modifiers = .{ .ctrl = true, .alt = true };
    try expect(mods.has(.ctrl));
    try expect(mods.has(.alt));
    try expect(!mods.has(.shift));
    try expect(!mods.has(.super));
    try expect(!mods.has(.none));
    try expect(!(Modifiers{}).has(.none));
    try expect((Modifiers{ .super = true }).has(.super));
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
