const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("../../main.zig");

const ansi = @import("ansi.zig");

const log = std.log.scoped(.vaxis_terminal);

const Screen = @This();

pub const Cell = struct {
    char: std.ArrayList(u8) = undefined,
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    width: u8 = 1,

    wrapped: bool = false,
    dirty: bool = true,

    pub fn erase(self: *Cell, bg: vaxis.Color) void {
        self.char.clearRetainingCapacity();
        self.char.append(' ') catch unreachable; // we never completely free this list
        self.style = .{};
        self.style.bg = bg;
        self.uri.clearRetainingCapacity();
        self.uri_id.clearRetainingCapacity();
        self.width = 1;
        self.wrapped = false;
        self.dirty = true;
    }

    pub fn copyFrom(self: *Cell, src: Cell) !void {
        self.char.clearRetainingCapacity();
        try self.char.appendSlice(src.char.items);
        self.style = src.style;
        self.uri.clearRetainingCapacity();
        try self.uri.appendSlice(src.uri.items);
        self.uri_id.clearRetainingCapacity();
        try self.uri_id.appendSlice(src.uri_id.items);
        self.width = src.width;
        self.wrapped = src.wrapped;

        self.dirty = true;
    }
};

pub const Cursor = struct {
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    col: u16 = 0,
    row: u16 = 0,
    pending_wrap: bool = false,
    shape: vaxis.Cell.CursorShape = .default,
    visible: bool = true,

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
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,

    pub fn contains(self: ScrollingRegion, col: usize, row: usize) bool {
        return col >= self.left and
            col <= self.right and
            row >= self.top and
            row <= self.bottom;
    }
};

width: u16 = 0,
height: u16 = 0,

scrolling_region: ScrollingRegion,

buf: []Cell = undefined,

cursor: Cursor = .{},

csi_u_flags: vaxis.Key.KittyFlags = @bitCast(@as(u5, 0)),

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !Screen {
    var screen = Screen{
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * h),
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
    dst.cursor = self.cursor;
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

/// returns true if the current cursor position is within the scrolling region
pub fn withinScrollingRegion(self: Screen) bool {
    return self.scrolling_region.contains(self.cursor.col, self.cursor.row);
}

/// writes a cell to a location. 0 indexed
pub fn print(
    self: *Screen,
    grapheme: []const u8,
    width: u8,
    wrap: bool,
) !void {
    if (self.cursor.pending_wrap) {
        try self.index();
        self.cursor.col = self.scrolling_region.left;
    }
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

    if (wrap and self.cursor.col >= self.width - 1) self.cursor.pending_wrap = true;
    self.cursor.col += width;
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
        try self.deleteLine(1);
        return;
    }
    self.cursor.row += 1;
}

pub fn sgr(self: *Screen, seq: ansi.CSI) void {
    if (seq.params.len == 0) {
        self.cursor.style = .{};
        return;
    }

    var iter = seq.iterator(u8);
    while (iter.next()) |ps| {
        switch (ps) {
            0 => self.cursor.style = .{},
            1 => self.cursor.style.bold = true,
            2 => self.cursor.style.dim = true,
            3 => self.cursor.style.italic = true,
            4 => {
                const kind: vaxis.Style.Underline = if (iter.next_is_sub)
                    @enumFromInt(iter.next() orelse 1)
                else
                    .single;
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
            30...37 => self.cursor.style.fg = .{ .index = ps - 30 },
            38 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        self.cursor.style.fg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.fg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            39 => self.cursor.style.fg = .default,
            40...47 => self.cursor.style.bg = .{ .index = ps - 40 },
            48 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        self.cursor.style.bg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.bg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            49 => self.cursor.style.bg = .default,
            90...97 => self.cursor.style.fg = .{ .index = ps - 90 + 8 },
            100...107 => self.cursor.style.bg = .{ .index = ps - 100 + 8 },
            else => continue,
        }
    }
}

pub fn cursorUp(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.row = @max(
            self.cursor.row -| n,
            self.scrolling_region.top,
        )
    else
        self.cursor.row -|= n;
}

pub fn cursorLeft(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.col = @max(
            self.cursor.col -| n,
            self.scrolling_region.left,
        )
    else
        self.cursor.col = self.cursor.col -| n;
}

pub fn cursorRight(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.col = @min(
            self.cursor.col + n,
            self.scrolling_region.right,
        )
    else
        self.cursor.col = @min(
            self.cursor.col + n,
            self.width - 1,
        );
}

pub fn cursorDown(self: *Screen, n: usize) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.row = @min(
            self.scrolling_region.bottom,
            self.cursor.row + n,
        )
    else
        self.cursor.row = @min(
            self.height -| 1,
            self.cursor.row + n,
        );
}

