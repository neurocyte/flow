const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const command = @import("command");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const tp = @import("thespian");
const reflow = @import("Buffer").reflow;
const tui = @import("tui.zig");

pub const name = @typeName(Self);

const Self = @This();

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
lines: std.ArrayList([]const u8),
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
top: usize = 0,

const default_widget_type: Widget.Type = .panel;

pub const panel_tag = "info";
pub const panel_singleton = true;

pub fn panel_title(_: *Self) []const u8 {
    return "Info";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "\u{ea74}";
}

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    const self = try init(allocator, parent, default_widget_type);
    errdefer self.deinit(allocator);
    self.panel_input = try PanelInput.init(allocator, "info");
    return Panel.to(self);
}

pub fn create_widget_type(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !Widget {
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    errdefer container.deinit(allocator);
    const self = try init(allocator, parent, widget_type);
    container.ctx = self;
    try container.add(Widget.to(self));
    return container.widget();
}

fn init(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .lines = .empty,
        .widget_type = widget_type,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.panel_input) |*panel_input| panel_input.deinit(Widget.to(self));
    self.clear();
    self.lines.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn focus(self: *Self) void {
    if (self.panel_input) |*panel_input| panel_input.focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    if (self.panel_input) |*panel_input| panel_input.unfocus(Widget.to(self));
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    return if (self.panel_input) |*panel_input| panel_input.receive(from, m) else false;
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    const rows = @max(1, self.view_rows);
    const max_top = self.lines.items.len -| rows;
    self.top = @min(max_top, switch (action) {
        .line_up => self.top -| 1,
        .line_down => self.top + 1,
        .page_up => self.top -| rows,
        .page_down => self.top + rows,
        .top => 0,
        .bottom => max_top,
    });
    tui.need_render(@src());
}

pub fn panel_copy(self: *Self) void {
    var text: std.Io.Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    for (self.lines.items) |line| text.writer.print("{s}\n", .{line}) catch return;
    PanelInput.copy_to_clipboard(text.written());
}

pub fn clear(self: *Self) void {
    for (self.lines.items) |line|
        self.allocator.free(line);
    self.lines.clearRetainingCapacity();
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.view_rows = pos.h;
}

pub fn append_content(self: *Self, content: []const u8) !void {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| if (line.len > 0) {
        const width = if (self.widget_type == .info_box)
            tui.config().info_box_width_limit
        else
            tui.screen().w;
        const text = try reflow(self.allocator, line, width, .screen, .spaces, self.plane.metrics(tui.config().tab_width));
        defer self.allocator.free(text);
        var iter_ = std.mem.splitScalar(u8, text, '\n');
        while (iter_.next()) |line_| if (line_.len > 0) {
            (try self.lines.addOne(self.allocator)).* = try self.allocator.dupe(u8, line_);
        };
    };
}

pub fn set_content(self: *Self, content: []const u8) !void {
    self.clear();
    self.top = 0;
    return self.append_content(content);
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    var cols: usize = 0;
    for (self.lines.items) |line| cols = @max(cols, line.len);
    return .{ .rows = self.lines.items.len, .cols = cols };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.plane.set_base_style(if (tui.config().hover_info_mode == .box) theme.editor_widget else theme.panel);
    self.plane.erase();
    self.plane.home();
    for (self.lines.items[@min(self.top, self.lines.items.len)..]) |line| {
        _ = self.plane.putstr(line) catch {};
        if (self.plane.cursor_y() >= self.view_rows - 1)
            return false;
        self.plane.cursor_move_yx(-1, 0);
        self.plane.cursor_move_rel(1, 0) catch {};
    }
    return false;
}
