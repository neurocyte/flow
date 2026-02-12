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
    clipping_indicator: []const u8 = "»",

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

    unfocused_active_fg: colors = .unfocused_active_fg,
    unfocused_active_bg: colors = .unfocused_active_bg,
    unfocused_active_left: []const u8 = "🭅",
    unfocused_active_left_fg: colors = .unfocused_active_bg,
    unfocused_active_left_bg: colors = .unfocused_inactive_bg,
    unfocused_active_right: []const u8 = "🭐",
    unfocused_active_right_fg: colors = .unfocused_active_bg,
    unfocused_active_right_bg: colors = .unfocused_inactive_bg,

    unfocused_inactive_fg: colors = .unfocused_inactive_fg,
    unfocused_inactive_bg: colors = .unfocused_inactive_bg,
    unfocused_inactive_left: []const u8 = " ",
    unfocused_inactive_left_fg: colors = .unfocused_inactive_fg,
    unfocused_inactive_left_bg: colors = .unfocused_inactive_bg,
    unfocused_inactive_right: []const u8 = " ",
    unfocused_inactive_right_fg: colors = .unfocused_inactive_fg,
    unfocused_inactive_right_bg: colors = .unfocused_inactive_bg,

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
    splits_list: *WidgetList,
    splits_list_widget: Widget,
    event_handler: ?EventHandler,
    tabs: []TabBarTab = &[_]TabBarTab{},
    active_focused_buffer_ref: ?Buffer.Ref = null,
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
        buffer_ref: Buffer.Ref,
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
            .splits_list = w,
            .splits_list_widget = w.widget(),
            .event_handler = event_handler,
            .tab_style = tab_style,
            .tab_style_bufs = tab_style_bufs,
            .minimum_tabs_shown = min_tabs orelse tab_style.default_minimum_tabs_shown,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        root.free_config(self.allocator, self.tab_style_bufs);
        self.allocator.free(self.tabs);
        self.splits_list_widget.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn layout(self: *Self) Widget.Layout {
        return if (self.tabs.len >= self.minimum_tabs_shown)
            self.splits_list_widget.layout()
        else
            .{ .static = 0 };
    }

    pub fn update(self: *Self) void {
        const drag_source, const drag_btn = tui.get_drag_source();
        self.update_tabs(drag_source) catch {};
        self.splits_list_widget.resize(Widget.Box.from(self.plane));
        self.splits_list_widget.update();
        for (self.splits_list.widgets.items) |*split_widgetstate| if (split_widgetstate.widget.dynamic_cast(WidgetList)) |split|
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
        for (self.tabs) |*tab| {
            const clipped, const clip_box = self.is_tab_clipped(tab);
            if (clipped) {
                if (clip_box) |box| self.render_clipping_indicator(box, theme);
                continue;
            }
            _ = tab.widget.render(theme);
        }
        return false;
    }

    fn is_tab_clipped(self: *const Self, tab: *const TabBarTab) struct { bool, ?Widget.Box } {
        const view = tab.view orelse return .{ true, null };
        const split_idx = if (view < self.splits_list.widgets.items.len) view else return .{ true, null };
        const split = self.splits_list.widgets.items[split_idx];
        const split_box = Widget.Box.from(split.widget.plane.*);
        const widget_box = tab.widget.box();
        const dragging = if (tab.widget.dynamic_cast(Tab.ButtonType)) |btn| if (btn.drag_pos) |_| true else false else false;
        if (dragging) return .{ false, split_box };
        if (split_box.y + split_box.h < widget_box.y + widget_box.h or
            split_box.x + split_box.w < widget_box.x + widget_box.w)
            return .{ true, split_box };
        return .{ false, split_box };
    }

    fn render_clipping_indicator(self: *@This(), box: Widget.Box, theme: *const Widget.Theme) void {
        self.plane.set_style(.{
            .fg = self.tab_style.bar_fg.from_theme(theme),
            .bg = self.tab_style.bar_bg.from_theme(theme),
        });
        self.plane.cursor_move_yx(0, @intCast(box.x + box.w -| 1));
        self.plane.putchar(self.tab_style.clipping_indicator);
    }

    pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var buffer_ref: Buffer.Ref = undefined;
        if (try m.match(.{"next_tab"})) {
            self.select_next_tab();
        } else if (try m.match(.{"previous_tab"})) {
            self.select_previous_tab();
        } else if (try m.match(.{"move_tab_next"})) {
            self.move_tab_next();
        } else if (try m.match(.{"move_tab_previous"})) {
            self.move_tab_previous();
        } else if (try m.match(.{ "place_next_tab", "after", tp.extract(&buffer_ref) })) {
            self.place_next_tab(.after, buffer_ref);
        } else if (try m.match(.{ "place_next_tab", "before", tp.extract(&buffer_ref) })) {
            self.place_next_tab(.before, buffer_ref);
        } else if (try m.match(.{ "place_next_tab", "atend" })) {
            self.place_next = .atend;
        } else if (try m.match(.{ "E", "open", tp.more })) {
            self.refresh_active_buffer();
        } else if (try m.match(.{ "E", "close" })) {
            self.refresh_active_buffer();
        } else if (try m.match(.{"splits_updated"})) {
            self.refresh_active_buffer();
            const drag_source, _ = tui.get_drag_source();
            self.update_tab_widgets(drag_source) catch {};
        }
        return false;
    }

    fn refresh_active_buffer(self: *Self) void {
        const mv = tui.mainview() orelse @panic("tabs no main view");
        const buffer = mv.get_active_buffer();
        self.active_focused_buffer_ref = if (buffer) |buf| buf.to_ref() else null;
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
            } else return self.handle_event_drop_target(dragging);
            if (dragging != hover_) {
                self.move_tab_to(hover_, dragging);
                if (self.tabs[dragging].widget.dynamic_cast(Tab.ButtonType)) |btn| btn.hover = false;
                self.update();
            }
        }
    }

    fn handle_event_drop_target(self: *Self, dragging: usize) tp.result {
        var hover_view: ?usize = null;
        for (self.splits_list.widgets.items, 0..) |*split_widgetstate, idx|
            if (split_widgetstate.widget.dynamic_cast(WidgetList)) |split| {
                for (split.widgets.items) |*widgetstate|
                    if (widgetstate.widget.dynamic_cast(drop_target.ButtonType)) |btn| {
                        if (btn.hover)
                            hover_view = idx;
                    };
            };
        if (hover_view) |view| {
            self.move_tab_to_view(view, dragging);
            self.update();
        }
    }

    pub fn handle_resize(self: *Self, pos: Widget.Box) void {
        self.splits_list_widget.resize(pos);
        self.plane = self.splits_list.plane;
    }

    pub fn get(self: *const Self, name: []const u8) ?*const Widget {
        return self.splits_list_widget.get(name);
    }

    pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, self_w: *Widget) bool {
        for (self.tabs) |*tab| {
            const clipped, _ = self.is_tab_clipped(tab);
            if (!clipped)
                if (tab.widget.walk(ctx, f)) return true;
        }
        return f(ctx, self_w);
    }

    pub fn hover(self: *Self) bool {
        return self.splits_list_widget.hover();
    }

    fn update_tabs(self: *Self, drag_source: ?*Widget) !void {
        const buffers_changed = try self.update_tab_buffers();
        const dragging = for (self.tabs) |*tab| {
            if (tab.widget.dynamic_cast(Tab.ButtonType)) |btn|
                if (btn.drag_pos) |_| break true;
        } else false;
        if (!dragging and !buffers_changed and self.splits_list.widgets.items.len > 0) return;
        try self.update_tab_widgets(drag_source);
    }

    fn update_tab_widgets(self: *Self, drag_source: ?*Widget) !void {
        const mv = tui.mainview() orelse @panic("tabs no main view");
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        var prev_widget_count: usize = 0;

        for (self.splits_list.widgets.items) |*split_widgetstate| if (split_widgetstate.widget.dynamic_cast(WidgetList)) |split| {
            prev_widget_count += 1;
            for (split.widgets.items) |_| prev_widget_count += 1;
        };

        for (self.splits_list.widgets.items) |*split_widget| if (split_widget.widget.dynamic_cast(WidgetList)) |split| {
            for (split.widgets.items) |*widget|
                if (&widget.widget == drag_source) tui.reset_drag_context();
        };
        while (self.splits_list.pop()) |split_widget| if (split_widget.dynamic_cast(WidgetList)) |split| {
            while (split.pop()) |widget| if (widget.dynamic_cast(Tab.ButtonType) == null)
                widget.deinit(self.splits_list.allocator);
            split.deinit(self.splits_list.allocator);
        };

        for (self.tabs) |*tab| if (buffer_manager.buffer_from_ref(tab.buffer_ref)) |buffer| {
            tab.view = buffer.get_last_view() orelse 0;
        };

        const views = mv.get_view_count();

        var widget_count: usize = 0;
        for (0..views) |view| {
            var first = true;
            var view_widget_list = try WidgetList.createH(self.allocator, self.splits_list.plane, "split", .dynamic);
            try self.splits_list.add(view_widget_list.widget());
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
                    if (buffer_manager.buffer_from_ref(tab.buffer_ref)) |buffer| {
                        try btn.update_label(Tab.name_from_buffer(buffer));
                        btn.opts.ctx.view = buffer.get_last_view() orelse 0;
                    }
                }
            }
            try view_widget_list.add(try self.make_drop_target(view));
        }
        if (prev_widget_count != widget_count)
            tui.refresh_hover(@src());
    }

    fn update_tab_buffers(self: *Self) !bool {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffers = try buffer_manager.list_unordered(self.allocator);
        defer self.allocator.free(buffers);
        const existing_tabs = self.tabs;
        defer self.allocator.free(existing_tabs);
        var result: std.ArrayListUnmanaged(TabBarTab) = .{};
        errdefer result.deinit(self.allocator);

        // add existing tabs in original order if they still exist
        outer: for (existing_tabs) |*existing_tab|
            for (buffers) |buffer| if (existing_tab.buffer_ref == buffer.to_ref()) {
                existing_tab.view = buffer.get_last_view();
                if (!buffer.hidden)
                    (try result.addOne(self.allocator)).* = existing_tab.*;
                continue :outer;
            };

        // add new tabs
        outer: for (buffers) |buffer| {
            for (result.items) |result_tab| if (result_tab.buffer_ref == buffer.to_ref())
                continue :outer;
            if (!buffer.hidden)
                try self.place_new_tab(&result, buffer);
        }

        self.tabs = try result.toOwnedSlice(self.allocator);

        if (existing_tabs.len != self.tabs.len)
            return true;
        for (existing_tabs, self.tabs) |tab_a, tab_b| {
            if (tab_a.buffer_ref == tab_b.buffer_ref and
                tab_a.view == tab_b.view)
                continue;
            return true;
        }
        return false;
    }

    fn place_new_tab(self: *Self, result: *std.ArrayListUnmanaged(TabBarTab), buffer: *Buffer) !void {
        const buffer_ref = buffer.to_ref();
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

    fn make_drop_target(self: *@This(), view: usize) !Widget {
        return drop_target.create(self, view);
    }

    fn find_buffer_tab(self: *Self, buffer_ref: Buffer.Ref) struct { ?usize, usize } {
        for (self.tabs, 0..) |*tab, idx|
            if (tab.widget.dynamic_cast(Tab.ButtonType)) |btn|
                if (btn.opts.ctx.buffer_ref == buffer_ref) return .{ idx, btn.opts.ctx.view };
        return .{ null, 0 };
    }

    fn find_first_tab_buffer(self: *Self) ?Buffer.Ref {
        for (self.splits_list.widgets.items) |*split_widget| if (split_widget.widget.dynamic_cast(WidgetList)) |split|
            for (split.widgets.items) |*widget_state| if (widget_state.widget.dynamic_cast(Tab.ButtonType)) |btn|
                return btn.opts.ctx.buffer_ref;
        return null;
    }

    fn find_last_tab_buffer(self: *Self) ?Buffer.Ref {
        var last: ?Buffer.Ref = null;
        for (self.splits_list.widgets.items) |*split_widget| if (split_widget.widget.dynamic_cast(WidgetList)) |split|
            for (split.widgets.items) |*widget_state| if (widget_state.widget.dynamic_cast(Tab.ButtonType)) |btn| {
                last = btn.opts.ctx.buffer_ref;
            };
        return last;
    }

    fn find_next_tab_buffer(self: *Self) struct { ?Buffer.Ref, usize } {
        var found_active: bool = false;
        for (self.splits_list.widgets.items) |*split_widget| if (split_widget.widget.dynamic_cast(WidgetList)) |split|
            for (split.widgets.items) |*widget_state| if (widget_state.widget.dynamic_cast(Tab.ButtonType)) |btn| {
                if (found_active)
                    return .{ btn.opts.ctx.buffer_ref, btn.opts.ctx.view };
                if (btn.opts.ctx.buffer_ref == self.active_focused_buffer_ref)
                    found_active = true;
            };
        return .{ null, 0 };
    }

    fn find_previous_tab_buffer(self: *Self) struct { ?Buffer.Ref, usize } {
        var previous: ?Buffer.Ref = null;
        var previous_view: usize = 0;
        for (self.splits_list.widgets.items) |*split_widget| if (split_widget.widget.dynamic_cast(WidgetList)) |split|
            for (split.widgets.items) |*widget_state| if (widget_state.widget.dynamic_cast(Tab.ButtonType)) |btn| {
                if (btn.opts.ctx.buffer_ref == self.active_focused_buffer_ref)
                    return .{ previous, previous_view };
                previous = btn.opts.ctx.buffer_ref;
                previous_view = btn.opts.ctx.view;
            };
        return .{ null, 0 };
    }

    fn select_next_tab(self: *Self) void {
        tp.trace(tp.channel.debug, .{"select_next_tab"});
        const buffer_ref, _ = self.find_next_tab_buffer();
        if (buffer_ref) |ref| return navigate_to_buffer(ref);
        if (self.find_first_tab_buffer()) |ref| return navigate_to_buffer(ref);
    }

    fn select_previous_tab(self: *Self) void {
        tp.trace(tp.channel.debug, .{"select_previous_tab"});
        const buffer_ref, _ = self.find_previous_tab_buffer();
        if (buffer_ref) |ref| return navigate_to_buffer(ref);
        if (self.find_last_tab_buffer()) |ref| return navigate_to_buffer(ref);
    }

    fn move_tab_next(self: *Self) void {
        tp.trace(tp.channel.debug, .{"move_tab_next"});
        const this_idx_, const this_view = self.find_buffer_tab(self.active_focused_buffer_ref orelse return);
        const this_idx = this_idx_ orelse return;
        const other_buffer_ref_, const other_view = self.find_next_tab_buffer();
        const other_buffer_ref = other_buffer_ref_ orelse return self.move_tab_to_new_split(this_idx, this_view);
        if (other_view -| this_view > 1) return self.move_tab_to_view(this_view + 1, this_idx);
        const other_idx, _ = self.find_buffer_tab(other_buffer_ref);
        if (other_idx) |idx| self.move_tab_to(idx, this_idx);
    }

    fn move_tab_previous(self: *Self) void {
        tp.trace(tp.channel.debug, .{"move_tab_previous"});
        const this_idx_, const this_view = self.find_buffer_tab(self.active_focused_buffer_ref orelse return);
        const this_idx = this_idx_ orelse return;
        const other_buffer_ref_, const other_view = self.find_previous_tab_buffer();
        const other_buffer_ref = other_buffer_ref_ orelse return;
        if (this_view -| other_view > 1) return self.move_tab_to_view(this_view -| 1, this_idx);
        const other_idx, _ = self.find_buffer_tab(other_buffer_ref);
        if (other_idx) |idx| self.move_tab_to(idx, this_idx);
    }

    fn move_tab_to(self: *Self, dst_idx: usize, src_idx: usize) void {
        if (dst_idx == src_idx) return;
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const mv = tui.mainview() orelse return;

        var tabs: std.ArrayListUnmanaged(TabBarTab) = .fromOwnedSlice(self.tabs);
        defer self.tabs = tabs.toOwnedSlice(self.allocator) catch @panic("OOM move_tab_to");

        const old_view = tabs.items[src_idx].view;
        const new_view = tabs.items[dst_idx].view;

        var src_tab = tabs.orderedRemove(src_idx);
        src_tab.view = new_view;
        const buffer = buffer_manager.buffer_from_ref(src_tab.buffer_ref);
        const active = if (buffer) |buf| if (mv.get_editor_for_buffer(buf)) |_| true else false else false;

        if (new_view == old_view) {
            tabs.insert(self.allocator, dst_idx, src_tab) catch @panic("OOM move_tab_to");
        } else {
            if (new_view orelse 0 < old_view orelse 0)
                tabs.append(self.allocator, src_tab) catch @panic("OOM move_tab_to")
            else
                tabs.insert(self.allocator, 0, src_tab) catch @panic("OOM move_tab_to");
            if (buffer) |buf| {
                buf.set_last_view(new_view);
                if (mv.get_editor_for_buffer(buf)) |editor|
                    editor.close_editor() catch {};
            }
        }

        const drag_source, _ = tui.get_drag_source();
        self.update_tab_widgets(drag_source) catch {};
        if (active)
            navigate_to_buffer(src_tab.buffer_ref);
    }

    fn move_tab_to_view(self: *Self, new_view: usize, src_idx: usize) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const mv = tui.mainview() orelse return;

        var tabs: std.ArrayListUnmanaged(TabBarTab) = .fromOwnedSlice(self.tabs);
        defer self.tabs = tabs.toOwnedSlice(self.allocator) catch @panic("OOM move_tab_to_view");

        const old_view = tabs.items[src_idx].view;

        var src_tab = &tabs.items[src_idx];
        const src_buffer_ref = src_tab.buffer_ref;
        src_tab.view = new_view;

        tabs.append(self.allocator, tabs.orderedRemove(src_idx)) catch @panic("OOM move_tab_to_view");

        const buffer = buffer_manager.buffer_from_ref(src_buffer_ref);
        const active = if (buffer) |buf| if (mv.get_editor_for_buffer(buf)) |_| true else false else false;

        if (new_view != old_view) {
            if (buffer) |buf| {
                buf.set_last_view(new_view);
                if (mv.get_editor_for_buffer(buf)) |editor|
                    editor.close_editor() catch {};
            }
        }

        const drag_source, _ = tui.get_drag_source();
        self.update_tab_widgets(drag_source) catch {};
        if (active and new_view != old_view)
            navigate_to_buffer(src_tab.buffer_ref);
    }

    fn move_tab_to_new_split(self: *Self, src_idx: usize, src_view: usize) void {
        const mv = tui.mainview() orelse return;
        var tabs_in_view: usize = 0;
        for (self.tabs) |*tab| if (tab.view) |view| {
            if (view == src_view)
                tabs_in_view += 1;
        };
        if (tabs_in_view > 1) {
            const view = mv.get_view_count();
            if (view -| src_view > 1) {
                self.move_tab_to_view(src_view + 1, src_idx);
            } else {
                mv.create_home_split() catch return;
                self.move_tab_to_view(view, src_idx);
            }
        }
    }

    fn place_next_tab(self: *Self, position: enum { before, after }, buffer_ref: Buffer.Ref) void {
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
        return navigate_to_buffer(tab.buffer_ref);
    }

    fn navigate_to_buffer(buffer_ref: Buffer.Ref) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        if (buffer_manager.buffer_from_ref(buffer_ref)) |buffer|
            tp.self_pid().send(.{ "cmd", "navigate", .{ .file = buffer.get_file_path() } }) catch {};
    }

    pub fn write_state(self: *const Self, writer: *std.Io.Writer) error{WriteFailed}!void {
        try cbor.writeArrayHeader(writer, self.tabs.len);
        for (self.tabs) |tab| try cbor.writeValue(writer, ref_to_name(tab.buffer_ref));
    }

    fn ref_to_name(buffer_ref: Buffer.Ref) ?[]const u8 {
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

    fn name_to_ref_and_view(buffer_name: []const u8) struct { ?Buffer.Ref, ?usize } {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        return if (buffer_manager.get_buffer_for_file(buffer_name)) |buffer|
            .{ buffer.to_ref(), buffer.get_last_view() }
        else
            .{ null, null };
    }
};

