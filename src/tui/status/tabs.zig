const std = @import("std");
const tp = @import("thespian");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const Buffer = @import("Buffer");

const tui = @import("../tui.zig");
const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const Button = @import("../Button.zig");

const dirty_indicator = " ";
const padding = " ";

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler) @import("widget.zig").CreateError!Widget {
    const self = try allocator.create(TabBar);
    self.* = try TabBar.init(allocator, parent, event_handler);
    return Widget.to(self);
}

const TabBar = struct {
    allocator: std.mem.Allocator,
    plane: Plane,
    widget_list: *WidgetList,
    widget_list_widget: Widget,
    event_handler: ?EventHandler,
    tabs: []TabBarTab = &[_]TabBarTab{},
    active_buffer: ?*Buffer = null,

    const Self = @This();

    const TabBarTab = struct {
        buffer: *Buffer,
        widget: Widget,
    };

    fn init(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler) !Self {
        var w = try WidgetList.createH(allocator, parent, "tabs", .dynamic);
        w.ctx = w;
        return .{
            .allocator = allocator,
            .plane = w.plane,
            .widget_list = w,
            .widget_list_widget = w.widget(),
            .event_handler = event_handler,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.allocator.free(self.tabs);
        self.widget_list_widget.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn layout(self: *Self) Widget.Layout {
        return self.widget_list_widget.layout();
    }

    pub fn update(self: *Self) void {
        self.update_tabs() catch {};
        self.widget_list_widget.resize(Widget.Box.from(self.plane));
        self.widget_list_widget.update();
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        self.plane.set_base_style(theme.editor);
        self.plane.erase();
        self.plane.home();
        self.plane.set_style(theme.tab_inactive);
        self.plane.fill(" ");
        self.plane.home();
        return self.widget_list_widget.render(theme);
    }

    pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        var file_path: []const u8 = undefined;
        if (try m.match(.{"next_tab"})) {
            self.select_next_tab();
        } else if (try m.match(.{"previous_tab"})) {
            self.select_previous_tab();
        } else if (try m.match(.{ "E", "open", tp.extract(&file_path), tp.more })) {
            self.active_buffer = buffer_manager.get_buffer_for_file(file_path);
        } else if (try m.match(.{ "E", "close" })) {
            self.active_buffer = null;
        }
        return false;
    }

    pub fn handle_resize(self: *Self, pos: Widget.Box) void {
        self.widget_list_widget.resize(pos);
        self.plane = self.widget_list.plane;
    }

    pub fn get(self: *Self, name: []const u8) ?*Widget {
        return self.widget_list_widget.get(name);
    }

    pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, _: *Widget) bool {
        return self.widget_list_widget.walk(ctx, f);
    }

    pub fn hover(self: *Self) bool {
        return self.widget_list_widget.hover();
    }

    fn update_tabs(self: *Self) !void {
        try self.update_tab_buffers();
        while (self.widget_list.pop()) |widget| if (widget.dynamic_cast(Button.State(Tab)) == null)
            widget.deinit(self.widget_list.allocator);
        var first = true;
        for (self.tabs) |tab| {
            if (first) {
                first = false;
            } else {
                try self.widget_list.add(try self.make_spacer());
            }
            try self.widget_list.add(tab.widget);
        }
    }

    fn update_tab_buffers(self: *Self) !void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffers = try buffer_manager.list_unordered(self.allocator);
        defer self.allocator.free(buffers);
        const existing_tabs = self.tabs;
        defer self.allocator.free(existing_tabs);
        var result: std.ArrayListUnmanaged(TabBarTab) = .{};
        errdefer result.deinit(self.allocator);

        // add existing tabs in original order if they still exist
        outer: for (existing_tabs) |existing_tab|
            for (buffers) |buffer| if (existing_tab.buffer == buffer) {
                if (!buffer.hidden)
                    (try result.addOne(self.allocator)).* = existing_tab;
                continue :outer;
            };

        // add new tabs
        outer: for (buffers) |buffer| {
            for (result.items) |result_tab| if (result_tab.buffer == buffer)
                continue :outer;
            if (!buffer.hidden)
                (try result.addOne(self.allocator)).* = .{
                    .buffer = buffer,
                    .widget = try Tab.create(self, buffer, self.event_handler),
                };
        }

        self.tabs = try result.toOwnedSlice(self.allocator);
    }

    fn make_spacer(self: @This()) !Widget {
        return spacer.create(self.allocator, self.widget_list.plane, null);
    }

    fn select_next_tab(self: *Self) void {
        tp.trace(tp.channel.debug, .{"select_next_tab"});
        var activate_next = false;
        var first: ?*const TabBarTab = null;
        for (self.tabs) |*tab| {
            if (first == null)
                first = tab;
            if (activate_next)
                return navigate_to_tab(tab);
            if (tab.buffer == self.active_buffer)
                activate_next = true;
        }
        if (first) |tab|
            navigate_to_tab(tab);
    }

    fn select_previous_tab(self: *Self) void {
        tp.trace(tp.channel.debug, .{"select_previous_tab"});
        var goto: ?*const TabBarTab = if (self.tabs.len > 0) &self.tabs[self.tabs.len - 1] else null;
        for (self.tabs) |*tab| {
            if (tab.buffer == self.active_buffer)
                break;
            goto = tab;
        }
        if (goto) |tab| navigate_to_tab(tab);
    }

    fn navigate_to_tab(tab: *const TabBarTab) void {
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = tab.buffer.file_path } }) catch {};
    }
};

