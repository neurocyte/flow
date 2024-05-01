const std = @import("std");
const Style = @import("theme").Style;
const StyleBits = @import("style.zig").StyleBits;
const Cell = @import("Cell.zig");
const vaxis = @import("vaxis");

const Plane = @This();

window: vaxis.Window,
row: i32 = 0,
col: i32 = 0,
name_buf: [128]u8,
name_len: usize,
cache: GraphemeCache = .{},
style: vaxis.Cell.Style = .{},

pub const Options = struct {
    y: usize = 0,
    x: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
    name: [*:0]const u8,
    flags: option = .none,
};

pub const option = enum {
    none,
    VSCROLL,
};

pub fn init(nopts: *const Options, parent_: Plane) !Plane {
    const opts = .{
        .x_off = nopts.x,
        .y_off = nopts.y,
        .width = .{ .limit = nopts.cols },
        .height = .{ .limit = nopts.rows },
        .border = .{},
    };
    var plane: Plane = .{
        .window = parent_.window.child(opts),
        .name_buf = undefined,
        .name_len = std.mem.span(nopts.name).len,
    };
    @memcpy(plane.name_buf[0..plane.name_len], nopts.name);
    return plane;
}

pub fn deinit(_: *Plane) void {}

pub fn name(self: Plane, buf: []u8) []const u8 {
    @memcpy(buf[0..self.name_len], self.name_buf[0..self.name_len]);
    return buf[0..self.name_len];
}

pub fn above(_: Plane) ?Plane {
    return null;
}

pub fn below(_: Plane) ?Plane {
    return null;
}

pub fn erase(self: Plane) void {
    self.window.clear();
}

pub inline fn abs_y(self: Plane) c_int {
    return @intCast(self.window.y_off);
}

pub inline fn abs_x(self: Plane) c_int {
    return @intCast(self.window.x_off);
}

pub inline fn dim_y(self: Plane) c_uint {
    return @intCast(self.window.height);
}

pub inline fn dim_x(self: Plane) c_uint {
    return @intCast(self.window.width);
}

pub fn abs_yx_to_rel(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
    return .{ y - self.abs_y(), x - self.abs_x() };
}

pub fn rel_yx_to_abs(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
    return .{ self.abs_y() + y, self.abs_x() + x };
}

pub fn hide(_: Plane) void {}

pub fn move_yx(self: *Plane, y: c_int, x: c_int) !void {
    self.window.y_off = @intCast(y);
    self.window.x_off = @intCast(x);
}

pub fn resize_simple(self: *Plane, ylen: c_uint, xlen: c_uint) !void {
    self.window.height = @intCast(ylen);
    self.window.width = @intCast(xlen);
}

pub fn home(self: *Plane) void {
    self.row = 0;
    self.col = 0;
}

pub fn print(self: *Plane, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    return self.putstr(text);
}

pub fn print_aligned_right(self: *Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const width = self.window.width;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    const text_width = self.egc_chunk_width(text, 0);
    self.row = @intCast(y);
    self.col = @intCast(if (text_width >= width) 0 else width - text_width);
    return self.putstr(text);
}

pub fn print_aligned_center(self: *Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const width = self.window.width;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    const text_width = self.egc_chunk_width(text, 0);
    self.row = @intCast(y);
    self.col = @intCast(if (text_width >= width) 0 else (width - text_width) / 2);
    return self.putstr(text);
}

pub fn putstr(self: *Plane, text: []const u8) !usize {
    var result: usize = 0;
    const width = self.window.width;
    var iter = self.window.screen.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (self.col >= width) {
            self.row += 1;
            self.col = 0;
        }
        const s = grapheme.bytes(text);
        if (std.mem.eql(u8, s, "\n")) {
            self.row += 1;
            self.col = 0;
            result += 1;
            continue;
        }
        const w = self.window.gwidth(s);
        if (w == 0) continue;
        self.window.writeCell(@intCast(self.col), @intCast(self.row), .{
            .char = .{
                .grapheme = self.cache.put(s),
                .width = w,
            },
            .style = self.style,
        });
        self.col += @intCast(w);
        result += 1;
    }
    return result;
}

pub fn putc(self: *Plane, cell: *const Cell) !usize {
    return self.putc_yx(@intCast(self.row), @intCast(self.col), cell);
}

pub fn putc_yx(self: *Plane, y: c_int, x: c_int, cell: *const Cell) !usize {
    try self.cursor_move_yx(y, x);
    const w = if (cell.cell.char.width == 0) self.window.gwidth(cell.cell.char.grapheme) else cell.cell.char.width;
    if (w == 0) return w;
    self.window.writeCell(@intCast(self.col), @intCast(self.row), cell.cell);
    self.col += @intCast(w);
    if (self.col >= self.window.width) {
        self.row += 1;
        self.col = 0;
    }
    return w;
}

pub fn cursor_yx(self: Plane, y: *c_uint, x: *c_uint) void {
    y.* = @intCast(self.row);
    x.* = @intCast(self.col);
}

pub fn cursor_y(self: Plane) c_uint {
    return @intCast(self.row);
}

pub fn cursor_x(self: Plane) c_uint {
    return @intCast(self.col);
}