const Tab = struct {
    tabbar: *TabBar,
    buffer_ref: Buffer.Ref,
    view: usize,
    tab_style: *const Style,
    close_pos: ?i32 = null,
    save_pos: ?i32 = null,
    on_event: ?EventHandler = null,

    const Mode = enum { active, inactive, selected };

    const ButtonType = Button.Options(@This()).ButtonType;

    fn create(
        tabbar: *TabBar,
        buffer_ref: Buffer.Ref,
        tab_style: *const Style,
    ) !Widget {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffer = buffer_manager.buffer_from_ref(buffer_ref);
        return Button.create_widget(Tab, tabbar.allocator, tabbar.splits_list.plane, .{
            .ctx = .{ .tabbar = tabbar, .buffer_ref = buffer_ref, .view = if (buffer) |buf| buf.get_last_view() orelse 0 else 0, .tab_style = tab_style },
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

    fn is_active(self: *@This()) bool {
        const mv = tui.mainview() orelse @panic("tabs no main view");
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffer = buffer_manager.buffer_from_ref(self.buffer_ref) orelse return false;
        return if (mv.get_editor_for_buffer(buffer)) |_| true else false;
    }

    fn is_focused(self: *@This()) bool {
        const mv = tui.mainview() orelse @panic("tabs no main view");
        return self.view == mv.get_active_view();
    }

    fn render(self: *@This(), btn: *ButtonType, theme: *const Widget.Theme) bool {
        if (btn.drag_pos) |pos| {
            self.render_dragging(&btn.plane, theme);
            const anchor: Widget.Pos = btn.drag_anchor orelse .{};
            var box = Widget.Box.from(btn.plane);
            box.y = @intCast(@max(pos.y, anchor.y) - anchor.y);
            box.x = @intCast(@max(pos.x, anchor.x) - anchor.x);
            if (tui.top_layer(box.to_layer())) |top_layer| {
                self.render_selected(top_layer, btn.opts.label, false, theme, self.is_active());
            }
        } else {
            const active = self.is_active();
            const mode: Mode = if (btn.hover) .selected else if (active) .active else .inactive;
            switch (mode) {
                .selected => self.render_selected(&btn.plane, btn.opts.label, btn.hover, theme, active),
                .active => if (self.is_focused())
                    self.render_active(&btn.plane, btn.opts.label, btn.hover, theme)
                else
                    self.render_unfocused_active(&btn.plane, btn.opts.label, btn.hover, theme),
                .inactive => if (self.is_focused())
                    self.render_inactive(&btn.plane, btn.opts.label, btn.hover, theme)
                else
                    self.render_unfocused_inactive(&btn.plane, btn.opts.label, btn.hover, theme),
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

    fn render_unfocused_active(self: *@This(), plane: *Plane, label: []const u8, hover: bool, theme: *const Widget.Theme) void {
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
        _ = plane.putstr(self.tab_style.unfocused_active_left) catch {};

        plane.set_style(.{
            .fg = self.tab_style.unfocused_active_fg.from_theme(theme),
            .bg = self.tab_style.active_bg.from_theme(theme),
        });
        self.render_content(plane, label, hover, self.tab_style.unfocused_active_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = self.tab_style.active_right_fg.from_theme(theme),
            .bg = self.tab_style.active_right_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.unfocused_active_right) catch {};
    }

    fn render_unfocused_inactive(self: *@This(), plane: *Plane, label: []const u8, hover: bool, theme: *const Widget.Theme) void {
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
        _ = plane.putstr(self.tab_style.unfocused_inactive_left) catch {};

        plane.set_style(.{
            .fg = self.tab_style.inactive_fg.from_theme(theme),
            .bg = self.tab_style.inactive_bg.from_theme(theme),
        });
        self.render_content(plane, label, hover, self.tab_style.unfocused_inactive_fg.from_theme(theme), theme);

        plane.set_style(.{
            .fg = self.tab_style.inactive_right_fg.from_theme(theme),
            .bg = self.tab_style.inactive_right_bg.from_theme(theme),
        });
        _ = plane.putstr(self.tab_style.unfocused_inactive_right) catch {};
    }

    fn render_content(self: *@This(), plane: *Plane, label: []const u8, hover: bool, fg: ?Widget.Theme.Color, theme: *const Widget.Theme) void {
        const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
        const buffer_ = buffer_manager.buffer_from_ref(self.buffer_ref);
        const is_dirty = if (buffer_) |buffer| buffer.is_dirty() else false;
        const auto_save = if (buffer_) |buffer| if (buffer.is_auto_save()) switch (tui.config().auto_save_mode) {
            .on_input_idle, .on_document_change => true,
            .on_focus_change => false,
        } else false else false;
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
        const active = self.is_active();
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
};

const drop_target = struct {
    tabbar: *TabBar,
    view: usize,
    on_event: ?EventHandler = null,

    const ButtonType = Button.Options(@This()).ButtonType;

    fn create(
        tabbar: *TabBar,
        view: usize,
    ) !Widget {
        return Button.create_widget(@This(), tabbar.allocator, tabbar.splits_list.plane, .{
            .ctx = .{ .tabbar = tabbar, .view = view },
            .label = &.{},
            .on_layout = @This().layout,
            .on_render = @This().render,
            .on_event = EventHandler.bind(tabbar, TabBar.handle_event),
            .cursor = .default,
        });
    }

    fn render(self: *@This(), btn: *ButtonType, theme: *const Widget.Theme) bool {
        _ = self;
        _ = btn;
        _ = theme;
        return false;
    }

    fn layout(_: *@This(), _: *ButtonType) Widget.Layout {
        return .dynamic;
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
    unfocused_active_bg,
    unfocused_active_fg,
    unfocused_inactive_bg,
    unfocused_inactive_fg,

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
            .unfocused_active_bg => theme.tab_unfocused_active.bg,
            .unfocused_active_fg => theme.tab_unfocused_active.fg,
            .unfocused_inactive_bg => theme.tab_unfocused_inactive.bg,
            .unfocused_inactive_fg => theme.tab_unfocused_inactive.fg,
            .Error => theme.editor_error.fg,
            .Warning => theme.editor_warning.fg,
            .Information => theme.editor_information.fg,
            .Hint => theme.editor_hint.fg,
        };
    }
};
