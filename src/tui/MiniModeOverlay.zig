const std = @import("std");
const tp = @import("thespian");
const Plane = @import("renderer").Plane;
const styles = @import("renderer").styles;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const OverlayLine = @import("OverlayLine.zig");
const modestate = @import("status/modestate.zig");

const Self = @This();

line: OverlayLine = .{ .name = "mini_mode_overlay.layer" },
label: ?Widget = null,
text_area: ?Widget = null,
shown: bool = false,
have_cursor: bool = false,

const TextArea = struct {
    plane: Plane,

    fn create(allocator: std.mem.Allocator, parent: Plane) !Widget {
        const self = try allocator.create(TextArea);
        errdefer allocator.destroy(self);
        self.* = .{ .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(TextArea)), parent) };
        return Widget.to(self);
    }

    pub fn deinit(self: *TextArea, allocator: std.mem.Allocator) void {
        self.plane.deinit();
        allocator.destroy(self);
    }

    pub fn receive(self: *TextArea, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var hover: bool = false;
        if (try m.match(.{ "H", tp.extract(&hover) })) {
            tui.rdr().request_mouse_cursor(.text, hover);
            return true;
        }
        const mini_mode = tui.mini_mode() orelse return false;
        const mini_editor = mini_mode.mini_editor orelse return false;
        return mini_editor.receive_mouse(self.plane, m);
    }
};

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.text_area) |*text_area| text_area.deinit(allocator);
    self.text_area = null;
    self.line.deinit(allocator);
    self.label = null;
}

fn create_widgets(self: *Self, allocator: std.mem.Allocator) !void {
    if (self.label != null) return;
    const layer = try self.line.get_layer(allocator);
    const label = modestate.create(allocator, layer.inner_plane(), null, null) catch return error.OutOfMemory;
    layer.set(label);
    self.label = label;
    self.text_area = try TextArea.create(allocator, layer.inner_plane());
}

pub fn render(self: *Self, allocator: std.mem.Allocator, theme: *const Widget.Theme, area: Widget.Box, mini_mode: *const tui.MiniMode) error{ NoSpace, OutOfMemory }!void {
    self.create_widgets(allocator) catch return error.OutOfMemory;
    const label = self.label orelse return;
    const label_width: usize = switch (label.layout()) {
        .static => |width| width,
        .dynamic => 0,
    };
    const editor_width = if (mini_mode.mini_editor) |mini_editor| mini_editor.width() + 2 else 0;
    var plane, _ = try self.line.begin(allocator, theme, area, .left, label_width + editor_width);
    label.resize(.{ .w = @min(label_width, plane.dim_x()), .h = 1 });
    if (self.text_area) |text_area| text_area.resize(.{ .w = plane.dim_x(), .h = 1 });
    self.shown = true;
    draw(&plane, theme, mini_mode, label_width + 1);
    self.have_cursor = mini_mode.mini_editor != null;
    self.line.end(theme);
}

pub fn hide(self: *Self) void {
    if (!self.shown) return;
    self.shown = false;
    if (self.label) |*label| label.resize(.{});
    if (self.text_area) |*text_area| text_area.resize(.{});
}

pub fn is_label(self: *const Self, ptr: *const anyopaque) bool {
    return if (self.label) |label| label.ptr == ptr else false;
}

pub fn walk(self: *const Self, ctx: *anyopaque, f: Widget.WalkFn) bool {
    if (self.label) |*label| if (label.walk(ctx, f)) return true;
    if (self.text_area) |*text_area| if (text_area.walk(ctx, f)) return true;
    return false;
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
