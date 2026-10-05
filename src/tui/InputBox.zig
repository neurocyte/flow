const std = @import("std");
const tp = @import("thespian");

const Plane = @import("renderer").Plane;
const input = @import("input");
const MouseEvent = @import("MouseEvent");

const Widget = @import("Widget.zig");
const MiniEditor = @import("MiniEditor.zig");
const tui = @import("tui.zig");

pub fn Options(context: type) type {
    return struct {
        label: []const u8 = "Enter text",
        hint: ?[]const u8 = null,
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
            const style_input_placeholder = theme.input_placeholder;
            const text = self.mini_editor.bytes();
            const style_label = if (text.len > 0) theme.input else style_input_placeholder;
            self.plane.set_base_style(style_base);
            self.plane.erase();
            self.plane.home();
            self.plane.set_style(style_label);
            self.plane.fill(" ");
            self.plane.home();
            var hint_width: usize = 0;
            if (self.hint.items.len > 0) {
                const hint = self.hint.items;
                self.plane.set_style(style_input_placeholder);
                _ = self.plane.print_aligned_right(0, "{s} ", .{hint}) catch {};
                hint_width = self.plane.egc_chunk_width(hint, 0, 1) + 2;
                self.plane.home();
                self.plane.set_style(style_label);
            }
            const x: c_int = self.opts.padding;
            if (text.len == 0) {
                const prefix_width = self.plane.egc_chunk_width(self.mini_editor.prefix.items, 0, 1);
                self.plane.cursor_move_yx(0, x + @as(c_int, @intCast(prefix_width)));
                _ = self.plane.print("{s} ", .{self.label.items}) catch {};
            }
            const used = @as(usize, @intCast(x)) + hint_width;
            const width = self.plane.dim_x();
            self.mini_editor.render(&self.plane, .{
                .x = x,
                .width = if (width > used) width - used else 1,
                .style = style_label,
                .style_selection = theme.editor_selection,
            });
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
    const mini_editor = try MiniEditor.create(allocator);
    errdefer mini_editor.destroy();
    self.* = .{
        .allocator = allocator,
        .parent = parent,
        .plane = n,
        .opts = opts,
        .label = .empty,
        .hint = .empty,
        .mini_editor = mini_editor,
    };
    if (tui.config().show_fileicons) if (opts.icon) |icon|
        try mini_editor.set_prefix(icon);
    try self.label.appendSlice(self.allocator, self.opts.label);
    self.opts.label = self.label.items;
    if (self.opts.hint) |hint| {
        try self.hint.appendSlice(self.allocator, hint);
        self.opts.hint = self.hint.items;
    }
    return Widget.to(self);
}

pub fn State(ctx_type: type) type {
    return struct {
        allocator: std.mem.Allocator,
        parent: Plane,
        plane: Plane,
        active: bool = false,
        hover: bool = false,
        label: std.ArrayList(u8),
        hint: std.ArrayList(u8),
        opts: Options(ctx_type),
        mini_editor: *MiniEditor,

        const Self = @This();
        pub const Context = ctx_type;

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.mini_editor.destroy();
            self.hint.deinit(self.allocator);
            self.label.deinit(self.allocator);
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
            if (try m.match(.{ MouseEvent.Type.press, MouseEvent.Button.left, tp.more })) {
                self.active = true;
                tui.need_render(@src());
                return true;
            } else if (try m.match(.{ MouseEvent.Type.release, MouseEvent.Button.left, tp.more })) {
                self.opts.on_click(self.opts.ctx, self);
                self.active = false;
                tui.need_render(@src());
                return true;
            } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
                tui.rdr().request_mouse_cursor_pointer(self.hover);
                tui.need_render(@src());
                return true;
            }
            return false;
        }
    };
}
