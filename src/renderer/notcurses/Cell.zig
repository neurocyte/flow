const nc = @import("notcurses");
const Style = @import("theme").Style;
const channels = @import("channels.zig");

pub const Cell = struct {
    cell: nc.Cell,

    pub inline fn set_style(cell: *Cell, style_: Style) void {
        channels.from_style(&cell.cell.channels, style_);
        if (style_.fs) |fs| switch (fs) {
            .normal => nc.cell_set_styles(&cell.cell, nc.style.none),
            .bold => nc.cell_set_styles(&cell.cell, nc.style.bold),
            .italic => nc.cell_set_styles(&cell.cell, nc.style.italic),
            .underline => nc.cell_set_styles(&cell.cell, nc.style.underline),
            .undercurl => nc.cell_set_styles(&cell.cell, nc.style.undercurl),
            .strikethrough => nc.cell_set_styles(&cell.cell, nc.style.struck),
        };
    }

    pub inline fn set_style_fg(cell: *Cell, style_: Style) void {
        channels.fg_from_style(&cell.cell.channels, style_);
    }

    pub inline fn set_style_bg(cell: *Cell, style_: Style) void {
        channels.bg_from_style(&cell.cell.channels, style_);
    }

    pub inline fn set_fg_rgb(cell: *Cell, arg_rgb: c_uint) !void {
        return channels.set_fg_rgb(&cell.cell.channels, arg_rgb);
    }
    pub inline fn set_bg_rgb(cell: *Cell, arg_rgb: c_uint) !void {
        return channels.set_bg_rgb(&cell.cell.channels, arg_rgb);
    }

    pub fn columns(cell: *const Cell) usize {
        return nc.cell_cols(&cell.cell);
    }
};
