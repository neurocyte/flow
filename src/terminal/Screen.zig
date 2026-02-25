const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("../../main.zig");

const ansi = @import("ansi.zig");

const log = std.log.scoped(.vaxis_terminal);

const Screen = @This();

pub const Cell = struct {
    char: std.ArrayList(u8) = .empty,
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
    width: u8 = 1,

    wrapped: bool = false,
    dirty: bool = true,

    pub fn erase(self: *Cell, allocator: std.mem.Allocator, bg: vaxis.Color) void {
        self.char.clearRetainingCapacity();
        self.char.append(allocator, ' ') catch unreachable; // we never completely free this list
        self.style = .{};
        self.style.bg = bg;
        self.uri.clearRetainingCapacity();
        self.uri_id.clearRetainingCapacity();
        self.width = 1;
        self.wrapped = false;
        self.dirty = true;
    }

    pub fn copyFrom(self: *Cell, allocator: std.mem.Allocator, src: Cell) !void {
        self.char.clearRetainingCapacity();
        try self.char.appendSlice(allocator, src.char.items);
        self.style = src.style;
        self.uri.clearRetainingCapacity();
        try self.uri.appendSlice(allocator, src.uri.items);
        self.uri_id.clearRetainingCapacity();
        try self.uri_id.appendSlice(allocator, src.uri_id.items);
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

allocator: std.mem.Allocator,

width: u16 = 0,
height: u16 = 0,
visible_top: usize = 0,

scrolling_region: ScrollingRegion,

buf: []Cell = undefined,

cursor: Cursor = .{},

csi_u_flags: vaxis.Key.KittyFlags = @bitCast(@as(u5, 0)),

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !Screen {
    return initScrollback(alloc, w, h, 0);
}

pub fn initScrollback(alloc: std.mem.Allocator, w: u16, visible_h: u16, scrollback: u16) !Screen {
    const total_h: usize = @as(usize, visible_h) + scrollback;
    var screen = Screen{
        .allocator = alloc,
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * total_h),
        .scrolling_region = .{
            .top = 0,
            .bottom = visible_h - 1,
            .left = 0,
            .right = w - 1,
        },
        .width = w,
        .height = visible_h,
        .visible_top = 0,
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try .initCapacity(alloc, 1),
        };
        try screen.buf[i].char.append(alloc, ' ');
    }
    return screen;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i].char.deinit(alloc);
        self.buf[i].uri.deinit(alloc);
        self.buf[i].uri_id.deinit(alloc);
    }

    alloc.free(self.buf);
}

/// Copy the visible area (or a scrolled-back view) to the destination screen
/// `scroll_offset` is the number of history rows to look back (0 = live view)
pub fn copyTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen, scroll_offset: usize) !void {
    dst.cursor = self.cursor;
    var dst_row: usize = 0;
    while (dst_row < self.height) : (dst_row += 1) {
        const src_row = (self.visible_top -| scroll_offset) + dst_row;
        var col: usize = 0;
        while (col < self.width) : (col += 1) {
            const src_i = src_row * self.width + col;
            const dst_i = dst_row * self.width + col;
            const cell = &self.buf[src_i];
            if (!cell.dirty) continue;
            self.buf[src_i].dirty = false;
            dst.buf[dst_i].char.clearRetainingCapacity();
            try dst.buf[dst_i].char.appendSlice(allocator, cell.char.items);
            dst.buf[dst_i].width = cell.width;
            dst.buf[dst_i].style = cell.style;
        }
    }
}

/// Copy history rows from `self` into `dst`, which must be a freshly
/// initialised scrollback screen
pub fn copyHistoryTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen) !void {
    const src_history = self.visible_top;
    const dst_capacity = dst.buf.len / dst.width - dst.height;
    const copy_rows = @min(src_history, dst_capacity);
    if (copy_rows == 0) return;

    dst.visible_top = copy_rows;

    const copy_cols = @min(self.width, dst.width);

    var i: usize = 0;
    while (i < copy_rows) : (i += 1) {
        const src_row = src_history - copy_rows + i;
        const dst_row = i;
        var col: usize = 0;
        while (col < copy_cols) : (col += 1) {
            const src_i = src_row * self.width + col;
            const dst_i = dst_row * dst.width + col;
            try dst.buf[dst_i].copyFrom(allocator, self.buf[src_i]);
            dst.buf[dst_i].dirty = true;
        }
    }
}

