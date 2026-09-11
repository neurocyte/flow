const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("soft_root").root;
const command = @import("command");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const PanelGroup = @import("PanelGroup.zig");
const Panel = @import("Panel.zig");
const Tabs = @import("status/tabs.zig");

const Self = @This();

pub const Location = enum { bottom };
pub const ToggleMode = enum { toggle, enable, disable };

pub const Found = struct {
    group: *PanelGroup,
    panel: Panel,
};

pub const OpenOptions = struct {
    group: ?*PanelGroup = null,
    activate: bool = true,
    focus: bool = false,
    show: bool = true,
};

allocator: Allocator,
location: Location,
host: *WidgetList,
list: *WidgetList,
groups: std.ArrayList(*PanelGroup) = .empty,
attached: bool = false,
last_focused: ?*PanelGroup = null,
next_id: Panel.Id = 1,
mru: std.ArrayList(Panel.Id) = .empty, // least recently used first
current: std.StringHashMapUnmanaged(Panel.Id) = .empty, // by panel tag
tab_style: Tabs.Style,
tab_style_bufs: [][]const u8,

height: ?usize = null,
maximized: bool = false,
maximized_by_snap: bool = false,
snap_height: usize = 0,

const height_ratio_max: f32 = 0.75;
const height_min_rows: usize = 3;

pub fn create(allocator: Allocator, host: *WidgetList, location: Location) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const list = try WidgetList.createH(allocator, host.plane, "panel", .{ .static = 0 });
    const tab_style, const tab_style_bufs = root.read_config(Tabs.Style, allocator);
    self.* = .{
        .allocator = allocator,
        .location = location,
        .host = host,
        .list = list,
        .tab_style = tab_style,
        .tab_style_bufs = tab_style_bufs,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.attached) _ = self.host.detach(self.list.widget());
    self.list.deinit(self.allocator);
    self.groups.deinit(self.allocator);
    self.mru.deinit(self.allocator);
    self.current.deinit(self.allocator);
    root.free_config(self.allocator, self.tab_style_bufs);
    self.allocator.destroy(self);
}

pub fn visible(self: *const Self) bool {
    return self.attached;
}

pub fn empty(self: *const Self) bool {
    return self.groups.items.len == 0;
}

pub fn show(self: *Self) void {
    if (self.attached or self.groups.items.len == 0) return;
    self.list.layout_ = .{ .static = if (self.maximized) self.max_height() else self.get_height() };
    self.host.add(self.list.widget()) catch return;
    self.attached = true;
    tui.resize();
}

pub fn hide(self: *Self) void {
    if (!self.attached) return;
    self.release_focus();
    _ = self.host.detach(self.list.widget());
    self.attached = false;
    tui.resize();
}

fn release_focus(self: *Self) void {
    for (self.groups.items) |g| if (g.is_focused()) {
        tui.clear_keyboard_focus();
        return;
    };
}

pub fn active_plane(self: *Self) ?@import("renderer").Plane {
    if (!self.attached) return null;
    if (self.focused_group()) |g| return g.list.plane;
    return self.list.plane;
}

fn add_group(self: *Self) error{OutOfMemory}!*PanelGroup {
    const g = try PanelGroup.create(self.allocator, self.list.plane, .panel, &self.tab_style);
    errdefer g.widget().deinit(self.allocator);
    g.on_focus = .{ .ctx = self, .f = note_focused };
    g.on_activate = .{ .ctx = self, .f = note_activated };
    try self.groups.append(self.allocator, g);
    errdefer _ = self.groups.pop();
    try self.list.add(g.widget());
    return g;
}

fn remove_group(self: *Self, g: *PanelGroup) void {
    for (self.groups.items, 0..) |g_, i| if (g_ == g) {
        _ = self.groups.orderedRemove(i);
        break;
    };
    if (self.last_focused == g) self.last_focused = null;
    self.list.remove(g.widget());
    if (self.groups.items.len == 0) self.hide() else tui.resize();
}

fn note_focused(ctx: *anyopaque, g: *PanelGroup) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.last_focused = g;
    if (g.active()) |p| self.touch(p.id);
}

fn note_activated(ctx: *anyopaque, g: *PanelGroup) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (g.active()) |p| self.touch(p.id);
}

fn mru_remove(self: *Self, id: Panel.Id) void {
    for (self.mru.items, 0..) |id_, i| if (id_ == id) {
        _ = self.mru.orderedRemove(i);
        return;
    };
}

fn touch(self: *Self, id: Panel.Id) void {
    if (self.mru.items.len > 0 and self.mru.items[self.mru.items.len - 1] == id) return;
    const f = self.find_by_id(id) orelse return;
    self.mru_remove(id);
    self.mru.append(self.allocator, id) catch return;
    self.update_current(f.panel.tag());
}

