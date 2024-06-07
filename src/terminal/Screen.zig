const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("../../main.zig");

const log = std.log.scoped(.terminal);

const Screen = @This();

pub const Cell = struct {
    char: std.ArrayList(u8) = undefined,
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    width: u8 = 0,

    wrapped: bool = false,
    dirty: bool = true,
};

pub const Cursor = struct {
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    col: usize = 0,
    row: usize = 0,
    pending_wrap: bool = false,
    shape: vaxis.Cell.CursorShape = .default,

    pub fn isOutsideScrollingRegion(self: Cursor, sr: ScrollingRegion) bool {
        return self.row < sr.top or
            self.row > sr.bottom or
            self.col < sr.left or
            self.col > sr.right;
    }

    pub fn isInsideScrollingRegion(self: Cursor, sr: ScrollingRegion) bool {
        return !self.isOutsideScrollingRegion(sr);
    }
};

pub const ScrollingRegion = struct {
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,

    pub fn contains(self: ScrollingRegion, col: usize, row: usize) bool {
        return col >= self.left and
            col <= self.right and
            row >= self.top and
            row <= self.bottom;
    }
};

width: usize = 0,
height: usize = 0,

scrolling_region: ScrollingRegion,

buf: []Cell = undefined,

cursor: Cursor = .{},

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !Screen {
    var screen = Screen{
        .buf = try alloc.alloc(Cell, w * h),
        .scrolling_region = .{
            .top = 0,
            .bottom = h - 1,
            .left = 0,
            .right = w - 1,
        },
        .width = w,
        .height = h,
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try std.ArrayList(u8).initCapacity(alloc, 1),
            .uri = std.ArrayList(u8).init(alloc),
            .uri_id = std.ArrayList(u8).init(alloc),
        };
        try screen.buf[i].char.append(' ');
    }
    return screen;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i].char.deinit();
        self.buf[i].uri.deinit();
        self.buf[i].uri_id.deinit();
    }

    alloc.free(self.buf);
}

/// copies the visible area to the destination screen
pub fn copyTo(self: *Screen, dst: *Screen) !void {
    for (self.buf, 0..) |cell, i| {
        if (!cell.dirty) continue;
        self.buf[i].dirty = false;
        const grapheme = cell.char.items;
        dst.buf[i].char.clearRetainingCapacity();
        try dst.buf[i].char.appendSlice(grapheme);
        dst.buf[i].width = cell.width;
        dst.buf[i].style = cell.style;
    }
}

