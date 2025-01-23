const std = @import("std");
const tp = @import("thespian");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const Buffer = @import("Buffer");

const tui = @import("../tui.zig");
const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const Button = @import("../Button.zig");

const dirty_indicator = "";

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler) @import("widget.zig").CreateError!Widget {
    const self = try allocator.create(TabBar);
    self.* = try TabBar.init(allocator, parent, event_handler);
    return Widget.to(self);
}

const TabBar = struct {
    allocator: std.mem.Allocator,
    plane: Plane,
    widget_list: *WidgetList,
    event_handler: ?EventHandler,
    tab_buffers: []*Buffer = &[_]*Buffer{},

    const Self = @This();

    fn init(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler) !Self {
        var w = try WidgetList.createH(allocator, parent, "tabs", .dynamic);
        w.ctx = w;
        return .{
            .allocator = allocator,
            .plane = w.plane,
            .widget_list = w,
            .event_handler = event_handler,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.allocator.free(self.tab_buffers);
        self.widget_list.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn layout(self: *Self) Widget.Layout {
        return self.widget_list.layout;
    }

    pub fn update(self: *Self) void {
        self.update_tabs() catch {};
        self.widget_list.resize(Widget.Box.from(self.plane));
        self.widget_list.update();
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        return self.widget_list.render(theme);
    }

    pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
        return self.widget_list.receive(from_, m);
    }

    pub fn handle_resize(self: *Self, pos: Widget.Box) void {
        self.widget_list.handle_resize(pos);
        self.plane = self.widget_list.plane;
    }

    pub fn get(self: *Self, name: []const u8) ?*Widget {
        return self.widget_list.get(name);
    }

    pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, self_w: *Widget) bool {
        return self.widget_list.walk(ctx, f, self_w);
    }

    pub fn hover(self: *Self) bool {
        return self.widget_list.hover();
    }

    fn update_tabs(self: *Self) !void {
        self.widget_list.remove_all();
        try self.update_tab_buffers();
        var first = true;
        for (self.tab_buffers) |buffer| {
            if (first) {
                first = false;
            } else {
                try self.widget_list.add(try self.make_spacer(1));
            }
            // const hint = if (buffer.is_dirty()) dirty_indicator else "";
            try self.widget_list.add(try Tab.create(self, buffer.file_path, self.event_handler));
        }
    }

    fn update_tab_buffers(self: *Self) !void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffers = try buffer_manager.list_most_recently_used(self.allocator);
        defer self.allocator.free(buffers);
        const exiting_buffers = self.tab_buffers;
        defer self.allocator.free(exiting_buffers);
        var result: std.ArrayListUnmanaged(*Buffer) = .{};
        errdefer result.deinit(self.allocator);

        // add existing tabs in original order if they still exist
        outer: for (exiting_buffers) |exiting_buffer|
            for (buffers) |buffer| if (exiting_buffer == buffer) {
                if (!buffer.hidden)
                    (try result.addOne(self.allocator)).* = buffer;
                continue :outer;
            };

        // add new tabs
        outer: for (buffers) |buffer| {
            for (result.items) |result_buffer| if (result_buffer == buffer)
                continue :outer;
            if (!buffer.hidden)
                (try result.addOne(self.allocator)).* = buffer;
        }

        self.tab_buffers = try result.toOwnedSlice(self.allocator);
    }

    fn make_spacer(self: @This(), comptime size: usize) !Widget {
        return @import("blank.zig").Create(.{ .static = size })(self.allocator, self.widget_list.plane, null);
    }
};

const Tab = struct {
    tabs: *TabBar,
    file_path: []const u8,

    fn create(
        tabs: *TabBar,
        file_path: []const u8,
        event_handler: ?EventHandler,
    ) !Widget {
        return Button.create_widget(Tab, tabs.allocator, tabs.widget_list.plane, .{
            .ctx = .{ .tabs = tabs, .file_path = file_path },
            .label = name_from_buffer_file_path(file_path),
            .on_click = Tab.on_click,
            .on_layout = Tab.layout,
            .on_render = Tab.render,
            // .on_receive = receive,
            .on_event = event_handler,
        });
    }
    fn on_click(self: *@This(), _: *Button.State(@This())) void {
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = self.file_path } }) catch {};
    }

    fn render(_: *@This(), btn: *Button.State(@This()), theme: *const Widget.Theme) bool {
        btn.plane.set_base_style(theme.editor);
        btn.plane.erase();
        btn.plane.home();
        btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
        btn.plane.fill(" ");
        btn.plane.home();
        btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar);
        _ = btn.plane.putstr(" ") catch {};
        _ = btn.plane.putstr(btn.opts.label) catch {};
        _ = btn.plane.putstr(" ") catch {};
        return false;
    }

    fn layout(_: *@This(), btn: *Button.State(@This())) Widget.Layout {
        const len = btn.plane.egc_chunk_width(btn.opts.label, 0, 1);
        return .{ .static = len + 2 };
    }

    fn name_from_buffer_file_path(file_path: []const u8) []const u8 {
        const basename_begin = std.mem.lastIndexOfScalar(u8, file_path, std.fs.path.sep);
        const basename = if (basename_begin) |begin| file_path[begin + 1 ..] else file_path;
        return basename;
    }
};
