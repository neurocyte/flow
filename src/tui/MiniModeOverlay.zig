const std = @import("std");
const Plane = @import("renderer").Plane;
const styles = @import("renderer").styles;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const OverlayLine = @import("OverlayLine.zig");
const modestate = @import("status/modestate.zig");

const Self = @This();

line: OverlayLine = .{ .name = "mini_mode_overlay.layer" },
label: ?Widget = null,
shown: bool = false,
have_cursor: bool = false,

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.line.deinit(allocator);
    self.label = null;
}

fn get_label(self: *Self, allocator: std.mem.Allocator) !Widget {
    if (self.label) |label| return label;
    const layer = try self.line.get_layer(allocator);
    const label = modestate.create(allocator, layer.inner_plane(), null, null) catch return error.OutOfMemory;
    layer.set(label);
    self.label = label;
    return label;
}

pub fn render(self: *Self, allocator: std.mem.Allocator, theme: *const Widget.Theme, area: Widget.Box, mini_mode: *const tui.MiniMode) error{ NoSpace, OutOfMemory }!void {
    var label = try self.get_label(allocator);
    const label_width: usize = switch (label.layout()) {
        .static => |width| width,
        .dynamic => 0,
    };
    const editor_width = if (mini_mode.mini_editor) |mini_editor| mini_editor.width() + 2 else 0;
    var plane, _ = try self.line.begin(allocator, theme, area, .left, label_width + editor_width);
    label.resize(.{ .w = @min(label_width, plane.dim_x()), .h = 1 });
    self.shown = true;
    draw(&plane, theme, mini_mode, label_width + 1);
    self.have_cursor = mini_mode.mini_editor != null;
    self.line.end(theme);
}

pub fn hide(self: *Self) void {
    if (!self.shown) return;
    self.shown = false;
    if (self.label) |*label| label.resize(.{});
}

pub fn is_label(self: *const Self, ptr: *const anyopaque) bool {
    return if (self.label) |label| label.ptr == ptr else false;
}

pub fn walk(self: *const Self, ctx: *anyopaque, f: Widget.WalkFn) bool {
    return if (self.label) |*label| label.walk(ctx, f) else false;
}

pub fn release_cursor(self: *Self) void {
    if (!self.have_cursor) return;
    self.have_cursor = false;
    tui.plane().cursor_disable();
}

pub fn draw(plane: *Plane, theme: *const Widget.Theme, mini_mode: *const tui.MiniMode, x: usize) void {
    plane.off_styles(styles.italic);
    const mini_editor = mini_mode.mini_editor orelse return;
    const width: usize = plane.dim_x();
    mini_editor.render(plane, .{
        .x = @intCast(x),
        .width = width -| x,
        .style = theme.statusbar,
        .style_selection = theme.editor_selection,
    });
}