/// Copy the visible viewport from `self` into `dst` for a vertical resize
pub fn copyViewportTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen) !void {
    const old_h: usize = self.height;
    const new_h: usize = dst.height;
    const copy_cols = @min(self.width, dst.width);
    const old_cursor: usize = self.cursor.row;

    var src_vp_start: usize = 0;
    var new_cursor_row: usize = 0;

    if (new_h >= old_h) {
        const delta = new_h - old_h;
        const pull = @min(delta, dst.visible_top);
        dst.visible_top -= pull;
        src_vp_start = 0;
        new_cursor_row = @min(new_h - 1, pull + old_cursor);
        var vp_row: usize = 0;
        while (vp_row < old_h) : (vp_row += 1) {
            const src_buf_row = self.visible_top + vp_row;
            const dst_buf_row = dst.visible_top + pull + vp_row;
            var col: usize = 0;
            while (col < copy_cols) : (col += 1) {
                const src_i = src_buf_row * self.width + col;
                const dst_i = dst_buf_row * dst.width + col;
                try dst.buf[dst_i].copyFrom(allocator, self.buf[src_i]);
            }
        }
    } else {
        const keep_above = @min(old_cursor, new_h - 1);
        src_vp_start = old_cursor - keep_above;
        new_cursor_row = keep_above;

        const dst_capacity = dst.buf.len / dst.width - dst.height;
        const space_in_history = dst_capacity -| dst.visible_top;
        const push = @min(src_vp_start, space_in_history);

        var i: usize = 0;
        while (i < push) : (i += 1) {
            const src_vp_row = src_vp_start - push + i;
            const src_buf_row = self.visible_top + src_vp_row;
            const dst_hist_row = dst.visible_top + i;
            var col: usize = 0;
            while (col < copy_cols) : (col += 1) {
                const src_i = src_buf_row * self.width + col;
                const dst_i = dst_hist_row * dst.width + col;
                try dst.buf[dst_i].copyFrom(allocator, self.buf[src_i]);
                dst.buf[dst_i].dirty = true;
            }
        }
        dst.visible_top += push;

        var vp_row: usize = 0;
        while (vp_row < new_h) : (vp_row += 1) {
            const src_buf_row = self.visible_top + src_vp_start + vp_row;
            const dst_buf_row = dst.visible_top + vp_row;
            var col: usize = 0;
            while (col < copy_cols) : (col += 1) {
                const src_i = src_buf_row * self.width + col;
                const dst_i = dst_buf_row * dst.width + col;
                try dst.buf[dst_i].copyFrom(allocator, self.buf[src_i]);
            }
        }
    }

    dst.cursor = self.cursor;
    dst.cursor.row = @intCast(new_cursor_row);
    dst.scrolling_region.bottom = @intCast(new_h - 1);
    dst.scrolling_region.right = @intCast(dst.width - 1);

    const vp_start = dst.visible_top * dst.width;
    const vp_end = vp_start + new_h * dst.width;
    for (dst.buf[vp_start..vp_end]) |*cell| cell.dirty = true;
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
    const i = self.rowIndex(row, col);
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

/// absolute buffer index for (row, col) in the visible viewport
inline fn rowIndex(self: *const Screen, row: usize, col: usize) usize {
    return (self.visible_top + row) * self.width + col;
}

/// history lines available above the current viewport
pub fn historySize(self: *const Screen) usize {
    return self.visible_top;
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

    const i = self.rowIndex(row, col);
    assert(i < self.buf.len);
    self.buf[i].char.clearRetainingCapacity();
    self.buf[i].char.appendSlice(self.allocator, grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri.appendSlice(self.allocator, self.cursor.uri.items) catch {
        log.warn("couldn't write uri", .{});
    };
    self.buf[i].uri_id.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(self.allocator, self.cursor.uri_id.items) catch {
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
        const full_screen = self.scrolling_region.top == 0 and
            self.scrolling_region.bottom == self.height - 1 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.width - 1;
        const total_rows = self.buf.len / self.width;
        if (full_screen and self.visible_top + self.height < total_rows) {
            self.visible_top += 1;
            const new_bottom = self.rowIndex(self.height - 1, 0);
            for (self.buf[new_bottom .. new_bottom + self.width]) |*cell| {
                cell.erase(self.allocator, self.cursor.style.bg);
            }
            const viewport_start = self.visible_top * self.width;
            const viewport_end = viewport_start + @as(usize, self.height) * self.width;
            for (self.buf[viewport_start..viewport_end]) |*cell| cell.dirty = true;
        } else {
            try self.deleteLine(1);
        }
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
    const start = self.rowIndex(self.cursor.row, self.cursor.col);
    const end = self.rowIndex(self.cursor.row, self.width);
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseLeft(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const start = self.rowIndex(self.cursor.row, 0);
    const end = self.rowIndex(self.cursor.row, self.cursor.col + 1);
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseLine(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const start = self.rowIndex(self.cursor.row, 0);
    const end = self.rowIndex(self.cursor.row, self.width);
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
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
            const i = self.rowIndex(row, col);
            if (row + cnt > self.scrolling_region.bottom)
                self.buf[i].erase(self.allocator, self.cursor.style.bg)
            else
                try self.buf[i].copyFrom(self.allocator, self.buf[i + stride]);
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
            const i = self.rowIndex(row, col);
            try self.buf[i].copyFrom(self.allocator, self.buf[i - stride]);
        }
    }

    row = self.scrolling_region.top;
    while (row < self.scrolling_region.top + adjusted_n) : (row += 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = self.rowIndex(row, col);
            self.buf[i].erase(self.allocator, self.cursor.style.bg);
        }
    }
}

pub fn eraseBelow(self: *Screen) void {
    self.eraseRight();
    // erase all cells from the row below cursor to the bottom of the visible area
    const start = self.rowIndex(self.cursor.row + 1, 0);
    const end = self.rowIndex(self.height, 0);
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseAbove(self: *Screen) void {
    self.eraseLeft();
    // erase from the top of the visible area up to (but not including) cursor row
    const start = self.rowIndex(0, 0);
    const end = self.rowIndex(self.cursor.row, 0);
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseAll(self: *Screen) void {
    var i = self.rowIndex(0, 0);
    const end = self.rowIndex(self.height, 0);
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn deleteCharacters(self: *Screen, n: usize) !void {
    if (!self.withinScrollingRegion()) return;

    self.cursor.pending_wrap = false;
    var col = self.cursor.col;
    while (col <= self.scrolling_region.right) : (col += 1) {
        const i = self.rowIndex(self.cursor.row, col);
        if (col + n <= self.scrolling_region.right)
            try self.buf[i].copyFrom(self.allocator, self.buf[self.rowIndex(self.cursor.row, col + n)])
        else
            self.buf[i].erase(self.allocator, self.cursor.style.bg);
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