pub fn eraseRight(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const end = (self.cursor.row * self.width) + (self.width);
    var i = (self.cursor.row * self.width) + self.cursor.col;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.cursor.style.bg);
    }
}

pub fn eraseLeft(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const start = self.cursor.row * self.width;
    const end = start + self.cursor.col + 1;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.cursor.style.bg);
    }
}

pub fn eraseLine(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const start = self.cursor.row * self.width;
    const end = start + self.width;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.cursor.style.bg);
    }
}

/// delete n lines from the bottom of the scrolling region
pub fn deleteLine(self: *Screen, n: usize) !void {
    if (n == 0) return;

    // Don't delete if outside scroll region
    if (!self.withinScrollingRegion()) return;

    self.cursor.pending_wrap = false;

    // Number of rows from here to bottom of scroll region or n
    const cnt = @min(self.scrolling_region.bottom - self.cursor.row + 1, n);
    const stride = (self.width) * cnt;

    var row: usize = self.scrolling_region.top;
    while (row <= self.scrolling_region.bottom) : (row += 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = (row * self.width) + col;
            if (row + cnt > self.scrolling_region.bottom)
                self.buf[i].erase(self.cursor.style.bg)
            else
                try self.buf[i].copyFrom(self.buf[i + stride]);
        }
    }
}

/// insert n lines at the top of the scrolling region
pub fn insertLine(self: *Screen, n: usize) !void {
    if (n == 0) return;

    self.cursor.pending_wrap = false;
    // Don't insert if outside scroll region
    if (!self.withinScrollingRegion()) return;

    const adjusted_n = @min(self.scrolling_region.bottom - self.cursor.row, n);
    const stride = (self.width) * adjusted_n;

    var row: usize = self.scrolling_region.bottom;
    while (row >= self.scrolling_region.top + adjusted_n) : (row -|= 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = (row * self.width) + col;
            try self.buf[i].copyFrom(self.buf[i - stride]);
        }
    }

    row = self.scrolling_region.top;
    while (row < self.scrolling_region.top + adjusted_n) : (row += 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = (row * self.width) + col;
            self.buf[i].erase(self.cursor.style.bg);
        }
    }
}

pub fn eraseBelow(self: *Screen) void {
    self.eraseRight();
    // start is the first column of the row below us
    const start = (self.cursor.row * self.width) + (self.width);
    var i = start;
    while (i < self.buf.len) : (i += 1) {
        self.buf[i].erase(self.cursor.style.bg);
    }
}

pub fn eraseAbove(self: *Screen) void {
    self.eraseLeft();
    // start is the first column of the row below us
    const start: usize = 0;
    const end = self.cursor.row * self.width;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.cursor.style.bg);
    }
}

pub fn eraseAll(self: *Screen) void {
    var i: usize = 0;
    while (i < self.buf.len) : (i += 1) {
        self.buf[i].erase(self.cursor.style.bg);
    }
}

pub fn deleteCharacters(self: *Screen, n: usize) !void {
    if (!self.withinScrollingRegion()) return;

    self.cursor.pending_wrap = false;
    var col = self.cursor.col;
    while (col <= self.scrolling_region.right) : (col += 1) {
        if (col + n <= self.scrolling_region.right)
            try self.buf[col].copyFrom(self.buf[col + n])
        else
            self.buf[col].erase(self.cursor.style.bg);
    }
}

pub fn reverseIndex(self: *Screen) !void {
    if (self.cursor.row != self.scrolling_region.top or
        self.cursor.col < self.scrolling_region.left or
        self.cursor.col > self.scrolling_region.right)
        self.cursorUp(1)
    else
        try self.scrollDown(1);
}

pub fn scrollDown(self: *Screen, n: usize) !void {
    const cur_row = self.cursor.row;
    const cur_col = self.cursor.col;
    const wrap = self.cursor.pending_wrap;
    defer {
        self.cursor.row = cur_row;
        self.cursor.col = cur_col;
        self.cursor.pending_wrap = wrap;
    }
    self.cursor.col = self.scrolling_region.left;
    self.cursor.row = self.scrolling_region.top;
    try self.insertLine(n);
}
