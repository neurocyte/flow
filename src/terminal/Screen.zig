const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const ansi = @import("ansi.zig");
const DoubleMappedRingBuffer = @import("DoubleMappedRingBuffer");

const log = std.log.scoped(.vaxis_terminal);

const Screen = @This();

/// SSO grapheme storage
pub const Grapheme = union(enum) {
    pub const inline_capacity = 22;

    inline_buf: Inline,
    heap: []u8,

    const Inline = struct {
        len: u8,
        buf: [inline_capacity]u8,
    };

    pub const empty: Grapheme = .{ .inline_buf = .{ .len = 0, .buf = undefined } };

    pub fn bytes(self: *const Grapheme) []const u8 {
        return switch (self.*) {
            .inline_buf => |*inl| inl.buf[0..inl.len],
            .heap => |h| h,
        };
    }

    pub fn set(self: *Grapheme, allocator: std.mem.Allocator, data: []const u8) void {
        if (data.len <= inline_capacity) {
            self.deinit(allocator);
            self.* = .{ .inline_buf = .{ .len = @intCast(data.len), .buf = undefined } };
            @memcpy(self.inline_buf.buf[0..data.len], data);
            return;
        }
        const new_buf: ?[]u8 = switch (self.*) {
            .heap => |h| allocator.realloc(h, data.len) catch null,
            .inline_buf => allocator.dupe(u8, data) catch null,
        };
        if (new_buf) |buf| {
            @memcpy(buf, data);
            self.* = .{ .heap = buf };
            return;
        }
        // On OOM keep as much as fits inline, but only whole codepoints
        self.deinit(allocator);
        var n: usize = inline_capacity;
        while (n > 0 and (data[n] & 0xC0) == 0x80) : (n -= 1) {}
        self.* = .{ .inline_buf = .{ .len = @intCast(n), .buf = undefined } };
        @memcpy(self.inline_buf.buf[0..n], data[0..n]);
    }

    pub fn deinit(self: *Grapheme, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .heap => |h| allocator.free(h),
            .inline_buf => {},
        }
        self.* = empty;
    }
};

