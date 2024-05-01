const nc = @import("notcurses");
const Style = @import("theme").Style;
const channels = @import("channels.zig");
const StyleBits = @import("style.zig").StyleBits;
const Cell = @import("Cell.zig").Cell;

pub const Plane = struct {
    plane: nc.Plane,

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
        var nopts_: nc.Plane.Options = .{
            .y = @intCast(nopts.y),
            .x = @intCast(nopts.x),
            .rows = @intCast(nopts.rows),
            .cols = @intCast(nopts.cols),
            .name = nopts.name,
        };
        switch (nopts.flags) {
            .none => {},
            .VSCROLL => nopts_.flags = nc.Plane.option.VSCROLL,
        }

        return .{ .plane = nc.Plane.init(&nopts_, parent_.plane) catch |e| return e };
    }

    pub fn deinit(self: *Plane) void {
        self.plane.deinit();
    }

    pub fn name(self: Plane, buf: []u8) []u8 {
        return self.plane.name(buf);
    }

    pub fn parent(self: Plane) Plane {
        return .{ .plane = self.plane.parent() };
    }

    pub fn above(self: Plane) ?Plane {
        return .{ .plane = self.plane.above() orelse return null };
    }

    pub fn below(self: Plane) ?Plane {
        return .{ .plane = self.plane.below() orelse return null };
    }

    pub fn erase(self: Plane) void {
        return self.plane.erase();
    }

    pub fn abs_y(self: Plane) c_int {
        return self.plane.abs_y();
    }

    pub fn abs_x(self: Plane) c_int {
        return self.plane.abs_x();
    }

    pub fn dim_y(self: Plane) c_uint {
        return self.plane.dim_y();
    }

    pub fn dim_x(self: Plane) c_uint {
        return self.plane.dim_x();
    }

    pub fn abs_yx_to_rel(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
        var y_, var x_ = .{ y, x };
        self.plane.abs_yx_to_rel(&y_, &x_);
        return .{ y_, x_ };
    }

    pub fn rel_yx_to_abs(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
        var y_, var x_ = .{ y, x };
        self.plane.rel_yx_to_abs(&y_, &x_);
        return .{ y_, x_ };
    }

    pub fn hide(self: Plane) void {
        self.plane.move_bottom();
    }

    pub fn move_yx(self: Plane, y: c_int, x: c_int) !void {
        return self.plane.move_yx(y, x);
    }

    pub fn resize_simple(self: Plane, ylen: c_uint, xlen: c_uint) !void {
        return self.plane.resize_simple(ylen, xlen);
    }

    pub fn home(self: Plane) void {
        return self.plane.home();
    }

    pub fn print(self: Plane, comptime fmt: anytype, args: anytype) !usize {
        return self.plane.print(fmt, args);
    }

    pub fn print_aligned_right(self: Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
        return self.plane.print_aligned(y, .right, fmt, args);
    }

    pub fn print_aligned_center(self: Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
        return self.plane.print_aligned(y, .center, fmt, args);
    }

    pub fn putstr(self: Plane, gclustarr: [*:0]const u8) !usize {
        return self.plane.putstr(gclustarr);
    }

    pub fn putc(self: Plane, cell: *const Cell) !usize {
        return self.plane.putc(&cell.cell);
    }

    pub fn putc_yx(self: Plane, y: c_int, x: c_int, cell: *const Cell) !usize {
        return self.plane.put_yx(y, x, &cell.cell);
    }

    pub fn cursor_yx(self: Plane, y: *c_uint, x: *c_uint) void {
        self.plane.cursor_yx(y, x);
    }

    pub fn cursor_y(self: Plane) c_uint {
        return self.plane.cursor_y();
    }

    pub fn cursor_x(self: Plane) c_uint {
        return self.plane.cursor_x();
    }

    pub fn cursor_move_yx(self: Plane, y: c_int, x: c_int) !void {
        return self.plane.cursor_move_yx(y, x);
    }

    pub fn cursor_move_rel(self: Plane, y: c_int, x: c_int) !void {
        return self.plane.cursor_move_rel(y, x);
    }

    pub fn cell_init(self: Plane) Cell {
        return .{ .cell = self.plane.cell_init() };
    }

    pub fn cell_load(self: Plane, cell: *Cell, gcluster: [:0]const u8) !usize {
        return self.plane.cell_load(&cell.cell, gcluster);
    }

    pub fn at_cursor_cell(self: Plane, cell: *Cell) !usize {
        return self.plane.at_cursor_cell(&cell.cell);
    }

    pub fn set_styles(self: Plane, stylebits: StyleBits) void {
        return self.plane.set_styles(@intCast(@as(u5, @bitCast(stylebits))));
    }

    pub fn on_styles(self: Plane, stylebits: StyleBits) void {
        return self.plane.on_styles(@intCast(@as(u5, @bitCast(stylebits))));
    }

    pub fn off_styles(self: Plane, stylebits: StyleBits) void {
        return self.plane.off_styles(@intCast(@as(u5, @bitCast(stylebits))));
    }

    pub fn set_fg_rgb(self: Plane, channel: u32) !void {
        return self.plane.set_fg_rgb(channel);
    }

    pub fn set_bg_rgb(self: Plane, channel: u32) !void {
        return self.plane.set_bg_rgb(channel);
    }

    pub fn set_fg_palindex(self: Plane, idx: c_uint) !void {
        return self.plane.set_fg_palindex(idx);
    }

    pub fn set_bg_palindex(self: Plane, idx: c_uint) !void {
        return self.plane.set_bg_palindex(idx);
    }

    pub fn set_channels(self: Plane, channels_: u64) void {
        return self.plane.set_channels(channels_);
    }

    pub inline fn set_base_style(plane: *const Plane, egc_: [*c]const u8, style_: Style) void {
        var channels_: u64 = 0;
        channels.from_style(&channels_, style_);
        if (style_.fg) |fg| plane.plane.set_fg_rgb(fg) catch {};
        if (style_.bg) |bg| plane.plane.set_bg_rgb(bg) catch {};
        _ = plane.plane.set_base(egc_, 0, channels_) catch {};
    }

    pub fn set_base_style_transparent(plane: Plane, egc_: [*:0]const u8, style_: Style) void {
        var channels_: u64 = 0;
        channels.from_style(&channels_, style_);
        if (style_.fg) |fg| plane.plane.set_fg_rgb(fg) catch {};
        if (style_.bg) |bg| plane.plane.set_bg_rgb(bg) catch {};
        channels.set_fg_transparent(&channels_);
        channels.set_bg_transparent(&channels_);
        _ = plane.plane.set_base(egc_, 0, channels_) catch {};
    }

    pub fn set_base_style_bg_transparent(plane: Plane, egc_: [*:0]const u8, style_: Style) void {
        var channels_: u64 = 0;
        channels.from_style(&channels_, style_);
        if (style_.fg) |fg| plane.plane.set_fg_rgb(fg) catch {};
        if (style_.bg) |bg| plane.plane.set_bg_rgb(bg) catch {};
        channels.set_bg_transparent(&channels_);
        _ = plane.plane.set_base(egc_, 0, channels_) catch {};
    }

    pub inline fn set_style(plane: *const Plane, style_: Style) void {
        var channels_: u64 = 0;
        channels.from_style(&channels_, style_);
        plane.plane.set_channels(channels_);
        if (style_.fs) |fs| switch (fs) {
            .normal => plane.plane.set_styles(nc.style.none),
            .bold => plane.plane.set_styles(nc.style.bold),
            .italic => plane.plane.set_styles(nc.style.italic),
            .underline => plane.plane.set_styles(nc.style.underline),
            .undercurl => plane.plane.set_styles(nc.style.undercurl),
            .strikethrough => plane.plane.set_styles(nc.style.struck),
        };
    }

    pub inline fn set_style_bg_transparent(plane: *const Plane, style_: Style) void {
        var channels_: u64 = 0;
        channels.from_style(&channels_, style_);
        channels.set_bg_transparent(&channels_);
        plane.plane.set_channels(channels_);
        if (style_.fs) |fs| switch (fs) {
            .normal => plane.plane.set_styles(nc.style.none),
            .bold => plane.plane.set_styles(nc.style.bold),
            .italic => plane.plane.set_styles(nc.style.italic),
            .underline => plane.plane.set_styles(nc.style.underline),
            .undercurl => plane.plane.set_styles(nc.style.undercurl),
            .strikethrough => plane.plane.set_styles(nc.style.struck),
        };
    }

    pub fn egc_length(_: Plane, egcs: []const u8, colcount: *c_int, abs_col: usize) usize {
        if (egcs[0] == '\t') {
            colcount.* = @intCast(8 - abs_col % 8);
            return 1;
        }
        return nc.ncegc_len(egcs, colcount) catch ret: {
            colcount.* = 1;
            break :ret 1;
        };
    }

    pub fn egc_chunk_width(plane: Plane, chunk_: []const u8, abs_col_: usize) usize {
        var abs_col = abs_col_;
        var chunk = chunk_;
        var colcount: usize = 0;
        var cols: c_int = 0;
        while (chunk.len > 0) {
            const bytes = plane.egc_length(chunk, &cols, abs_col);
            colcount += @intCast(cols);
            abs_col += @intCast(cols);
            if (chunk.len < bytes) break;
            chunk = chunk[bytes..];
        }
        return colcount;
    }
};
