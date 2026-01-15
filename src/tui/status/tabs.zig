const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const Buffer = @import("Buffer");
const input = @import("input");

const tui = @import("../tui.zig");
const Widget = @import("../Widget.zig");
const WidgetList = @import("../WidgetList.zig");
const Button = @import("../Button.zig");

const default_min_tabs = 2;

const @"style.config" = struct {
    default_minimum_tabs_shown: usize = 2,

    padding: []const u8 = " ",
    padding_left: usize = 2,
    padding_right: usize = 1,

    clean_indicator: []const u8 = " ",
    clean_indicator_fg: ?colors = null,
    dirty_indicator: []const u8 = "",
    dirty_indicator_fg: ?colors = null,
    close_icon: []const u8 = "󰅖",
    close_icon_fg: colors = .Error,
    save_icon: []const u8 = "󰆓",
    save_icon_fg: ?colors = null,

    spacer: []const u8 = "|",
    spacer_fg: colors = .active_bg,
    spacer_bg: colors = .inactive_bg,

    bar_fg: colors = .inactive_fg,
    bar_bg: colors = .inactive_bg,

    active_fg: colors = .active_fg,
    active_bg: colors = .active_bg,
    active_left: []const u8 = "🭅",
    active_left_fg: colors = .active_bg,
    active_left_bg: colors = .inactive_bg,
    active_right: []const u8 = "🭐",
    active_right_fg: colors = .active_bg,
    active_right_bg: colors = .inactive_bg,

    inactive_fg: colors = .inactive_fg,
    inactive_bg: colors = .inactive_bg,
    inactive_left: []const u8 = " ",
    inactive_left_fg: colors = .inactive_fg,
    inactive_left_bg: colors = .inactive_bg,
    inactive_right: []const u8 = " ",
    inactive_right_fg: colors = .inactive_fg,
    inactive_right_bg: colors = .inactive_bg,

    selected_fg: colors = .active_fg,
    selected_bg: colors = .active_bg,
    selected_left: []const u8 = "🭅",
    selected_left_fg: colors = .active_bg,
    selected_left_bg: colors = .inactive_bg,
    selected_right: []const u8 = "🭐",
    selected_right_fg: colors = .active_bg,
    selected_right_bg: colors = .inactive_bg,

    file_type_icon: bool = true,

    include_files: []const u8 = "",
};
pub const Style = @"style.config";

pub fn create(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler, arg: ?[]const u8) @import("widget.zig").CreateError!Widget {
    const min_tabs = if (arg) |str_size| std.fmt.parseInt(usize, str_size, 10) catch null else null;
    const self = try allocator.create(TabBar);
    errdefer allocator.destroy(self);
    self.* = try TabBar.init(allocator, parent, event_handler, min_tabs);
    return Widget.to(self);
}