const Tab = struct {
    tabbar: *TabBar,
    buffer: *Buffer,

    fn create(
        tabbar: *TabBar,
        buffer: *Buffer,
        event_handler: ?EventHandler,
    ) !Widget {
        return Button.create_widget(Tab, tabbar.allocator, tabbar.widget_list.plane, .{
            .ctx = .{ .tabbar = tabbar, .buffer = buffer },
            .label = name_from_buffer(buffer),
            .on_click = Tab.on_click,
            .on_click2 = Tab.on_click2,
            .on_layout = Tab.layout,
            .on_render = Tab.render,
            .on_event = event_handler,
        });
    }

    fn on_click(self: *@This(), _: *Button.State(@This())) void {
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = self.buffer.file_path } }) catch {};
    }

    fn on_click2(self: *@This(), _: *Button.State(@This())) void {
        tp.self_pid().send(.{ "cmd", "delete_buffer", .{self.buffer.file_path} }) catch {};
    }

    fn render(self: *@This(), btn: *Button.State(@This()), theme: *const Widget.Theme) bool {
        const active = self.tabbar.active_buffer == self.buffer;
        return if (active)
            self.render_active(btn, theme)
        else
            self.render_inactive(btn, theme);
    }

    fn render_active(self: *@This(), btn: *Button.State(@This()), theme: *const Widget.Theme) bool {
        btn.plane.set_base_style(theme.editor);
        btn.plane.erase();
        btn.plane.home();
        btn.plane.set_style(theme.tab_inactive);
        btn.plane.fill(" ");
        btn.plane.home();
        btn.plane.set_style(theme.tab_active);
        btn.plane.fill(" ");
        btn.plane.home();
        return self.render_content(btn);
    }

    fn render_inactive(self: *@This(), btn: *Button.State(@This()), theme: *const Widget.Theme) bool {
        btn.plane.set_base_style(theme.editor);
        btn.plane.erase();
        btn.plane.home();
        btn.plane.set_style(theme.tab_inactive);
        btn.plane.fill(" ");
        btn.plane.home();
        if (btn.hover) {
            btn.plane.set_style(theme.tab_selected);
            btn.plane.fill(" ");
            btn.plane.home();
        }
        return self.render_content(btn);
    }

    fn render_content(self: *@This(), btn: *Button.State(@This())) bool {
        _ = btn.plane.putstr(" ") catch {};
        if (self.buffer.is_dirty())
            _ = btn.plane.putstr(dirty_indicator) catch {};
        _ = btn.plane.putstr(btn.opts.label) catch {};
        _ = btn.plane.putstr(" ") catch {};
        return false;
    }

    fn layout(self: *@This(), btn: *Button.State(@This())) Widget.Layout {
        const len = btn.plane.egc_chunk_width(btn.opts.label, 0, 1);
        const len_dirty_indicator = btn.plane.egc_chunk_width(dirty_indicator, 0, 1);
        const len_padding = btn.plane.egc_chunk_width(padding, 0, 1);
        return if (self.buffer.is_dirty())
            .{ .static = len + (2 * len_padding) + len_dirty_indicator }
        else
            .{ .static = len + (2 * len_padding) };
    }

    fn name_from_buffer(buffer: *Buffer) []const u8 {
        const file_path = buffer.file_path;
        const basename_begin = std.mem.lastIndexOfScalar(u8, file_path, std.fs.path.sep);
        const basename = if (basename_begin) |begin| file_path[begin + 1 ..] else file_path;
        return basename;
    }
};

const spacer = struct {
    plane: Plane,
    layout: Widget.Layout,
    on_event: ?EventHandler,

    const Self = @This();

    fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler) @import("widget.zig").CreateError!Widget {
        const self: *Self = try allocator.create(Self);
        self.* = .{
            .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
            .layout = .{ .static = 1 },
            .on_event = event_handler,
        };
        return Widget.to(self);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.plane.deinit();
        allocator.destroy(self);
    }

    pub fn layout(self: *Self) Widget.Layout {
        return self.layout;
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        self.plane.set_base_style(theme.editor);
        self.plane.erase();
        self.plane.home();
        self.plane.set_style(theme.tab_inactive);
        self.plane.fill(" ");
        self.plane.home();
        return false;
    }

    pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var btn: u32 = 0;
        if (try m.match(.{ "D", tp.any, tp.extract(&btn), tp.more })) {
            if (self.on_event) |h| h.send(from, m) catch {};
            return true;
        }
        return false;
    }
};
