const std = @import("std");
const Style = @import("theme").Style;
const ThemeColor = @import("theme").Color;
const FontStyle = @import("theme").FontStyle;
const StyleBits = @import("style.zig").StyleBits;
const Cell = @import("Cell.zig");
const vaxis = @import("vaxis");
const Buffer = @import("Buffer");
const color = @import("color");
const RGB = @import("color").RGB;
const GraphemeCache = @import("GraphemeCache.zig");

const Plane = @This();

const name_buf_len = 128;

window: vaxis.Window,
row: i32 = 0,
col: i32 = 0,
name_buf: [name_buf_len]u8,
name_len: usize,
cache: GraphemeCache,
style: vaxis.Cell.Style = .{},
style_base: vaxis.Cell.Style = .{},
scrolling: bool = false,
transparent: bool = false,

pub const Options = struct {
    y: usize = 0,
    x: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
    name: []const u8,
    flags: option = .none,
};

pub const option = enum {
    none,
    VSCROLL,
};

pub fn init(nopts: *const Options, parent_: Plane) !Plane {
    const opts: vaxis.Window.ChildOptions = .{
        .x_off = @as(i17, @intCast(nopts.x)),
        .y_off = @as(i17, @intCast(nopts.y)),
        .width = @as(u16, @intCast(nopts.cols)),
        .height = @as(u16, @intCast(nopts.rows)),
        .border = .{},
    };
    const len = @min(nopts.name.len, name_buf_len);
    var plane: Plane = .{
        .window = parent_.window.child(opts),
        .cache = parent_.cache,
        .name_buf = undefined,
        .name_len = len,
        .scrolling = nopts.flags == .VSCROLL,
    };
    @memcpy(plane.name_buf[0..len], nopts.name[0..len]);
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
    self.window.fill(.{ .style = self.style_base });
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

pub fn abs_yx_to_rel_nearest_x(self: Plane, y: c_int, x: c_int, xoffset: c_int) struct { c_int, c_int } {
    if (self.window.screen.width == 0 or self.window.screen.height == 0) return self.abs_yx_to_rel(y, x);
    const xextra = self.window.screen.width_pix % self.window.screen.width;
    const xcell = (self.window.screen.width_pix - xextra) / self.window.screen.width;
    if (xcell == 0)
        return self.abs_yx_to_rel(y, x);
    if (xoffset > xcell / 2)
        return self.abs_yx_to_rel(y, x + 1);
    return self.abs_yx_to_rel(y, x);
}

pub fn abs_yx_to_rel(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
    return .{ y - self.abs_y(), x - self.abs_x() };
}

pub fn abs_y_to_rel(self: Plane, y: c_int) c_int {
    return y - self.abs_y();
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

pub fn fill(self: *Plane, egc: []const u8) void {
    for (0..self.dim_y()) |y|
        for (0..self.dim_x()) |x|
            self.write_cell(x, y, egc);
}

pub fn fill_width(self: *Plane, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    var pos: usize = 0;
    const width = self.window.width;
    var text_width: usize = 0;
    while (text_width < width) {
        const text = try std.fmt.bufPrint(buf[pos..], fmt, args);
        pos += text.len;
        text_width += self.egc_chunk_width(text, 0, 8);
    }
    return self.putstr(buf[0..pos]);
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
    const text_width = self.egc_chunk_width(text, 0, 8);
    self.row = @intCast(y);
    self.col = @intCast(if (text_width >= width) 0 else width - text_width);
    return self.putstr(text);
}

pub fn print_right(self: *Plane, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    const width = self.window.width;
    const text_width: usize = self.egc_chunk_width(text, 0, 1);
    const col: usize = @intCast(self.col);
    const space = width -| col;
    self.col += @intCast(space -| text_width);
    return self.putstr(text);
}

pub fn print_aligned_center(self: *Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const width = self.window.width;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    const text_width = self.egc_chunk_width(text, 0, 8);
    self.row = @intCast(y);
    self.col = @intCast(if (text_width >= width) 0 else (width - text_width) / 2);
    return self.putstr(text);
}

pub fn putstr(self: *Plane, text: []const u8) !usize {
    var result: usize = 0;
    const height = self.window.height;
    const width = self.window.width;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const s = grapheme.bytes(text);
        if (std.mem.eql(u8, s, "\n")) {
            if (self.scrolling and self.row == height - 1)
                self.window.scroll(1)
            else
                self.row += 1;
            self.col = 0;
            result += 1;
            continue;
        }
        if (self.col >= width) {
            if (self.scrolling) {
                self.row += 1;
                self.col = 0;
            } else return result;
        }
        self.write_cell(@intCast(self.col), @intCast(self.row), s);
        result += 1;
    }
    return result;
}

pub fn putstr_unicode(self: *Plane, text: []const u8) !usize {
    var result: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const s_ = grapheme.bytes(text);
        const s = switch (s_[0]) {
            0...31 => |code| Buffer.unicode.control_code_to_unicode(code),
            else => s_,
        };
        self.write_cell(@intCast(self.col), @intCast(self.row), s);
        result += 1;
    }
    return result;
}

