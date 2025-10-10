const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const Buffer = @import("Buffer");
const config = @import("config");

const Plane = @import("renderer").Plane;
const command = @import("command");
const EventHandler = @import("EventHandler");

const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const fonts = @import("../fonts.zig");

const DigitStyle = fonts.DigitStyle;

const utf8_sanitized_warning = "  UTF";

line: usize = 0,
lines: usize = 0,
column: usize = 0,
buf: [256]u8 = undefined,
rendered: [:0]const u8 = "",
eol_mode: Buffer.EolMode = .lf,
utf8_sanitized: bool = false,
indent_mode: config.IndentMode = .spaces,
padding: ?usize,
leader: ?Leader,
style: ?DigitStyle,

const Leader = enum {
    space,
    zero,
};
const Self = @This();
const ButtonType = Button.Options(Self).ButtonType;

pub fn create(allocator: Allocator, parent: Plane, event_handler: ?EventHandler, arg: ?[]const u8) @import("widget.zig").CreateError!Widget {
    const padding: ?usize, const leader: ?Leader, const style: ?DigitStyle = if (arg) |fmt| blk: {
        var it = std.mem.splitScalar(u8, fmt, ',');
        break :blk .{
            if (it.next()) |size| std.fmt.parseInt(usize, size, 10) catch null else null,
            if (it.next()) |leader| std.meta.stringToEnum(Leader, leader) orelse null else null,
            if (it.next()) |style| std.meta.stringToEnum(DigitStyle, style) orelse null else null,
        };
    } else .{ null, null, null };

    return Button.create_widget(Self, allocator, parent, .{
        .ctx = .{
            .padding = padding,
            .leader = leader,
            .style = style,
        },
        .label = "",
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
        .on_receive = receive,
        .on_event = event_handler,
    });
}

fn on_click(_: *Self, _: *ButtonType, _: Widget.Pos) void {
    command.executeName("goto", .{}) catch {};
}

pub fn layout(self: *Self, btn: *ButtonType) Widget.Layout {
    const warn_len = if (self.utf8_sanitized) btn.plane.egc_chunk_width(utf8_sanitized_warning, 0, 1) else 0;
    const len = btn.plane.egc_chunk_width(self.rendered, 0, 1) + warn_len;
    return .{ .static = len };
}

pub fn render(self: *Self, btn: *ButtonType, theme: *const Widget.Theme) bool {
    btn.plane.set_base_style(theme.editor);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
    btn.plane.fill(" ");
    btn.plane.home();
    if (self.utf8_sanitized) {
        btn.plane.set_style(.{ .fg = theme.editor_error.fg.? });
        _ = btn.plane.putstr(utf8_sanitized_warning) catch {};
    }
    btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
    _ = btn.plane.putstr(self.rendered) catch {};
    return false;
}

fn format(self: *Self) void {
    var fbs = std.io.fixedBufferStream(&self.buf);
    const writer = fbs.writer();
    const eol_mode = switch (self.eol_mode) {
        .lf => "",
        .crlf => " ␍␊",
    };
    const indent_mode = switch (self.indent_mode) {
        .spaces, .auto => "",
        .tabs => " ⭾ ",
    };
    std.fmt.format(writer, "{s}{s} Ln ", .{ eol_mode, indent_mode }) catch {};
    self.format_count(writer, self.line + 1, self.padding orelse 0) catch {};
    std.fmt.format(writer, ", Col ", .{}) catch {};
    self.format_count(writer, self.column + 1, self.padding orelse 0) catch {};
    std.fmt.format(writer, " ", .{}) catch {};
    self.rendered = @ptrCast(fbs.getWritten());
    self.buf[self.rendered.len] = 0;
}

fn format_count(self: *Self, writer: anytype, value: usize, width: usize) !void {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer_ = fbs.writer();
    try std.fmt.format(writer_, "{d}", .{value});
    const value_str = fbs.getWritten();

    const char: []const u8 = switch (self.leader orelse .space) {
        .space => " ",
        .zero => "0",
    };
    for (0..(@max(value_str.len, width) - value_str.len)) |_| try writer.writeAll(fonts.get_digit_ascii(char, self.style orelse .ascii));
    for (value_str, 0..) |_, i| try writer.writeAll(fonts.get_digit_ascii(value_str[i .. i + 1], self.style orelse .ascii));
}

pub fn receive(self: *Self, _: *ButtonType, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "E", "pos", tp.extract(&self.lines), tp.extract(&self.line), tp.extract(&self.column) })) {
        self.format();
    } else if (try m.match(.{ "E", "eol_mode", tp.extract(&self.eol_mode), tp.extract(&self.utf8_sanitized), tp.extract(&self.indent_mode) })) {
        self.format();
    } else if (try m.match(.{ "E", "open", tp.more })) {
        self.eol_mode = .lf;
    } else if (try m.match(.{ "E", "close" })) {
        self.lines = 0;
        self.line = 0;
        self.column = 0;
        self.rendered = "";
        self.eol_mode = .lf;
        self.utf8_sanitized = false;
    }
    return false;
}