pub fn readCell(self: *Screen, col: usize, row: usize) ?vaxis.Cell {
    if (self.width < col) {
        // column out of bounds
        return null;
    }
    if (self.height < row) {
        // height out of bounds
        return null;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    const cell = self.buf[i];
    return .{
        .char = .{ .grapheme = cell.char.items, .width = cell.width },
        .style = cell.style,
    };
}

/// writes a cell to a location. 0 indexed
pub fn print(
    self: *Screen,
    grapheme: []const u8,
    width: u8,
) void {

    // FIXME: wrapping
    // if (self.cursor.col + width >= self.width) {
    //     self.cursor.col = 0;
    //     self.cursor.row += 1;
    // }
    if (self.cursor.col >= self.width) return;
    if (self.cursor.row >= self.height) return;
    const col = self.cursor.col;
    const row = self.cursor.row;

    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i].char.clearRetainingCapacity();
    self.buf[i].char.appendSlice(grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri.appendSlice(self.cursor.uri.items) catch {
        log.warn("couldn't write uri", .{});
    };
    self.buf[i].uri_id.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(self.cursor.uri_id.items) catch {
        log.warn("couldn't write uri_id", .{});
    };
    self.buf[i].style = self.cursor.style;
    self.buf[i].width = width;
    self.buf[i].dirty = true;

    self.cursor.col += width;
    // FIXME: when do we set default in this function??
    // self.buf[i].default = false;
}

/// IND
pub fn index(self: *Screen) !void {
    self.cursor.pending_wrap = false;

    if (self.cursor.isOutsideScrollingRegion(self.scrolling_region)) {
        // Outside, we just move cursor down one
        self.cursor.row = @min(self.height - 1, self.cursor.row + 1);
        return;
    }
    // We are inside the scrolling region
    if (self.cursor.row == self.scrolling_region.bottom) {
        // Inside scrolling region *and* at bottom of screen, we scroll contents up and insert a
        // blank line
        // TODO: scrollback if scrolling region is entire visible screen
        @panic("TODO");
    }
    self.cursor.row += 1;
}

fn Parameter(T: type) type {
    return struct {
        const Self = @This();
        val: T,
        // indicates the next parameter is a sub-parameter
        has_sub: bool = false,
        is_empty: bool = false,

        const Iterator = struct {
            bytes: []const u8,
            idx: usize = 0,

            fn next(self: *Iterator) ?Self {
                const start = self.idx;
                var val: T = 0;
                while (self.idx < self.bytes.len) {
                    defer self.idx += 1; // defer so we trigger on return as well
                    const b = self.bytes[self.idx];
                    switch (b) {
                        0x30...0x39 => {
                            val = (val * 10) + (b - 0x30);
                            if (self.idx == self.bytes.len - 1) return .{ .val = val };
                        },
                        ':', ';' => return .{
                            .val = val,
                            .is_empty = self.idx == start,
                            .has_sub = b == ':',
                        },
                        else => return null,
                    }
                }
                return null;
            }
        };
    };
}

pub fn sgr(self: *Screen, seq: []const u8) void {
    if (seq.len == 0) {
        self.cursor.style = .{};
        return;
    }
    switch (seq[0]) {
        0x30...0x39 => {},
        else => return, // TODO: handle private indicator sequences
    }

    var iter: Parameter(u8).Iterator = .{ .bytes = seq };
    while (iter.next()) |ps| {
        switch (ps.val) {
            0 => self.cursor.style = .{},
            1 => self.cursor.style.bold = true,
            2 => self.cursor.style.dim = true,
            3 => self.cursor.style.italic = true,
            4 => {
                const kind: vaxis.Style.Underline = if (ps.has_sub) blk: {
                    const ul = iter.next() orelse break :blk .single;
                    break :blk @enumFromInt(ul.val);
                } else .single;
                self.cursor.style.ul_style = kind;
            },
            5 => self.cursor.style.blink = true,
            7 => self.cursor.style.reverse = true,
            8 => self.cursor.style.invisible = true,
            9 => self.cursor.style.strikethrough = true,
            21 => self.cursor.style.ul_style = .double,
            22 => {
                self.cursor.style.bold = false;
                self.cursor.style.dim = false;
            },
            23 => self.cursor.style.italic = false,
            24 => self.cursor.style.ul_style = .off,
            25 => self.cursor.style.blink = false,
            27 => self.cursor.style.reverse = false,
            28 => self.cursor.style.invisible = false,
            29 => self.cursor.style.strikethrough = false,
            30...37 => self.cursor.style.fg = .{ .index = ps.val - 30 },
            38 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind.val) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            while (ps_r.is_empty) {
                                ps_r = iter.next() orelse return;
                            }
                            break :r ps_r.val;
                        };
                        const g = g: {
                            const ps_g = iter.next() orelse return;
                            break :g ps_g.val;
                        };
                        const b = b: {
                            const ps_b = iter.next() orelse return;
                            break :b ps_b.val;
                        };
                        self.cursor.style.fg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.fg = .{ .index = idx.val };
                    }, // index
                    else => return,
                }
            },
            39 => self.cursor.style.fg = .default,
            40...47 => self.cursor.style.bg = .{ .index = ps.val - 40 },
            48 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind.val) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            while (ps_r.is_empty) {
                                ps_r = iter.next() orelse return;
                            }
                            break :r ps_r.val;
                        };
                        const g = g: {
                            const ps_g = iter.next() orelse return;
                            break :g ps_g.val;
                        };
                        const b = b: {
                            const ps_b = iter.next() orelse return;
                            break :b ps_b.val;
                        };
                        self.cursor.style.bg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => { // index
                        const idx = iter.next() orelse return;
                        self.cursor.style.bg = .{ .index = idx.val };
                    },
                    else => return,
                }
            },
            49 => self.cursor.style.bg = .default,
            90...97 => self.cursor.style.fg = .{ .index = ps.val - 90 + 8 },
            100...107 => self.cursor.style.bg = .{ .index = ps.val - 100 + 8 },
            else => continue,
        }
    }
}

pub fn cursorLeft(self: *Screen, n: usize) void {
    // default to 1, max of current cursor location
    const cnt = @min(self.cursor.col, @max(n, 1));

    self.cursor.pending_wrap = false;
    self.cursor.col -= cnt;
}