pub fn putchar(self: *Plane, ecg: []const u8) void {
    self.write_cell(@intCast(self.col), @intCast(self.row), ecg);
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
    return w;
}

fn write_cell(self: *Plane, col: usize, row: usize, egc: []const u8) void {
    var cell: vaxis.Cell = self.window.readCell(@intCast(col), @intCast(row)) orelse .{ .style = self.style };
    const w = self.window.gwidth(egc);
    cell.char.grapheme = self.cache.put(egc);
    cell.char.width = @intCast(w);
    if (self.transparent) {
        cell.style.fg = self.style.fg;
    } else {
        cell.style = self.style;
    }
    self.window.writeCell(@intCast(col), @intCast(row), cell);
    self.col += @intCast(w);
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

pub fn cell_load(self: *Plane, cell: *Cell, gcluster: []const u8) !usize {
    var cols: c_int = 0;
    const bytes = self.egc_length(gcluster, &cols, 0, 1);
    cell.cell.char.grapheme = self.cache.put(gcluster[0..bytes]);
    cell.cell.char.width = @intCast(cols);
    return bytes;
}

pub fn at_cursor_cell(self: Plane, cell: *Cell) !usize {
    cell.* = .{};
    if (self.window.readCell(@intCast(self.col), @intCast(self.row))) |cell_| cell.cell = cell_;
    return if (std.mem.eql(u8, cell.cell.char.grapheme, " ")) 0 else cell.cell.char.grapheme.len;
}

pub fn set_styles(self: *Plane, stylebits: StyleBits) void {
    self.style.strikethrough = false;
    self.style.bold = false;
    self.style.ul_style = .off;
    self.style.italic = false;
    self.on_styles(stylebits);
}

pub fn on_styles(self: *Plane, stylebits: StyleBits) void {
    if (stylebits.struck) self.style.strikethrough = true;
    if (stylebits.bold) self.style.bold = true;
    if (stylebits.undercurl) self.style.ul_style = .curly;
    if (stylebits.underline) self.style.ul_style = .single;
    if (stylebits.italic) self.style.italic = true;
}

pub fn off_styles(self: *Plane, stylebits: StyleBits) void {
    if (stylebits.struck) self.style.strikethrough = false;
    if (stylebits.bold) self.style.bold = false;
    if (stylebits.undercurl) self.style.ul_style = .off;
    if (stylebits.underline) self.style.ul_style = .off;
    if (stylebits.italic) self.style.italic = false;
}

pub fn set_fg_rgb(self: *Plane, col: ThemeColor) !void {
    self.style.fg = to_cell_color(col);
}

pub fn set_fg_rgb_alpha(self: *Plane, alpha_fg: ThemeColor, col: ThemeColor) !void {
    self.style.fg = apply_alpha_theme(alpha_fg, col);
}

pub fn set_bg_rgb(self: *Plane, col: ThemeColor) !void {
    self.style.bg = to_cell_color(col);
}

pub fn set_bg_rgb_alpha(self: *Plane, alpha_bg: ThemeColor, col: ThemeColor) !void {
    self.style.bg = apply_alpha_theme(alpha_bg, col);
}

pub fn set_fg_palindex(self: *Plane, idx: c_uint) !void {
    self.style.fg = .{ .index = @intCast(idx) };
}

pub fn set_bg_palindex(self: *Plane, idx: c_uint) !void {
    self.style.bg = .{ .index = @intCast(idx) };
}

pub inline fn set_base_style(self: *Plane, style_: Style) void {
    self.style_base.fg = if (style_.fg) |col| to_cell_color(col) else .default;
    self.style_base.bg = if (style_.bg) |col| to_cell_color(col) else .default;
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.set_style(style_);
}

pub fn set_base_style_transparent(self: *Plane, _: [*:0]const u8, style_: Style) void {
    self.style_base.fg = if (style_.fg) |col| to_cell_color(col) else .default;
    self.style_base.bg = if (style_.bg) |col| to_cell_color(col) else .default;
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.set_style(style_);
    self.transparent = true;
}

pub fn set_base_style_bg_transparent(self: *Plane, _: [*:0]const u8, style_: Style) void {
    self.style_base.fg = if (style_.fg) |col| to_cell_color(col) else .default;
    self.style_base.bg = if (style_.bg) |col| to_cell_color(col) else .default;
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.set_style(style_);
    self.transparent = true;
}

fn apply_alpha(base: vaxis.Cell.Color, col: ThemeColor) vaxis.Cell.Color {
    const alpha = col.alpha;
    return if (alpha == 0xFF or base != .rgb)
        .{ .rgb = RGB.to_u8s(RGB.from_u24(col.color)) }
    else
        .{ .rgb = color.apply_alpha(RGB.from_u8s(base.rgb), RGB.from_u24(col.color), alpha).to_u8s() };
}

fn apply_alpha_theme(base: ThemeColor, col: ThemeColor) vaxis.Cell.Color {
    const alpha = col.alpha;
    return if (alpha == 0xFF)
        .{ .rgb = RGB.to_u8s(RGB.from_u24(col.color)) }
    else
        .{ .rgb = color.apply_alpha(RGB.from_u24(base.color), RGB.from_u24(col.color), alpha).to_u8s() };
}

pub inline fn reverse_style(self: *Plane) void {
    const swap = self.style.fg;
    self.style.fg = self.style.bg;
    self.style.bg = swap;
}

pub inline fn set_style(self: *Plane, style_: Style) void {
    if (style_.fg) |col| self.style.fg = apply_alpha(self.style_base.bg, col);
    if (style_.bg) |col| self.style.bg = apply_alpha(self.style_base.bg, col);
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.transparent = false;
}

pub inline fn set_style_bg_transparent(self: *Plane, style_: Style) void {
    if (style_.fg) |col| self.style.fg = apply_alpha(self.style_base.fg, col);
    if (style_.bg) |col| self.style.bg = apply_alpha(self.style_base.bg, col);
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.transparent = true;
}

inline fn set_font_style(style: *vaxis.Cell.Style, fs: FontStyle) void {
    switch (fs) {
        .normal => {
            style.bold = false;
            style.italic = false;
            style.dim = false;
        },
        .bold => style.bold = true,
        .italic => style.italic = true,
        .underline => style.ul_style = .single,
        .undercurl => style.ul_style = .curly,
        .strikethrough => style.strikethrough = true,
    }
}

inline fn is_control_code(c: u8) bool {
    return switch (c) {
        0...8, 10...31 => true,
        else => false,
    };
}

pub fn egc_length(self: *const Plane, egcs: []const u8, colcount: *c_int, abs_col: usize, tab_width: usize) usize {
    if (egcs.len == 0) {
        colcount.* = 0;
        return 0;
    }
    if (is_control_code(egcs[0])) {
        colcount.* = 1;
        return 1;
    }
    if (egcs[0] == '\t') {
        colcount.* = @intCast(tab_width - (abs_col % tab_width));
        return 1;
    }
    var iter = vaxis.unicode.graphemeIterator(egcs);
    const grapheme = iter.next() orelse {
        colcount.* = 1;
        return 1;
    };
    const s = grapheme.bytes(egcs);
    const w = self.window.gwidth(s);
    colcount.* = @intCast(w);
    return s.len;
}

pub fn egc_chunk_width(self: *const Plane, chunk_: []const u8, abs_col_: usize, tab_width: usize) usize {
    var abs_col = abs_col_;
    var chunk = chunk_;
    var colcount: usize = 0;
    var cols: c_int = 0;
    while (chunk.len > 0) {
        const bytes = self.egc_length(chunk, &cols, abs_col, tab_width);
        colcount += @intCast(cols);
        abs_col += @intCast(cols);
        if (chunk.len < bytes) break;
        chunk = chunk[bytes..];
    }
    return colcount;
}

pub fn egc_chunk_col_pos(self: *const Plane, chunk_: []const u8, abs_col_: usize, tab_width: usize, col: usize) usize {
    var abs_col = abs_col_;
    var chunk = chunk_;
    var colcount: usize = 0;
    var cols: c_int = 0;
    while (chunk.len > 0 and colcount < col) {
        const bytes = self.egc_length(chunk, &cols, abs_col, tab_width);
        colcount += @intCast(cols);
        abs_col += @intCast(cols);
        if (chunk.len < bytes) break;
        chunk = chunk[bytes..];
    }
    return chunk_.len - chunk.len;
}

pub fn egc_last(egcs: []const u8) []const u8 {
    var iter = vaxis.unicode.graphemeIterator(egcs);
    var last: []const u8 = egcs[0..0];
    while (iter.next()) |grapheme| last = grapheme.bytes(egcs);
    return last;
}

pub fn metrics(self: *const Plane, tab_width: usize) Buffer.Metrics {
    return .{
        .ctx = self,
        .egc_length = struct {
            fn f(self_: Buffer.Metrics, egcs: []const u8, colcount: *c_int, abs_col: usize) usize {
                const plane: *const Plane = @ptrCast(@alignCast(self_.ctx));
                return plane.egc_length(egcs, colcount, abs_col, self_.tab_width);
            }
        }.f,
        .egc_chunk_width = struct {
            fn f(self_: Buffer.Metrics, chunk_: []const u8, abs_col_: usize) usize {
                const plane: *const Plane = @ptrCast(@alignCast(self_.ctx));
                return plane.egc_chunk_width(chunk_, abs_col_, self_.tab_width);
            }
        }.f,
        .tab_width = tab_width,
        .egc_last = struct {
            fn f(_: Buffer.Metrics, egcs: []const u8) []const u8 {
                return egc_last(egcs);
            }
        }.f,
    };
}

fn to_cell_color(col: ThemeColor) vaxis.Cell.Color {
    return .{ .rgb = RGB.to_u8s(RGB.from_u24(col.color)) };
}
