const vaxis = @import("vaxis");
const Style = @import("theme").Style;

const Cell = @This();

cell: vaxis.Cell = .{},

pub inline fn set_style(self: *Cell, style_: Style) void {
    if (style_.fg) |fg| self.cell.style.fg = vaxis.Cell.Color.rgbFromUint(fg);
    if (style_.bg) |bg| self.cell.style.bg = vaxis.Cell.Color.rgbFromUint(bg);
    if (style_.fs) |fs| {
        self.cell.style.ul = .default;
        self.cell.style.ul_style = .off;
        self.cell.style.bold = false;
        self.cell.style.dim = false;
        self.cell.style.italic = false;
        self.cell.style.blink = false;
        self.cell.style.reverse = false;
        self.cell.style.invisible = false;
        self.cell.style.strikethrough = false;

        switch (fs) {
            .normal => {},
            .bold => self.cell.style.bold = true,
            .italic => self.cell.style.italic = true,
            .underline => self.cell.style.ul_style = .single,
            .undercurl => self.cell.style.ul_style = .curly,
            .strikethrough => self.cell.style.strikethrough = true,
        }
    }
}

pub inline fn set_under_color(self: *Cell, arg_rgb: c_uint) void {
    self.cell.style.ul = vaxis.Cell.Color.rgbFromUint(@intCast(arg_rgb));
}

pub inline fn set_style_fg(self: *Cell, style_: Style) void {
    if (style_.fg) |fg| self.cell.style.fg = vaxis.Cell.Color.rgbFromUint(fg);
}

pub inline fn set_style_bg(self: *Cell, style_: Style) void {
    if (style_.bg) |bg| self.cell.style.bg = vaxis.Cell.Color.rgbFromUint(bg);
}

pub inline fn set_fg_rgb(self: *Cell, arg_rgb: c_uint) !void {
    self.cell.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(arg_rgb));
}
pub inline fn set_bg_rgb(self: *Cell, arg_rgb: c_uint) !void {
    self.cell.style.bg = vaxis.Cell.Color.rgbFromUint(@intCast(arg_rgb));
}

pub fn columns(self: *const Cell) usize {
    // return if (self.cell.char.width == 0) self.window.gwidth(self.cell.char.grapheme) else self.cell.char.width; // FIXME?
    return self.cell.char.width;
}