pub const Cell = struct {
    char: Grapheme = .empty,
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
    width: u8 = 1,

    wrapped: bool = false,
    dirty: bool = true,

    pub fn erase(self: *Cell, allocator: std.mem.Allocator, bg: vaxis.Color) void {
        self.char.set(allocator, " ");
        self.style = .{};
        self.style.bg = bg;
        self.uri.clearRetainingCapacity();
        self.uri_id.clearRetainingCapacity();
        self.width = 1;
        self.wrapped = false;
        self.dirty = true;
    }

    pub fn copyFrom(self: *Cell, allocator: std.mem.Allocator, src: Cell) !void {
        self.char.set(allocator, src.char.bytes());
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

pub const CellRing = struct {
    drb: DoubleMappedRingBuffer,
    width: usize,
    rows: usize, // logical height
    cap_rows: usize, // physical capacity: cap_rows*row_bytes is page-sized
    head: usize,

    fn init(width: usize, rows: usize) !CellRing {
        assert(width >= 1 and rows >= 1);
        const row_bytes = width * @sizeOf(Cell);
        const page = std.heap.pageSize();
        const step = page / std.math.gcd(row_bytes, page);
        const cap_rows = ((rows + step - 1) / step) * step;
        return .{
            .drb = try DoubleMappedRingBuffer.init(cap_rows * row_bytes),
            .width = width,
            .rows = rows,
            .cap_rows = cap_rows,
            .head = 0,
        };
    }

    fn deinit(self: *CellRing) void {
        self.drb.deinit();
    }

    fn window(self: *const CellRing) []Cell {
        const row_bytes = self.width * @sizeOf(Cell);
        const bytes = self.drb.slice(self.head * row_bytes, self.rows * row_bytes);
        return @alignCast(std.mem.bytesAsSlice(Cell, bytes));
    }

    fn physical(self: *const CellRing) []Cell {
        return @alignCast(std.mem.bytesAsSlice(Cell, self.drb.data()));
    }

    fn advance(self: *CellRing) void {
        self.head = (self.head + 1) % self.cap_rows;
    }
};

pub const Cursor = struct {
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
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

    pub fn copyFrom(dst: *Cursor, src: Cursor, allocator: std.mem.Allocator) !void {
        dst.style = src.style;
        dst.col = src.col;
        dst.row = src.row;
        dst.pending_wrap = src.pending_wrap;
        dst.shape = src.shape;
        dst.visible = src.visible;
        dst.uri.clearRetainingCapacity();
        try dst.uri.appendSlice(allocator, src.uri.items);
        dst.uri_id.clearRetainingCapacity();
        try dst.uri_id.appendSlice(allocator, src.uri_id.items);
    }
};

/// Semantic prompt marks emitted by the shell via OSC 133
pub const PromptMarkKind = enum { prompt_start, input_start, output_start, output_end };

pub const PromptMark = struct {
    kind: PromptMarkKind,
    row: u32,
    col: u16,
    exit_code: ?i32 = null,
    click_events: bool = false,
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

ring: CellRing = undefined,
buf: []Cell = undefined,

cursor: Cursor = .{},

/// OSC 133 prompt/command markers
prompt_marks: std.ArrayList(PromptMark) = .empty,

csi_u_flags: vaxis.Key.KittyFlags = @bitCast(@as(u5, 0)),

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !Screen {
    return initScrollback(alloc, w, h, 0);
}

pub fn initScrollback(alloc: std.mem.Allocator, w: u16, visible_h: u16, scrollback: u16) !Screen {
    const total_h: usize = @as(usize, visible_h) + scrollback;
    var screen = Screen{
        .allocator = alloc,
        .ring = try CellRing.init(w, total_h),
        .buf = undefined,
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
    screen.buf = screen.ring.window();
    for (screen.ring.physical()) |*cell| {
        cell.* = .{};
        cell.char.set(alloc, " ");
    }
    return screen;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    for (self.ring.physical()) |*cell| {
        cell.char.deinit(alloc);
        cell.uri.deinit(alloc);
        cell.uri_id.deinit(alloc);
    }
    self.cursor.uri.deinit(alloc);
    self.cursor.uri_id.deinit(alloc);
    self.prompt_marks.deinit(alloc);

    self.ring.deinit();
}

/// Copy the visible area (or a scrolled-back view) to the destination screen
/// `scroll_offset` is the number of history rows to look back (0 = live view)
pub fn copyTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen, scroll_offset: usize) !void {
    try dst.cursor.copyFrom(self.cursor, allocator);
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
            dst.buf[dst_i].char.set(allocator, cell.char.bytes());
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

    const drop_start: u32 = @intCast(src_history - copy_rows);
    const src_history_u32: u32 = @intCast(src_history);
    try self.transferMarksRange(dst, allocator, drop_start, src_history_u32, 0);
}

fn transferMarksRange(
    self: *const Screen,
    dst: *Screen,
    allocator: std.mem.Allocator,
    src_top: u32,
    src_bot: u32,
    dst_top: u32,
) !void {
    for (self.prompt_marks.items) |mark| {
        if (mark.row < src_top or mark.row >= src_bot) continue;
        try dst.prompt_marks.append(allocator, .{
            .kind = mark.kind,
            .row = (mark.row - src_top) + dst_top,
            .col = mark.col,
            .exit_code = mark.exit_code,
            .click_events = mark.click_events,
        });
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
        const src_top: u32 = @intCast(self.visible_top);
        const src_bot: u32 = @intCast(self.visible_top + old_h);
        const dst_top: u32 = @intCast(dst.visible_top + pull);
        try self.transferMarksRange(dst, allocator, src_top, src_bot, dst_top);
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

        const src_top: u32 = @intCast(self.visible_top + src_vp_start - push);
        const src_bot: u32 = @intCast(self.visible_top + src_vp_start + new_h);
        const dst_top: u32 = @intCast(dst.visible_top - push);
        try self.transferMarksRange(dst, allocator, src_top, src_bot, dst_top);
    }

    try dst.cursor.copyFrom(self.cursor, allocator);
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
    const cell = &self.buf[i];
    return .{
        .char = .{ .grapheme = cell.char.bytes(), .width = cell.width },
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

pub fn addPromptMark(
    self: *Screen,
    allocator: std.mem.Allocator,
    kind: PromptMarkKind,
    exit_code: ?i32,
    click_events: bool,
) !void {
    const row: u32 = @intCast(self.visible_top + self.cursor.row);
    const col: u16 = self.cursor.col;
    if (self.prompt_marks.items.len > 0) {
        const last = self.prompt_marks.items[self.prompt_marks.items.len - 1];
        if (last.kind == kind and last.row == row and last.col == col) return;
    }
    try self.prompt_marks.append(allocator, .{
        .kind = kind,
        .row = row,
        .col = col,
        .exit_code = exit_code,
        .click_events = click_events,
    });
}

pub const CommandOutputRange = struct {
    start: u32,
    end: u32,
    exit_code: ?i32,
};

pub fn lastCommandOutputRange(self: *const Screen) ?CommandOutputRange {
    var i: usize = self.prompt_marks.items.len;
    while (i > 0) {
        i -= 1;
        const start_mark = self.prompt_marks.items[i];
        if (start_mark.kind != .output_start) continue;
        for (self.prompt_marks.items[i + 1 ..]) |later| switch (later.kind) {
            .output_end => return .{
                .start = start_mark.row,
                .end = later.row,
                .exit_code = later.exit_code,
            },
            .prompt_start => return .{
                .start = start_mark.row,
                .end = later.row,
                .exit_code = null,
            },
            else => {},
        };
        return .{
            .start = start_mark.row,
            .end = @intCast(self.visible_top + self.height),
            .exit_code = null,
        };
    }
    return null;
}

/// The output range of the command shown at `top_row` or the first command
/// if `top_row` is above all of them.
pub fn commandOutputRangeAt(self: *const Screen, top_row: usize) ?CommandOutputRange {
    var cmd_idx: ?usize = null;
    var first_idx: ?usize = null;
    for (self.prompt_marks.items, 0..) |mark, i| {
        if (mark.kind != .prompt_start) continue;
        if (first_idx == null) first_idx = i;
        if (self.commandTopRow(mark.row) <= top_row) cmd_idx = i;
    }
    const start_i = cmd_idx orelse first_idx orelse return null;
    var output_start: ?u32 = null;
    for (self.prompt_marks.items[start_i + 1 ..]) |m| switch (m.kind) {
        .output_start => output_start = m.row,
        .output_end => if (output_start) |s| return .{ .start = s, .end = m.row, .exit_code = m.exit_code },
        .prompt_start => return if (output_start) |s|
            .{ .start = s, .end = m.row, .exit_code = null }
        else
            null,
        else => {},
    };
    return if (output_start) |s|
        .{ .start = s, .end = @intCast(self.visible_top + self.height), .exit_code = null }
    else
        null;
}

pub const ShellState = union(enum) {
    at_prompt: struct { last_exit_code: ?i32 = null },
    at_prompt_with_input: struct { last_exit_code: ?i32 = null },
    running,
};

pub fn shellState(self: *const Screen) ShellState {
    if (self.prompt_marks.items.len == 0) return .running;
    const last = self.prompt_marks.items[self.prompt_marks.items.len - 1];
    return switch (last.kind) {
        .prompt_start => .{ .at_prompt = .{
            .last_exit_code = self.lastExitCode(),
        } },
        .input_start => .{ .at_prompt_with_input = .{
            .last_exit_code = self.lastExitCode(),
        } },
        .output_start => .running,
        .output_end => .{ .at_prompt = .{
            .last_exit_code = last.exit_code,
        } },
    };
}

fn lastExitCode(self: *const Screen) ?i32 {
    var i: usize = self.prompt_marks.items.len;
    while (i > 0) {
        i -= 1;
        const m = self.prompt_marks.items[i];
        switch (m.kind) {
            .output_end => return m.exit_code,
            .output_start => return null,
            else => {},
        }
    }
    return null;
}

fn commandTopRow(self: *const Screen, mark_row: u32) u32 {
    return if (self.rowIsBlank(mark_row)) mark_row + 1 else mark_row;
}

pub fn prevCommandRow(self: *const Screen, row: usize) ?u32 {
    var best: ?u32 = null;
    for (self.prompt_marks.items) |mark| {
        if (mark.kind != .prompt_start) continue;
        const top = self.commandTopRow(mark.row);
        if (top >= row) continue;
        if (best == null or top > best.?) best = top;
    }
    return best;
}

pub fn nextCommandRow(self: *const Screen, row: usize) ?u32 {
    var best: ?u32 = null;
    for (self.prompt_marks.items) |mark| {
        if (mark.kind != .prompt_start) continue;
        const top = self.commandTopRow(mark.row);
        if (top <= row) continue;
        if (best == null or top < best.?) best = top;
    }
    return best;
}

pub fn lastCommandRow(self: *const Screen) ?u32 {
    var best: ?u32 = null;
    for (self.prompt_marks.items) |mark| {
        if (mark.kind != .prompt_start) continue;
        const top = self.commandTopRow(mark.row);
        if (best == null or top > best.?) best = top;
    }
    return best;
}

pub fn rowIsBlank(self: *const Screen, row: usize) bool {
    if (self.width == 0) return true;
    const total_rows = self.buf.len / self.width;
    if (row >= total_rows) return true;
    const row_base = row * self.width;
    for (self.buf[row_base .. row_base + self.width]) |*cell| {
        for (cell.char.bytes()) |b| if (b != ' ') return false;
    }
    return true;
}

fn shiftMarksUp(self: *Screen, top: u32, bottom: u32, n: u32) void {
    if (n == 0 or top > bottom) return;
    var i: usize = 0;
    while (i < self.prompt_marks.items.len) {
        const r = self.prompt_marks.items[i].row;
        if (r >= top and r < top + n) {
            _ = self.prompt_marks.orderedRemove(i);
        } else if (r >= top + n and r <= bottom) {
            self.prompt_marks.items[i].row = r - n;
            i += 1;
        } else {
            i += 1;
        }
    }
}

/// Append the trimmed plain-text contents of `row` of `self.buf` to `out`,
/// where `row` is an absolute index in `self.buf` (0 is the oldest history
/// row, `visible_top + height` is one past the bottom of the viewport).
/// Trailing space cells are dropped. If `col_at_byte` is non-null, it is
/// populated so that `col_at_byte[i]` is the display column of byte `i` in
/// `out`, with the final entry equal to `self.width` (the column past the
/// last cell).
pub fn extractRowText(
    self: *const Screen,
    allocator: std.mem.Allocator,
    row: usize,
    out: *std.ArrayList(u8),
    col_at_byte: ?*std.ArrayList(u16),
) !void {
    if (self.width == 0) return;
    const total_rows = self.buf.len / self.width;
    if (row >= total_rows) return;
    const row_base = row * self.width;
    const start_len = out.items.len;
    var col: u16 = 0;
    while (col < self.width) : (col += 1) {
        const cell = &self.buf[row_base + col];
        const cell_bytes = cell.char.bytes();
        if (cell_bytes.len == 0) {
            try out.append(allocator, ' ');
            if (col_at_byte) |m| try m.append(allocator, col);
        } else {
            for (cell_bytes) |b| {
                try out.append(allocator, b);
                if (col_at_byte) |m| try m.append(allocator, col);
            }
        }
    }
    while (out.items.len > start_len and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
        if (col_at_byte) |m| m.items.len -= 1;
        col -= 1;
    }
    if (col_at_byte) |m| try m.append(allocator, col);
}

/// writes a cell to a location. 0 indexed
pub fn print(
    self: *Screen,
    grapheme: []const u8,
    width: u8,
    wrap: bool,
) !void {
    if (self.cursor.pending_wrap) {
        self.cursor.col = self.scrolling_region.left;
        try self.index();
    }
    if (self.cursor.col >= self.width) return;
    if (self.cursor.row >= self.height) return;
    const col = self.cursor.col;
    const row = self.cursor.row;

    const i = self.rowIndex(row, col);
    assert(i < self.buf.len);
    self.buf[i].char.set(self.allocator, grapheme);
    if (self.cursor.uri.items.len > 0 or self.buf[i].uri.items.len > 0) {
        self.buf[i].uri.clearRetainingCapacity();
        self.buf[i].uri.appendSlice(self.allocator, self.cursor.uri.items) catch {
            log.warn("couldn't write uri", .{});
        };
        self.buf[i].uri_id.clearRetainingCapacity();
        self.buf[i].uri_id.appendSlice(self.allocator, self.cursor.uri_id.items) catch {
            log.warn("couldn't write uri_id", .{});
        };
    }
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
        if (full_screen) {
            if (self.visible_top + self.height < total_rows) {
                // history is growing
                self.visible_top += 1;
            } else {
                // scrollback is full
                self.ring.advance();
                self.buf = self.ring.window();
                self.shiftMarksUp(0, @intCast(total_rows - 1), 1);
            }
            // recycled bottom row is stale
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

    const sr_top: u32 = @intCast(self.visible_top + self.scrolling_region.top);
    const sr_bottom: u32 = @intCast(self.visible_top + self.scrolling_region.bottom);
    self.shiftMarksUp(sr_top, sr_bottom, @intCast(cnt));
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

test "scrollback ring drops the oldest line once full and keeps recent history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.initScrollback(alloc, 4, 2, 2);
    defer screen.deinit(alloc);

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        screen.cursor.col = 0;
        try screen.print(&.{'0' + i}, 1, false);
        try screen.index();
    }

    try testing.expectEqualStrings("5", screen.buf[0].char.bytes());
    try testing.expectEqualStrings("6", screen.buf[4].char.bytes());
    try testing.expectEqualStrings("7", screen.buf[8].char.bytes());
    try testing.expectEqualStrings(" ", screen.buf[12].char.bytes());
    try testing.expectEqual(@as(usize, 2), screen.historySize());
}

test "print: a wrap on the bottom row scrolls instead of overwriting it" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.initScrollback(alloc, 5, 2, 10);
    defer screen.deinit(alloc);

    screen.cursor.row = 1;
    screen.cursor.col = 0;
    for ("ABCDEF") |ch| try screen.print(&.{ch}, 1, true);

    try testing.expectEqualStrings("A", screen.buf[screen.rowIndex(0, 0)].char.bytes());
    try testing.expectEqualStrings("E", screen.buf[screen.rowIndex(0, 4)].char.bytes());
    try testing.expectEqualStrings("F", screen.buf[screen.rowIndex(1, 0)].char.bytes());
}