fn update_current(self: *Self, tag: []const u8) void {
    const want: ?Found = blk: {
        var i = self.mru.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.find_by_id(self.mru.items[i]) orelse continue;
            if (std.mem.eql(u8, f.panel.tag(), tag)) break :blk f;
        }
        break :blk null;
    };
    const cur = self.current.get(tag);
    if (want) |w| if (cur) |c| if (w.panel.id == c) return;
    if (cur) |c| {
        if (self.find_by_id(c)) |f| f.panel.set_current(false);
        _ = self.current.remove(tag);
    }
    if (want) |w| {
        self.current.put(self.allocator, tag, w.panel.id) catch return;
        w.panel.set_current(true);
    }
}

pub fn current_of(self: *Self, comptime V: type) ?*V {
    const id = self.current.get(V.panel_tag) orelse return null;
    const f = self.find_by_id(id) orelse return null;
    return f.panel.cast(V);
}

fn is_group(self: *const Self, g: *PanelGroup) bool {
    for (self.groups.items) |g_| if (g_ == g) return true;
    return false;
}

pub fn focused_group(self: *Self) ?*PanelGroup {
    for (self.groups.items) |g| if (g.is_focused()) return g;
    if (self.last_focused) |g| if (self.is_group(g)) return g;
    return if (self.groups.items.len > 0) self.groups.items[0] else null;
}

fn target_group(self: *Self) error{OutOfMemory}!*PanelGroup {
    return self.focused_group() orelse self.add_group();
}

pub fn create_panel(self: *Self, comptime V: type, args: anytype, opts: OpenOptions) !*V {
    const group = opts.group orelse try self.target_group();
    errdefer if (group.empty()) self.remove_group(group);
    const panel = try @call(.auto, V.create, .{ self.allocator, group.panel_parent() } ++ args);
    errdefer panel.widget.deinit(self.allocator);
    try self.add(group, panel, opts);
    return panel.cast(V) orelse unreachable;
}

pub fn add(self: *Self, group: *PanelGroup, panel_: Panel, opts: OpenOptions) error{OutOfMemory}!void {
    var panel = panel_;
    panel.id = self.next_id;
    self.next_id += 1;
    try group.add(panel, opts.activate);
    if (!group.is_active(panel.id)) {
        self.mru.insert(self.allocator, 0, panel.id) catch {};
        self.update_current(panel.tag());
    }
    if (opts.show) self.show();
    tui.resize();
    if (opts.focus) panel.widget.focus();
}

pub fn find_by_id(self: *const Self, id: Panel.Id) ?Found {
    for (self.groups.items) |g| if (g.find(id)) |p| return .{ .group = g, .panel = p };
    return null;
}

pub fn find_panel(self: *const Self, comptime V: type) ?Found {
    for (self.groups.items) |g| for (g.panels.items) |p| if (p.is(V))
        return .{ .group = g, .panel = p };
    return null;
}

pub fn find_first(self: *const Self, comptime V: type) ?*V {
    const f = self.find_panel(V) orelse return null;
    return f.panel.cast(V);
}

pub fn find_panel_where(self: *const Self, comptime V: type, key: anytype, comptime pred: fn (*V, @TypeOf(key)) bool) ?Found {
    for (self.groups.items) |g| for (g.panels.items) |p| if (p.is(V)) if (p.cast(V)) |v|
        if (pred(v, key)) return .{ .group = g, .panel = p };
    return null;
}

pub fn find(self: *const Self, comptime V: type, key: anytype, comptime pred: fn (*V, @TypeOf(key)) bool) ?*V {
    const f = self.find_panel_where(V, key, pred) orelse return null;
    return f.panel.cast(V);
}

pub fn has(self: *const Self, comptime V: type) bool {
    return self.find_panel(V) != null;
}

pub fn is_showing(self: *const Self, comptime V: type) bool {
    if (!self.attached) return false;
    for (self.groups.items) |g| if (g.active()) |p| if (p.is(V)) return true;
    return false;
}

pub fn toggle(self: *Self, comptime V: type, mode: ToggleMode, ctx: command.Context) !?*V {
    if (self.find_panel(V)) |f| {
        const showing = self.attached and f.group.is_active(f.panel.id);
        switch (mode) {
            .disable => {
                self.close(f.panel.id);
                return null;
            },
            .toggle => if (showing) {
                self.close(f.panel.id);
                return null;
            },
            .enable => {},
        }
        self.activate(f.panel.id);
        return f.panel.cast(V);
    }
    if (mode == .disable) return null;
    return try self.create_panel(V, .{ctx}, .{});
}

pub fn activate(self: *Self, id: Panel.Id) void {
    const f = self.find_by_id(id) orelse return;
    f.group.activate(id);
    self.show();
}

pub fn close(self: *Self, id: Panel.Id) void {
    const f = self.find_by_id(id) orelse return;
    if (f.panel.request_close() == .vetoed) return;
    self.remove(f);
}