pub fn cursor_move_yx(self: *Plane, y: c_int, x: c_int) !void {
    if (self.window.height == 0 or self.window.width == 0) return;
    if (self.window.height <= y or self.window.width <= x) return;
    if (y >= 0)
        self.row = @intCast(y);
    if (x >= 0)
        self.col = @intCast(x);
}

pub fn cursor_move_rel(self: *Plane, y: c_int, x: c_int) !void {
    if (self.window.height == 0 or self.window.width == 0) return error.OutOfBounds;
    const new_y: isize = @as(c_int, @intCast(self.row)) + y;
    const new_x: isize = @as(c_int, @intCast(self.col)) + x;
    if (new_y < 0 or new_x < 0) return error.OutOfBounds;
    if (self.window.height <= new_y or self.window.width <= new_x) return error.OutOfBounds;
    self.row = @intCast(new_y);
    self.col = @intCast(new_x);
}

pub fn cell_init(self: Plane) Cell {
    return .{ .cell = .{ .style = self.style } };
}

pub fn cell_load(self: *Plane, cell: *Cell, gcluster: [:0]const u8) !usize {
    cell.* = .{ .cell = .{ .style = self.style } };
    var cols: c_int = 0;
    const bytes = self.egc_length(gcluster, &cols, 0);
    cell.cell.char.grapheme = self.cache.put(gcluster[0..bytes]);
    cell.cell.char.width = @intCast(cols);
    return bytes;
}

pub fn at_cursor_cell(self: Plane, cell: *Cell) !usize {
    cell.* = .{};
    if (self.window.readCell(@intCast(self.col), @intCast(self.row))) |cell_| cell.cell = cell_;
    return cell.cell.char.grapheme.len;
}

pub fn set_styles(self: Plane, stylebits: StyleBits) void {
    _ = self;
    _ = stylebits;
    // FIXME
}

pub fn on_styles(self: Plane, stylebits: StyleBits) void {
    _ = self;
    _ = stylebits;
    // FIXME
}

pub fn off_styles(self: Plane, stylebits: StyleBits) void {
    _ = self;
    _ = stylebits;
    // FIXME
}

pub fn set_fg_rgb(self: *Plane, channel: u32) !void {
    self.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(channel));
}

pub fn set_bg_rgb(self: *Plane, channel: u32) !void {
    self.style.bg = vaxis.Cell.Color.rgbFromUint(@intCast(channel));
}

pub fn set_fg_palindex(self: *Plane, idx: c_uint) !void {
    self.style.fg = .{ .index = @intCast(idx) };
}

pub fn set_bg_palindex(self: *Plane, idx: c_uint) !void {
    self.style.bg = .{ .index = @intCast(idx) };
}

pub fn set_channels(self: Plane, channels_: u64) void {
    _ = self;
    _ = channels_;
    // FIXME
}

pub inline fn set_base_style(self: *const Plane, egc_: [*c]const u8, style_: Style) void {
    _ = self;
    _ = egc_;
    _ = style_;
    // FIXME
}

pub fn set_base_style_transparent(self: Plane, egc_: [*:0]const u8, style_: Style) void {
    _ = self;
    _ = egc_;
    _ = style_;
    // FIXME
}

pub fn set_base_style_bg_transparent(self: Plane, egc_: [*:0]const u8, style_: Style) void {
    _ = self;
    _ = egc_;
    _ = style_;
    // FIXME
}

pub inline fn set_style(self: *Plane, style_: Style) void {
    if (style_.fg) |color| self.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    if (style_.bg) |color| self.style.bg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    // if (style_.fs) |fontstyle| ... FIXME
}

pub inline fn set_style_bg_transparent(self: *Plane, style_: Style) void {
    if (style_.fg) |color| self.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    self.style.bg = .default;
}

pub fn egc_length(self: *const Plane, egcs: []const u8, colcount: *c_int, abs_col: usize) usize {
    if (egcs[0] == '\t') {
        colcount.* = @intCast(8 - abs_col % 8);
        return 1;
    }
    var iter = self.window.screen.unicode.graphemeIterator(egcs);
    const grapheme = iter.next() orelse {
        colcount.* = 1;
        return 1;
    };
    const s = grapheme.bytes(egcs);
    const w = self.window.gwidth(s);
    colcount.* = @intCast(w);
    return s.len;
}

pub fn egc_chunk_width(self: *const Plane, chunk_: []const u8, abs_col_: usize) usize {
    var abs_col = abs_col_;
    var chunk = chunk_;
    var colcount: usize = 0;
    var cols: c_int = 0;
    while (chunk.len > 0) {
        const bytes = self.egc_length(chunk, &cols, abs_col);
        colcount += @intCast(cols);
        abs_col += @intCast(cols);
        if (chunk.len < bytes) break;
        chunk = chunk[bytes..];
    }
    return colcount;
}

const GraphemeCache = struct {
    buf: [1024 * 16]u8 = undefined,
    idx: usize = 0,

    pub fn put(self: *GraphemeCache, bytes: []const u8) []u8 {
        if (self.idx + bytes.len > self.buf.len) self.idx = 0;
        defer self.idx += bytes.len;
        @memcpy(self.buf[self.idx .. self.idx + bytes.len], bytes);
        return self.buf[self.idx .. self.idx + bytes.len];
    }
};
