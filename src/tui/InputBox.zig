const std = @import("std");
const tp = @import("thespian");

const Plane = @import("renderer").Plane;
const input = @import("input");

const Widget = @import("Widget.zig");
const tui = @import("tui.zig");

pub fn Options(context: type) type {
    return struct {
        label: []const u8 = "Enter text",
        pos: Widget.Box = .{ .y = 0, .x = 0, .w = 12, .h = 1 },
        ctx: Context,
        padding: u8 = 1,
        icon: ?[]const u8 = null,

        on_click: *const fn (ctx: context, button: *State(Context)) void = do_nothing,
        on_render: *const fn (ctx: context, button: *State(Context), theme: *const Widget.Theme) bool = on_render_default,
        on_layout: *const fn (ctx: context, button: *State(Context)) Widget.Layout = on_layout_default,

        pub const Context = context;
        pub fn do_nothing(_: context, _: *State(Context)) void {}

        pub fn on_render_default(_: context, self: *State(Context), theme: *const Widget.Theme) bool {
            const style_base = theme.editor_widget;
            const style_label = if (self.text.items.len > 0) theme.input else theme.input_placeholder;
            self.plane.set_base_style(style_base);
            self.plane.erase();
            self.plane.home();
            self.plane.set_style(style_label);
            self.plane.fill(" ");
            self.plane.home();
            for (0..self.opts.padding) |_| _ = self.plane.putchar(" ");
            if (self.icon_width > 0) if (self.opts.icon) |icon| {
                _ = self.plane.print("{s}", .{icon}) catch {};
            };
            if (self.text.items.len > 0) {
                _ = self.plane.print("{s} ", .{self.text.items}) catch {};
            } else {
                _ = self.plane.print("{s} ", .{self.label.items}) catch {};
            }
            if (self.cursor) |cursor| {
                const pos: c_int = @intCast(cursor);
                if (tui.config().enable_terminal_cursor) {
                    const y, const x = self.plane.rel_yx_to_abs(0, pos + self.opts.padding + self.icon_width);
                    tui.rdr().cursor_enable(y, x, tui.get_cursor_shape()) catch {};
                } else {
                    self.plane.cursor_move_yx(0, pos + self.opts.padding + self.icon_width) catch return false;
                    var cell = self.plane.cell_init();
                    _ = self.plane.at_cursor_cell(&cell) catch return false;
                    cell.set_style(theme.editor_cursor);
                    _ = self.plane.putc(&cell) catch {};
                }
            }
            return false;
        }

        pub fn on_layout_default(_: context, _: *State(Context)) Widget.Layout {
            return .{ .static = 1 };
        }
    };
}

pub fn create(ctx_type: type, allocator: std.mem.Allocator, parent: Plane, opts: Options(ctx_type)) !Widget {
    const Self = State(ctx_type);
    var n = try Plane.init(&opts.pos.opts(@typeName(Self)), parent);
    errdefer n.deinit();
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .parent = parent,
        .plane = n,
        .opts = opts,
        .label = std.ArrayList(u8).init(allocator),
        .text = std.ArrayList(u8).init(allocator),
        .icon_width = @intCast(if (tui.config().show_fileicons) if (opts.icon) |icon| n.egc_chunk_width(icon, 0, 1) else 0 else 0),
    };
    try self.label.appendSlice(self.opts.label);
    self.opts.label = self.label.items;
    return Widget.to(self);
}

pub fn State(ctx_type: type) type {
    return struct {
        parent: Plane,
        plane: Plane,
        active: bool = false,
        hover: bool = false,
        label: std.ArrayList(u8),
        opts: Options(ctx_type),
        text: std.ArrayList(u8),
        icon_width: c_int,
        cursor: ?usize = 0,

        const Self = @This();
        pub const Context = ctx_type;

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.text.deinit();
            self.label.deinit();
            self.plane.deinit();
            allocator.destroy(self);
        }

        pub fn layout(self: *Self) Widget.Layout {
            return self.opts.on_layout(self.opts.ctx, self);
        }

        pub fn render(self: *Self, theme: *const Widget.Theme) bool {
            return self.opts.on_render(self.opts.ctx, self, theme);
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            if (try m.match(.{ "B", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.active = true;
                tui.need_render();
                return true;
            } else if (try m.match(.{ "B", input.event.release, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.opts.on_click(self.opts.ctx, self);
                self.active = false;
                tui.need_render();
                return true;
            } else if (try m.match(.{ "D", input.event.release, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.any, tp.any, tp.any })) {
                self.opts.on_click(self.opts.ctx, self);
                self.active = false;
                tui.need_render();
                return true;
            } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
                tui.rdr().request_mouse_cursor_pointer(self.hover);
                tui.need_render();
                return true;
            }
            return false;
        }
    };
}