pub fn remove(self: *Self, f: Found) void {
    const tag = f.panel.tag();
    self.mru_remove(f.panel.id);
    if (self.current.get(tag)) |c| if (c == f.panel.id) {
        f.panel.set_current(false);
        _ = self.current.remove(tag);
    };
    f.group.remove(f.panel.id);
    self.update_current(tag);
    if (f.group.empty()) self.remove_group(f.group);
    tui.need_render(@src());
}

pub fn close_active(self: *Self) void {
    const g = self.focused_group() orelse return;
    const p = g.active() orelse return;
    self.close(p.id);
}

pub fn cycle_tab(self: *Self, dir: PanelGroup.Direction) void {
    const g = self.focused_group() orelse return;
    const was_focused = g.is_focused();
    g.cycle(dir);
    if (was_focused) if (g.active()) |p| p.widget.focus();
    self.show();
}

fn total_height() usize {
    return tui.plane().dim_y();
}

fn max_height(_: *const Self) usize {
    return total_height() -| 1;
}

fn rows_for_ratio(total: usize, ratio: f32) usize {
    const h: usize = @intFromFloat(@as(f32, @floatFromInt(total)) * @min(height_ratio_max, ratio));
    const max_h = total -| 1;
    return std.math.clamp(h, @min(height_min_rows, max_h), max_h);
}

pub fn get_height(self: *const Self) usize {
    if (self.height) |h| return h;
    return rows_for_ratio(total_height(), tui.config().panel_height_ratio);
}

pub fn is_maximized(self: *const Self) bool {
    return self.maximized;
}

fn save_height_ratio(height: usize) void {
    const total = total_height();
    if (total == 0) return;
    if (rows_for_ratio(total, tui.config().panel_height_ratio) == height) return;
    const total_f: f32 = @floatFromInt(total);
    const floor = @as(f32, @floatFromInt(height_min_rows)) / total_f;
    tui.config_mut().panel_height_ratio = std.math.clamp(@as(f32, @floatFromInt(height)) / total_f, floor, height_ratio_max);
    tui.save_config() catch {};
}

fn ensure_visible(self: *Self) bool {
    if (!self.attached) {
        if (self.groups.items.len > 0)
            self.show()
        else
            command.executeName("toggle_panel", .empty()) catch return false;
    }
    return self.attached;
}

pub fn set_height_abs(self: *Self, y: usize) void {
    if (!self.ensure_visible()) return;
    if (tui.input_mode_outer() != null and tui.mini_mode() == null)
        command.executeName("exit_overlay_mode", .empty()) catch {};
    const max_h = self.max_height();
    const height = @max(1, @min(max_h, y));
    self.height = height;
    self.maximized = false;
    self.maximized_by_snap = false;
    self.list.layout_ = .{ .static = height };
    if (height == 1) {
        self.height = null;
        self.hide();
    } else if (height >= max_h) {
        self.maximized = true;
        self.list.layout_ = .{ .static = max_h };
        self.height = null;
    } else {
        save_height_ratio(height);
    }
}

pub fn set_height_rel(self: *Self, y: isize) void {
    if (!self.attached and y < 0) return;
    if (self.maximized and y > 0) return;
    const h: isize = @intCast(self.get_height());
    self.set_height_abs(@intCast(@max(1, h +| y)));
}

pub fn toggle_maximize(self: *Self) void {
    if (!self.attached) {
        if (!self.ensure_visible()) return;
        self.maximized = false;
    }
    const max_h = self.max_height();
    const was_snap = self.maximized_by_snap;
    self.maximized_by_snap = false;
    if (was_snap) {
        self.maximized = true;
        self.list.layout_ = .{ .static = max_h };
    } else if (self.maximized) {
        self.maximized = false;
        var h = self.get_height();
        if (h >= max_h) {
            h = @max(1, max_h -| 1);
            self.height = h;
        }
        self.list.layout_ = .{ .static = h };
    } else {
        self.maximized = true;
        self.list.layout_ = .{ .static = max_h };
    }
    tui.resize();
}

pub fn update_layout_for_resize(self: *Self) void {
    if (!self.attached) return;
    const max_h = self.max_height();
    if (self.maximized) {
        self.list.layout_ = .{ .static = max_h };
        if (self.maximized_by_snap and self.snap_height < max_h) {
            self.maximized = false;
            self.maximized_by_snap = false;
            self.list.layout_ = .{ .static = self.snap_height };
        }
    } else {
        const cur_h = switch (self.list.layout_) {
            .static => |s| s,
            .dynamic => self.get_height(),
        };
        if (cur_h >= max_h) {
            self.maximized = true;
            self.maximized_by_snap = true;
            self.snap_height = cur_h;
            self.list.layout_ = .{ .static = max_h };
        }
    }
}