pub const TabBar = struct {
    allocator: std.mem.Allocator,
    plane: Plane,
    widget_list: *WidgetList,
    widget_list_widget: Widget,
    event_handler: ?EventHandler,
    tabs: []TabBarTab = &[_]TabBarTab{},
    active_buffer_ref: ?usize = null,
    minimum_tabs_shown: usize,
    place_next: Placement = .atend,

    tab_style: Style,
    tab_style_bufs: [][]const u8,

    const Self = @This();

    const Placement = union(enum) {
        atend,
        before: usize,
        after: usize,
    };

    const TabBarTab = struct {
        buffer_ref: usize,
        widget: Widget,
        view: ?usize,
    };

    fn init(allocator: std.mem.Allocator, parent: Plane, event_handler: ?EventHandler, min_tabs: ?usize) !Self {
        var w = try WidgetList.createH(allocator, parent, "tabs", .dynamic);
        w.render_decoration = null;
        w.ctx = w;
        const tab_style, const tab_style_bufs = root.read_config(Style, allocator);
        return .{
            .allocator = allocator,
            .plane = w.plane,
            .widget_list = w,
            .widget_list_widget = w.widget(),
            .event_handler = event_handler,
            .tab_style = tab_style,
            .tab_style_bufs = tab_style_bufs,
            .minimum_tabs_shown = min_tabs orelse tab_style.default_minimum_tabs_shown,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        root.free_config(self.allocator, self.tab_style_bufs);
        self.allocator.free(self.tabs);
        self.widget_list_widget.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn layout(self: *Self) Widget.Layout {
        return if (self.tabs.len >= self.minimum_tabs_shown)
            self.widget_list_widget.layout()
        else
            .{ .static = 0 };
    }

    pub fn update(self: *Self) void {
        const drag_source, const drag_btn = tui.get_drag_source();
        self.update_tabs(drag_source) catch {};
        self.widget_list_widget.resize(Widget.Box.from(self.plane));
        self.widget_list_widget.update();
        for (self.widget_list.widgets.items) |*split_widgetstate| if (split_widgetstate.widget.dynamic_cast(WidgetList)) |split|
            for (split.widgets.items) |*widgetstate| if (widgetstate.widget.dynamic_cast(Tab.ButtonType)) |btn| if (btn.drag_pos) |_|
                tui.update_drag_source(&widgetstate.widget, drag_btn);
        tui.refresh_hover(@src());
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        self.plane.set_base_style(theme.editor);
        self.plane.erase();
        self.plane.home();
        self.plane.set_style(.{
            .fg = self.tab_style.bar_fg.from_theme(theme),
            .bg = self.tab_style.bar_bg.from_theme(theme),
        });
        self.plane.fill(" ");
        self.plane.home();
        return self.widget_list_widget.render(theme);
    }

    pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        var file_path: []const u8 = undefined;
        var buffer_ref_a: usize = undefined;
        var buffer_ref_b: usize = undefined;
        if (try m.match(.{"next_tab"})) {
            self.select_next_tab();
        } else if (try m.match(.{"previous_tab"})) {
            self.select_previous_tab();
        } else if (try m.match(.{"move_tab_next"})) {
            self.move_tab_next();
        } else if (try m.match(.{"move_tab_previous"})) {
            self.move_tab_previous();
        } else if (try m.match(.{ "swap_tabs", tp.extract(&buffer_ref_a), tp.extract(&buffer_ref_b) })) {
            self.swap_tabs(buffer_ref_a, buffer_ref_b);
        } else if (try m.match(.{ "place_next_tab", "after", tp.extract(&buffer_ref_a) })) {
            self.place_next_tab(.after, buffer_ref_a);
        } else if (try m.match(.{ "place_next_tab", "before", tp.extract(&buffer_ref_a) })) {
            self.place_next_tab(.before, buffer_ref_a);
        } else if (try m.match(.{ "place_next_tab", "atend" })) {
            self.place_next = .atend;
        } else if (try m.match(.{ "E", "open", tp.extract(&file_path), tp.more })) {
            self.active_buffer_ref = if (buffer_manager.get_buffer_for_file(file_path)) |buffer|
                buffer_manager.buffer_to_ref(buffer)
            else
                null;
        } else if (try m.match(.{ "E", "close" })) {
            self.active_buffer_ref = null;
        }
        return false;
    }

    fn handle_event(self: *Self, from: tp.pid_ref, m: tp.message) tp.result {
        if (self.event_handler) |event_handler| try event_handler.send(from, m);
        if (try m.match(.{ "D", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.more })) {
            const dragging = for (self.tabs, 0..) |*tab, idx| {
                if (tab.widget.dynamic_cast(Tab.ButtonType)) |btn|
                    if (btn.drag_pos) |_| break idx;
            } else return;
            const hover_ = for (self.tabs, 0..) |*tab, idx| {
                if (tab.widget.dynamic_cast(Tab.ButtonType)) |btn|
                    if (btn.hover) break idx;
            } else return;
            if (dragging != hover_) {
                self.swap_tabs_by_index(dragging, hover_);
                if (self.tabs[dragging].widget.dynamic_cast(Tab.ButtonType)) |btn| btn.hover = false;
                self.update();
            }
        }
    }

    pub fn handle_resize(self: *Self, pos: Widget.Box) void {
        self.widget_list_widget.resize(pos);
        self.plane = self.widget_list.plane;
    }

    pub fn get(self: *const Self, name: []const u8) ?*const Widget {
        return self.widget_list_widget.get(name);
    }

    pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, _: *Widget) bool {
        return self.widget_list_widget.walk(ctx, f);
    }

    pub fn hover(self: *Self) bool {
        return self.widget_list_widget.hover();
    }

    fn update_tabs(self: *Self, drag_source: ?*Widget) !void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        try self.update_tab_buffers();
        var prev_widget_count: usize = 0;
        for (self.widget_list.widgets.items) |*split_widgetstate| if (split_widgetstate.widget.dynamic_cast(WidgetList)) |split| {
            prev_widget_count += 1;
            for (split.widgets.items) |_| prev_widget_count += 1;
        };

        for (self.widget_list.widgets.items) |*split_widget| if (split_widget.widget.dynamic_cast(WidgetList)) |split| {
            for (split.widgets.items) |*widget|
                if (&widget.widget == drag_source) tui.reset_drag_context();
        };
        while (self.widget_list.pop()) |split_widget| if (split_widget.dynamic_cast(WidgetList)) |split| {
            while (split.pop()) |widget| if (widget.dynamic_cast(Tab.ButtonType) == null)
                widget.deinit(self.widget_list.allocator);
            split.deinit(self.widget_list.allocator);
        };

        var max_view: usize = 0;
        for (self.tabs) |tab| max_view = @max(max_view, tab.view orelse 0);

        var widget_count: usize = 0;
        for (0..max_view + 1) |view| {
            var first = true;
            var view_widget_list = try WidgetList.createH(self.allocator, self.widget_list.plane, "split", .dynamic);
            try self.widget_list.add(view_widget_list.widget());
            widget_count += 1;
            for (self.tabs) |tab| {
                const tab_view = tab.view orelse 0;
                if (tab_view != view) continue;
                if (first) {
                    first = false;
                } else {
                    try view_widget_list.add(try self.make_spacer(view_widget_list.plane));
                    widget_count += 1;
                }
                try view_widget_list.add(tab.widget);
                widget_count += 1;
                if (tab.widget.dynamic_cast(Tab.ButtonType)) |btn| {
                    if (buffer_manager.buffer_from_ref(tab.buffer_ref)) |buffer|
                        try btn.update_label(Tab.name_from_buffer(buffer));
                }
            }
        }
        if (prev_widget_count != self.widget_list.widgets.items.len)
            tui.refresh_hover(@src());
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
            for (buffers) |buffer| if (existing_tab.buffer_ref == buffer_manager.buffer_to_ref(buffer)) {
                if (!buffer.hidden)
                    (try result.addOne(self.allocator)).* = existing_tab;
                continue :outer;
            };

        // add new tabs
        outer: for (buffers) |buffer| {
            for (result.items) |result_tab| if (result_tab.buffer_ref == buffer_manager.buffer_to_ref(buffer))
                continue :outer;
            if (!buffer.hidden)
                try self.place_new_tab(&result, buffer);
        }

        self.tabs = try result.toOwnedSlice(self.allocator);
    }

    fn place_new_tab(self: *Self, result: *std.ArrayListUnmanaged(TabBarTab), buffer: *Buffer) !void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffer_ref = buffer_manager.buffer_to_ref(buffer);
        const tab = try Tab.create(self, buffer_ref, &self.tab_style);
        const pos = switch (self.place_next) {
            .atend => try result.addOne(self.allocator),
            .before => |i| if (i < result.items.len)
                &(try result.addManyAt(self.allocator, i, 1))[0]
            else
                try result.addOne(self.allocator),
            .after => |i| if (i < result.items.len - 1)
                &(try result.addManyAt(self.allocator, i + 1, 1))[0]
            else
                try result.addOne(self.allocator),
        };
        pos.* = .{ .buffer_ref = buffer_ref, .widget = tab, .view = buffer.get_last_view() };
        self.place_next = .atend;
    }

    fn make_spacer(self: @This(), parent: Plane) !Widget {
        return spacer.create(
            self.allocator,
            parent,
            self.tab_style.spacer,
            self.tab_style.spacer_fg,
            self.tab_style.spacer_bg,
            null,
        );
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
            if (tab.buffer_ref == self.active_buffer_ref)
                activate_next = true;
        }
        if (first) |tab|
            navigate_to_tab(tab);
    }

    fn select_previous_tab(self: *Self) void {
        tp.trace(tp.channel.debug, .{"select_previous_tab"});
        var goto: ?*const TabBarTab = if (self.tabs.len > 0) &self.tabs[self.tabs.len - 1] else null;
        for (self.tabs) |*tab| {
            if (tab.buffer_ref == self.active_buffer_ref)
                break;
            goto = tab;
        }
        if (goto) |tab| navigate_to_tab(tab);
    }

    fn move_tab_next(self: *Self) void {
        tp.trace(tp.channel.debug, .{"move_tab_next"});
        for (self.tabs, 0..) |*tab, idx| if (tab.buffer_ref == self.active_buffer_ref and idx < self.tabs.len - 1) {
            const tmp = self.tabs[idx + 1];
            self.tabs[idx + 1] = self.tabs[idx];
            self.tabs[idx] = tmp;
            break;
        };
    }

    fn move_tab_previous(self: *Self) void {
        tp.trace(tp.channel.debug, .{"move_tab_previous"});
        for (self.tabs, 0..) |*tab, idx| if (tab.buffer_ref == self.active_buffer_ref and idx > 0) {
            const tmp = self.tabs[idx - 1];
            self.tabs[idx - 1] = self.tabs[idx];
            self.tabs[idx] = tmp;
            break;
        };
    }

    fn swap_tabs(self: *Self, buffer_ref_a: usize, buffer_ref_b: usize) void {
        tp.trace(tp.channel.debug, .{ "swap_tabs", "buffers", buffer_ref_a, buffer_ref_b });
        if (buffer_ref_a == buffer_ref_b) {
            tp.trace(tp.channel.debug, .{ "swap_tabs", "same_buffer" });
            return;
        }
        const tab_a_idx = for (self.tabs, 0..) |*tab, idx| if (tab.buffer_ref == buffer_ref_a) break idx else continue else {
            tp.trace(tp.channel.debug, .{ "swap_tabs", "not_found", "buffer_ref_a" });
            return;
        };
        const tab_b_idx = for (self.tabs, 0..) |*tab, idx| if (tab.buffer_ref == buffer_ref_b) break idx else continue else {
            tp.trace(tp.channel.debug, .{ "swap_tabs", "not_found", "buffer_ref_b" });
            return;
        };
        self.swap_tabs_by_index(tab_a_idx, tab_b_idx);
    }

    fn swap_tabs_by_index(self: *Self, tab_a_idx: usize, tab_b_idx: usize) void {
        const tmp = self.tabs[tab_a_idx];
        self.tabs[tab_a_idx] = self.tabs[tab_b_idx];
        self.tabs[tab_b_idx] = tmp;
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        if (buffer_manager.buffer_from_ref(self.tabs[tab_a_idx].buffer_ref)) |buffer_a|
            if (buffer_manager.buffer_from_ref(self.tabs[tab_b_idx].buffer_ref)) |buffer_b| {
                const view_a = buffer_a.get_last_view();
                const view_b = buffer_b.get_last_view();
                if (view_a != view_b) {
                    buffer_a.set_last_view(view_b);
                    buffer_b.set_last_view(view_a);
                }
            };
        tp.trace(tp.channel.debug, .{ "swap_tabs", "swapped", "indexes", tab_a_idx, tab_b_idx });
    }

    fn place_next_tab(self: *Self, position: enum { before, after }, buffer_ref: usize) void {
        tp.trace(tp.channel.debug, .{ "place_next_tab", position, buffer_ref });
        const tab_idx = for (self.tabs, 0..) |*tab, idx| if (tab.buffer_ref == buffer_ref) break idx else continue else {
            tp.trace(tp.channel.debug, .{ "place_next_tab", "not_found", buffer_ref });
            return;
        };
        self.place_next = switch (position) {
            .before => .{ .before = tab_idx },
            .after => .{ .after = tab_idx },
        };
    }

    fn navigate_to_tab(tab: *const TabBarTab) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        if (buffer_manager.buffer_from_ref(tab.buffer_ref)) |buffer|
            tp.self_pid().send(.{ "cmd", "navigate", .{ .file = buffer.get_file_path() } }) catch {};
    }

    pub fn write_state(self: *const Self, writer: *std.Io.Writer) error{WriteFailed}!void {
        try cbor.writeArrayHeader(writer, self.tabs.len);
        for (self.tabs) |tab| try cbor.writeValue(writer, ref_to_name(tab.buffer_ref));
    }

    fn ref_to_name(buffer_ref: usize) ?[]const u8 {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        return if (buffer_manager.buffer_from_ref(buffer_ref)) |buffer| buffer.get_file_path() else null;
    }

    pub fn extract_state(self: *Self, iter: *[]const u8) !void {
        var iter2 = iter.*;
        self.allocator.free(self.tabs);
        self.tabs = &.{};

        var result: std.ArrayListUnmanaged(TabBarTab) = .{};
        errdefer result.deinit(self.allocator);

        var count = cbor.decodeArrayHeader(&iter2) catch return error.MatchTabArrayFailed;
        while (count > 0) : (count -= 1) {
            var buffer_name: ?[]const u8 = undefined;
            if (!(cbor.matchValue(&iter2, cbor.extract(&buffer_name)) catch false)) return error.MatchTabBufferNameFailed;
            if (buffer_name) |name| {
                const buffer_ref_, const buffer_view = name_to_ref_and_view(name);
                if (buffer_ref_) |buffer_ref|
                    (try result.addOne(self.allocator)).* = .{
                        .buffer_ref = buffer_ref,
                        .widget = try Tab.create(self, buffer_ref, &self.tab_style),
                        .view = buffer_view,
                    };
            }
        }

        self.tabs = try result.toOwnedSlice(self.allocator);
        iter.* = iter2;
    }

    fn name_to_ref_and_view(buffer_name: []const u8) struct { ?usize, ?usize } {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        return if (buffer_manager.get_buffer_for_file(buffer_name)) |buffer|
            .{ buffer_manager.buffer_to_ref(buffer), buffer.get_last_view() }
        else
            .{ null, null };
    }
};

const Tab = struct {
    tabbar: *TabBar,
    buffer_ref: usize,
    tab_style: *const Style,
    close_pos: ?i32 = null,
    save_pos: ?i32 = null,
    on_event: ?EventHandler = null,

    const Mode = enum { active, inactive, selected };

    const ButtonType = Button.Options(@This()).ButtonType;

    fn create(
        tabbar: *TabBar,
        buffer_ref: usize,
        tab_style: *const Style,
    ) !Widget {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffer = buffer_manager.buffer_from_ref(buffer_ref);
        return Button.create_widget(Tab, tabbar.allocator, tabbar.widget_list.plane, .{
            .ctx = .{ .tabbar = tabbar, .buffer_ref = buffer_ref, .tab_style = tab_style },
            .label = if (buffer) |buf| name_from_buffer(buf) else "???",
            .on_click = Tab.on_click,
            .on_click2 = Tab.on_click2,
            .on_layout = Tab.layout,
            .on_render = Tab.render,
            .on_event = EventHandler.bind(tabbar, TabBar.handle_event),
        });
    }

    fn on_click(self: *@This(), _: *ButtonType, pos: Widget.Pos) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        if (buffer_manager.buffer_from_ref(self.buffer_ref)) |buffer| {
            if (self.close_pos) |close_pos| if (pos.x == close_pos) {
                tp.self_pid().send(.{ "cmd", "close_buffer", .{buffer.get_file_path()} }) catch {};
                return;
            };
            if (self.save_pos) |save_pos| if (pos.x == save_pos) {
                tp.self_pid().send(.{ "cmd", "save_buffer", .{buffer.get_file_path()} }) catch {};
                return;
            };
            tp.self_pid().send(.{ "cmd", "navigate", .{ .file = buffer.get_file_path() } }) catch {};
        }
    }

    fn on_click2(self: *@This(), _: *ButtonType, _: Widget.Pos) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        if (buffer_manager.buffer_from_ref(self.buffer_ref)) |buffer|
            tp.self_pid().send(.{ "cmd", "close_buffer", .{buffer.get_file_path()} }) catch {};
    }

    fn render(self: *@This(), btn: *ButtonType, theme: *const Widget.Theme) bool {
        const active = self.tabbar.active_buffer_ref == self.buffer_ref;
        if (btn.drag_pos) |pos| {
            self.render_dragging(&btn.plane, theme);
            const anchor: Widget.Pos = btn.drag_anchor orelse .{};
            var box = Widget.Box.from(btn.plane);
            box.y = @intCast(@max(pos.y, anchor.y) - anchor.y);
            box.x = @intCast(@max(pos.x, anchor.x) - anchor.x);
            if (tui.top_layer(box.to_layer())) |top_layer| {
                self.render_selected(top_layer, btn.opts.label, false, theme, active);
            }
        } else {
            const mode: Mode = if (btn.hover) .selected else if (active) .active else .inactive;
            switch (mode) {
                .selected => self.render_selected(&btn.plane, btn.opts.label, btn.hover, theme, active),
                .active => self.render_active(&btn.plane, btn.opts.label, btn.hover, theme),
                .inactive => self.render_inactive(&btn.plane, btn.opts.label, btn.hover, theme),
            }
        }
        return false;
    }

    fn render_selected(self: *@This(), plane: *Plane, label: []const u8, hover: bool, theme: *const Widget.Theme, active: bool) void {
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = self.tab_style.inactive_fg.from_theme(theme),
            .bg = self.tab_style.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();
        if (active) {
            plane.set_style(.{
                .fg = self.tab_style.selected_fg.from_theme(theme),
                .bg = self.tab_style.selected_bg.from_theme(theme),
            });
            plane.fill(" ");
            plane.home();
        }

        plane.set_style(.{
            .fg = self.tab_style.selected_left_fg.from_theme(theme),
            .bg = self.tab_style.selected_left_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.selected_left) catch {};

        plane.set_style(.{
            .fg = self.tab_style.selected_fg.from_theme(theme),
            .bg = self.tab_style.selected_bg.from_theme(theme),
        });
        self.render_content(plane, label, hover, self.tab_style.selected_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = self.tab_style.selected_right_fg.from_theme(theme),
            .bg = self.tab_style.selected_right_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.selected_right) catch {};
    }

    fn render_active(self: *@This(), plane: *Plane, label: []const u8, hover: bool, theme: *const Widget.Theme) void {
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = self.tab_style.inactive_fg.from_theme(theme),
            .bg = self.tab_style.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();
        plane.set_style(.{
            .fg = self.tab_style.active_fg.from_theme(theme),
            .bg = self.tab_style.active_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();

        plane.set_style(.{
            .fg = self.tab_style.active_left_fg.from_theme(theme),
            .bg = self.tab_style.active_left_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.active_left) catch {};

        plane.set_style(.{
            .fg = self.tab_style.active_fg.from_theme(theme),
            .bg = self.tab_style.active_bg.from_theme(theme),
        });
        self.render_content(plane, label, hover, self.tab_style.active_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = self.tab_style.active_right_fg.from_theme(theme),
            .bg = self.tab_style.active_right_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.active_right) catch {};
    }

    fn render_inactive(self: *@This(), plane: *Plane, label: []const u8, hover: bool, theme: *const Widget.Theme) void {
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = self.tab_style.inactive_fg.from_theme(theme),
            .bg = self.tab_style.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();

        plane.set_style(.{
            .fg = self.tab_style.inactive_left_fg.from_theme(theme),
            .bg = self.tab_style.inactive_left_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.inactive_left) catch {};

        plane.set_style(.{
            .fg = self.tab_style.inactive_fg.from_theme(theme),
            .bg = self.tab_style.inactive_bg.from_theme(theme),
        });
        self.render_content(plane, label, hover, self.tab_style.inactive_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = self.tab_style.inactive_right_fg.from_theme(theme),
            .bg = self.tab_style.inactive_right_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.inactive_right) catch {};
    }

    fn render_dragging(self: *@This(), plane: *Plane, theme: *const Widget.Theme) void {
        plane.set_base_style(theme.editor);
        plane.erase();
        plane.home();
        plane.set_style(.{
            .fg = self.tab_style.inactive_fg.from_theme(theme),
            .bg = self.tab_style.inactive_bg.from_theme(theme),
        });
        plane.fill(" ");
        plane.home();
    }

    fn render_content(self: *@This(), plane: *Plane, label: []const u8, hover: bool, fg: ?Widget.Theme.Color, theme: *const Widget.Theme) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffer_ = buffer_manager.buffer_from_ref(self.buffer_ref);
        const is_dirty = if (buffer_) |buffer| buffer.is_dirty() else false;
        const auto_save = if (buffer_) |buffer| buffer.is_auto_save() else false;
        self.render_padding(plane, .left);
        if (self.tab_style.file_type_icon) if (buffer_) |buffer| if (buffer.file_type_icon) |icon| {
            const color_: ?u24 = if (buffer.file_type_color) |color| if (!(color == 0xFFFFFF or color == 0x000000 or color == 0x000001)) color else null else null;
            if (color_) |color|
                plane.set_style(.{ .fg = .{ .color = color } });
            _ = plane.putstr(icon) catch {};
            if (color_) |_|
                plane.set_style(.{ .fg = fg });
            _ = plane.putstr("  ") catch {};
        };
        _ = plane.putstr(label) catch {};
        _ = plane.putstr(" ") catch {};
        self.close_pos = null;
        self.save_pos = null;
        if (hover) {
            if (is_dirty) {
                if (self.tab_style.save_icon_fg) |color|
                    plane.set_style(.{ .fg = color.from_theme(theme) });
                self.save_pos = plane.cursor_x();
                _ = plane.putstr(self.tabbar.tab_style.save_icon) catch {};
            } else {
                plane.set_style(.{ .fg = self.tab_style.close_icon_fg.from_theme(theme) });
                self.close_pos = plane.cursor_x();
                _ = plane.putstr(self.tabbar.tab_style.close_icon) catch {};
            }
        } else if (is_dirty and !auto_save) {
            if (self.tab_style.dirty_indicator_fg) |color|
                plane.set_style(.{ .fg = color.from_theme(theme) });
            _ = plane.putstr(self.tabbar.tab_style.dirty_indicator) catch {};
        } else {
            if (self.tab_style.clean_indicator_fg) |color|
                plane.set_style(.{ .fg = color.from_theme(theme) });
            _ = plane.putstr(self.tabbar.tab_style.clean_indicator) catch {};
        }
        plane.set_style(.{ .fg = fg });
        self.render_padding(plane, .right);
    }

    fn render_padding(self: *@This(), plane: *Plane, side: enum { left, right }) void {
        var padding: usize = switch (side) {
            .left => self.tab_style.padding_left,
            .right => self.tab_style.padding_right,
        };
        while (padding > 0) : (padding -= 1) _ = plane.putstr(self.tab_style.padding) catch {};
    }

    fn layout(self: *@This(), btn: *ButtonType) Widget.Layout {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const is_dirty = if (buffer_manager.buffer_from_ref(self.buffer_ref)) |buffer| buffer.is_dirty() else false;
        const active = self.tabbar.active_buffer_ref == self.buffer_ref;
        const len = btn.plane.egc_chunk_width(btn.opts.label, 0, 1);
        const len_padding = padding_len(btn.plane, self.tabbar.tab_style, active, is_dirty);
        return .{ .static = len + len_padding };
    }

    fn padding_len(plane: Plane, tab_style: Style, active: bool, dirty: bool) usize {
        const len_padding = plane.egc_chunk_width(tab_style.padding, 0, 1) * (tab_style.padding_left + tab_style.padding_right);
        const len_file_icon: usize = if (tab_style.file_type_icon) 3 else 0;
        const len_close_icon = plane.egc_chunk_width(tab_style.close_icon, 0, 1);
        const len_dirty_indicator = if (dirty) plane.egc_chunk_width(tab_style.dirty_indicator, 0, 1) else 0;
        const len_dirty_close = @max(len_close_icon, len_dirty_indicator) + 1; // +1 for the leading space
        return len_padding + len_file_icon + len_dirty_close + if (active)
            plane.egc_chunk_width(tab_style.active_left, 0, 1) +
                plane.egc_chunk_width(tab_style.active_right, 0, 1)
        else
            plane.egc_chunk_width(tab_style.inactive_left, 0, 1) +
                plane.egc_chunk_width(tab_style.inactive_right, 0, 1);
    }

    fn name_from_buffer(buffer: *Buffer) []const u8 {
        const file_path = buffer.get_file_path();
        if (file_path.len > 0 and file_path[0] == '*')
            return file_path;
        const basename_begin = std.mem.lastIndexOfScalar(u8, file_path, std.fs.path.sep);
        const basename = if (basename_begin) |begin| file_path[begin + 1 ..] else file_path;
        return basename;
    }

    fn write_state(self: *const @This(), writer: *std.Io.Writer) error{OutOfMemory}!void {
        try cbor.writeArrayHeader(writer, 9);
        try cbor.writeValue(writer, self.get_file_path());
        try cbor.writeValue(writer, self.file_exists);
        try cbor.writeValue(writer, self.file_eol_mode);
        try cbor.writeValue(writer, self.hidden);
        try cbor.writeValue(writer, self.ephemeral);
        try cbor.writeValue(writer, self.meta);
        try cbor.writeValue(writer, self.file_type_name);
    }

    fn extract_state(self: *@This(), iter: *[]const u8) !void {
        _ = self;
        _ = iter;
    }
};

const spacer = struct {
    plane: Plane,
    layout_: Widget.Layout,
    on_event: ?EventHandler,
    content: []const u8,
    fg: colors,
    bg: colors,

    const Self = @This();

    fn create(
        allocator: std.mem.Allocator,
        parent: Plane,
        content: []const u8,
        fg: colors,
        bg: colors,
        event_handler: ?EventHandler,
    ) @import("widget.zig").CreateError!Widget {
        const self: *Self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
            .layout_ = .{ .static = self.plane.egc_chunk_width(content, 0, 1) },
            .on_event = event_handler,
            .content = content,
            .fg = fg,
            .bg = bg,
        };
        return Widget.to(self);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.plane.deinit();
        allocator.destroy(self);
    }

    pub fn layout(self: *Self) Widget.Layout {
        return self.layout_;
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        self.plane.set_base_style(theme.editor);
        self.plane.erase();
        self.plane.home();
        self.plane.set_style(.{
            .fg = self.fg.from_theme(theme),
            .bg = self.bg.from_theme(theme),
        });
        self.plane.fill(" ");
        self.plane.home();
        _ = self.plane.putstr(self.content) catch {};
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

const colors = enum {
    default_bg,
    default_fg,
    active_bg,
    active_fg,
    inactive_bg,
    inactive_fg,
    selected_bg,
    selected_fg,

    Error,
    Warning,
    Information,
    Hint,

    fn from_theme(color: colors, theme: *const Widget.Theme) ?Widget.Theme.Color {
        return switch (color) {
            .default_bg => theme.editor.bg,
            .default_fg => theme.editor.fg,
            .active_bg => theme.tab_active.bg,
            .active_fg => theme.tab_active.fg,
            .inactive_bg => theme.tab_inactive.bg,
            .inactive_fg => theme.tab_inactive.fg,
            .selected_bg => theme.tab_selected.bg,
            .selected_fg => theme.tab_selected.fg,
            .Error => theme.editor_error.fg,
            .Warning => theme.editor_warning.fg,
            .Information => theme.editor_information.fg,
            .Hint => theme.editor_hint.fg,
        };
    }
};
