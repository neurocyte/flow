const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("soft_root").root;
const command = @import("command");
const cbor = @import("cbor");
const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const PanelGroup = @import("PanelGroup.zig");
const Panel = @import("Panel.zig");
const Tabs = @import("status/tabs.zig");

const Self = @This();

pub const Location = enum { bottom };
pub const ToggleMode = enum { toggle, enable, disable };
pub const GroupDirection = enum { left, right };
pub const RemoveFocus = enum { never, if_focused, always };
pub const RestoreFn = *const fn (allocator: Allocator, parent: Plane, tag: []const u8, state: []const u8) ?Panel;

pub const Found = struct {
    group: *PanelGroup,
    panel: Panel,
};

pub const Target = enum { focused_group, new_group };

pub const OpenOptions = struct {
    target: Target = .focused_group,
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
current: std.StringHashMapUnmanaged(Panel) = .empty, // by panel tag
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
    return self.add_group_at(self.groups.items.len);
}

fn add_group_at(self: *Self, n: usize) error{OutOfMemory}!*PanelGroup {
    const g = try PanelGroup.create(self.allocator, self.list.plane, .panel, &self.tab_style);
    errdefer g.widget().deinit(self.allocator);
    g.on_focus = .{ .ctx = self, .f = note_focused };
    g.on_activate = .{ .ctx = self, .f = note_activated };
    try self.groups.insert(self.allocator, n, g);
    errdefer _ = self.groups.orderedRemove(n);
    try self.list.insert(n, g.widget());
    return g;
}

fn group_index(self: *const Self, g: *PanelGroup) ?usize {
    for (self.groups.items, 0..) |g_, i| if (g_ == g) return i;
    return null;
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
    if (want) |w| if (cur) |c| if (w.panel.id == c.id) return;
    if (cur) |c| {
        c.set_current(false);
        _ = self.current.remove(tag);
    }
    if (want) |w| {
        self.current.put(self.allocator, tag, w.panel) catch return;
        w.panel.set_current(true);
    }
}

pub fn current_of(self: *Self, comptime V: type) ?*V {
    const panel = self.current.get(V.panel_tag) orelse return null;
    const f = self.find_by_id(panel.id) orelse return null;
    return f.panel.cast(V);
}

fn is_group(self: *const Self, g: *PanelGroup) bool {
    return self.group_index(g) != null;
}

pub fn focused_group(self: *Self) ?*PanelGroup {
    for (self.groups.items) |g| if (g.is_focused()) return g;
    if (self.last_focused) |g| if (self.is_group(g)) return g;
    return if (self.groups.items.len > 0) self.groups.items[0] else null;
}

fn target_group(self: *Self) error{OutOfMemory}!*PanelGroup {
    return self.focused_group() orelse self.add_group();
}

fn new_group_after(self: *Self, g: *PanelGroup) error{OutOfMemory}!*PanelGroup {
    return self.add_group_at((self.group_index(g) orelse self.groups.items.len) + 1);
}

fn group_for(self: *Self, target: Target) error{OutOfMemory}!*PanelGroup {
    return switch (target) {
        .focused_group => self.target_group(),
        .new_group => if (self.focused_group()) |g| self.new_group_after(g) else self.add_group(),
    };
}

pub fn create_panel(self: *Self, comptime V: type, args: anytype, opts: OpenOptions) !*V {
    const group = try self.group_for(opts.target);
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
    self.remove(f, .always);
}

pub fn remove(self: *Self, f: Found, focus_mode: RemoveFocus) void {
    const was_focused = tui.is_keyboard_focus(f.panel.impl);
    const tag = f.panel.tag();
    self.mru_remove(f.panel.id);
    if (self.current.get(tag)) |c| if (c.id == f.panel.id) {
        f.panel.set_current(false);
        _ = self.current.remove(tag);
    };
    f.group.remove(f.panel.id);
    self.update_current(tag);
    var next: ?*PanelGroup = f.group;
    if (f.group.empty()) {
        const i = self.group_index(f.group) orelse 0;
        self.remove_group(f.group);
        const n = self.groups.items.len;
        next = if (i < n) self.groups.items[i] else if (n > 0) self.groups.items[n - 1] else null;
    }
    const focus = switch (focus_mode) {
        .never => false,
        .if_focused => was_focused,
        .always => true,
    };
    if (focus) if (next) |g| {
        self.last_focused = g;
        self.show();
        self.focus_active();
    };
    tui.need_render(@src());
}

pub fn focus_active(self: *Self) void {
    const g = self.focused_group() orelse return;
    const p = g.active() orelse return;
    self.last_focused = g;
    p.widget.focus();
    self.touch(p.id);
}

pub fn close_active(self: *Self) void {
    const g = self.focused_group() orelse return;
    const p = g.active() orelse return;
    self.close(p.id);
}

fn move_panel(self: *Self, f: Found, to: *PanelGroup) void {
    const was_focused = tui.is_keyboard_focus(f.panel.impl);
    const panel = f.group.detach(f.panel.id) orelse return;
    to.add(panel, true) catch {
        f.group.add(panel, true) catch panel.widget.deinit(self.allocator);
        return;
    };
    if (f.group.empty()) self.remove_group(f.group);
    self.last_focused = to;
    tui.resize();
    if (was_focused) panel.widget.focus();
}

pub fn move_to_new_group(self: *Self, f: Found) error{OutOfMemory}!void {
    if (f.group.count() < 2) return;
    self.move_panel(f, try self.new_group_after(f.group));
}

pub fn split(self: *Self) error{OutOfMemory}!void {
    const g = self.focused_group() orelse return;
    const p = g.active() orelse return;
    try self.move_to_new_group(.{ .group = g, .panel = p });
    self.show();
}

pub fn move_active(self: *Self, dir: GroupDirection) error{OutOfMemory}!void {
    const g = self.focused_group() orelse return;
    const p = g.active() orelse return;
    const i = self.group_index(g) orelse return;
    const n = self.groups.items.len;
    const to = switch (dir) {
        .left => if (i > 0) self.groups.items[i - 1] else if (g.count() > 1) try self.add_group_at(0) else return,
        .right => if (i + 1 < n) self.groups.items[i + 1] else if (g.count() > 1) try self.add_group_at(n) else return,
    };
    self.move_panel(.{ .group = g, .panel = p }, to);
    self.show();
}

pub fn focus_group(self: *Self, dir: GroupDirection) void {
    const g = self.focused_group() orelse return;
    const i = self.group_index(g) orelse return;
    const j = switch (dir) {
        .left => if (i > 0) i - 1 else return,
        .right => if (i + 1 < self.groups.items.len) i + 1 else return,
    };
    const to = self.groups.items[j];
    // not every panel takes keyboard focus
    if (g.is_focused()) tui.clear_keyboard_focus();
    self.last_focused = to;
    self.show();
    if (to.active()) |p| {
        p.widget.focus();
        self.touch(p.id);
    }
    tui.need_render(@src());
}

fn find_by_tag(self: *const Self, tag: []const u8) ?Found {
    for (self.groups.items) |g| for (g.panels.items) |p| if (std.mem.eql(u8, p.tag(), tag))
        return .{ .group = g, .panel = p };
    return null;
}

fn persistable(p: Panel) bool {
    return p.vtable.write_state != null or p.singleton();
}

fn persistable_count(g: *const PanelGroup) usize {
    var n: usize = 0;
    for (g.panels.items) |p| if (persistable(p)) {
        n += 1;
    };
    return n;
}

// [location, visible, maximized, focused_group, groups: [[active_index, tabs: [[tag, state]]]]]
pub fn write_state(self: *Self, writer: *std.Io.Writer) error{WriteFailed}!void {
    var n_groups: usize = 0;
    var focused: ?usize = null;
    for (self.groups.items) |g| if (persistable_count(g) > 0) {
        if (self.last_focused == g) focused = n_groups;
        n_groups += 1;
    };
    try cbor.writeArrayHeader(writer, 5);
    try cbor.writeValue(writer, @tagName(self.location));
    try cbor.writeValue(writer, self.attached);
    try cbor.writeValue(writer, self.maximized);
    try cbor.writeValue(writer, focused);
    try cbor.writeArrayHeader(writer, n_groups);
    for (self.groups.items) |g| {
        const n = persistable_count(g);
        if (n == 0) continue;
        var active: usize = 0;
        var idx: usize = 0;
        for (g.panels.items) |p| if (persistable(p)) {
            if (g.is_active(p.id)) active = idx;
            idx += 1;
        };
        try cbor.writeArrayHeader(writer, 2);
        try cbor.writeValue(writer, active);
        try cbor.writeArrayHeader(writer, n);
        for (g.panels.items) |p| if (persistable(p)) {
            try cbor.writeArrayHeader(writer, 2);
            try cbor.writeValue(writer, p.tag());
            if (p.vtable.write_state) |write_state_| try write_state_(p.impl.ptr, writer) else try cbor.writeValue(writer, null);
        };
    }
}

fn skip_values(iter: *[]const u8, n: usize) !void {
    for (0..n) |_| try cbor.skipValue(iter);
}

pub fn restore_state(self: *Self, state: []const u8, restore_panel: RestoreFn) !void {
    var iter = state;
    const fields = try cbor.decodeArrayHeader(&iter);
    if (fields < 5) return error.InvalidPanelAreaState;
    var location: []const u8 = undefined;
    var visible_: bool = false;
    var maximized: bool = false;
    var focused: ?usize = null;
    if (!try cbor.matchValue(&iter, cbor.extract(&location)) or
        !try cbor.matchValue(&iter, cbor.extract(&visible_)) or
        !try cbor.matchValue(&iter, cbor.extract(&maximized)) or
        !try cbor.matchValue(&iter, cbor.extract(&focused)))
        return error.InvalidPanelAreaState;
    var n_groups = try cbor.decodeArrayHeader(&iter);
    var group_idx: usize = 0;
    while (n_groups > 0) : (n_groups -= 1) {
        defer group_idx += 1;
        const group_fields = try cbor.decodeArrayHeader(&iter);
        if (group_fields < 2) return error.InvalidPanelGroupState;
        var active: usize = 0;
        if (!try cbor.matchValue(&iter, cbor.extract(&active))) return error.InvalidPanelGroupState;
        var n_tabs = try cbor.decodeArrayHeader(&iter);
        var group: ?*PanelGroup = null;
        var tab_idx: usize = 0;
        while (n_tabs > 0) : (n_tabs -= 1) {
            defer tab_idx += 1;
            const tab_fields = try cbor.decodeArrayHeader(&iter);
            if (tab_fields < 2) return error.InvalidPanelTabState;
            var tag: []const u8 = undefined;
            var panel_state: []const u8 = undefined;
            if (!try cbor.matchValue(&iter, cbor.extract(&tag)) or
                !try cbor.matchValue(&iter, cbor.extract_cbor(&panel_state)))
                return error.InvalidPanelTabState;
            try skip_values(&iter, tab_fields - 2);
            const g = group orelse try self.add_group();
            group = g;
            const panel = restore_panel(self.allocator, g.panel_parent(), tag, panel_state) orelse continue;
            if (panel.singleton() and self.find_by_tag(panel.tag()) != null) {
                panel.widget.deinit(self.allocator);
                continue;
            }
            self.add(g, panel, .{ .activate = tab_idx == active, .show = false }) catch {
                panel.widget.deinit(self.allocator);
                continue;
            };
        }
        try skip_values(&iter, group_fields - 2);
        if (group) |g| {
            if (g.empty())
                self.remove_group(g)
            else if (focused == group_idx)
                self.last_focused = g;
        }
    }
    try skip_values(&iter, fields - 5);
    self.maximized = maximized;
    if (visible_) {
        self.show();
        if (self.maximized) self.focus_active();
    }
}

pub fn cycle_tab(self: *Self, dir: PanelGroup.Direction) void {
    const g = self.focused_group() orelse return;
    const was_focused = g.is_focused();
    const n_groups = self.groups.items.len;
    var gi = self.group_index(g) orelse return;
    const cur = g.deck.active_index() orelse 0;
    var ti: usize = cur;
    switch (dir) {
        .next => if (cur + 1 < g.count()) {
            ti = cur + 1;
        } else {
            gi = (gi + 1) % n_groups;
            ti = 0;
        },
        .previous => if (cur > 0) {
            ti = cur - 1;
        } else {
            gi = (gi + n_groups - 1) % n_groups;
            ti = self.groups.items[gi].count() -| 1;
        },
    }
    const target = self.groups.items[gi];
    const p = target.get_at(ti) orelse return;
    // not every panel takes keyboard focus, so drop it from the old tab first
    if (was_focused) tui.clear_keyboard_focus();
    target.activate(p.id);
    self.last_focused = target;
    self.show();
    if (was_focused) p.widget.focus();
    tui.need_render(@src());
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
        self.focus_active();
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
    self.set_maximized(self.maximized_by_snap or !self.maximized);
}

pub fn set_maximized(self: *Self, maximized: bool) void {
    if (!self.attached) {
        if (!maximized) return;
        if (!self.ensure_visible()) return;
        self.maximized = false;
    }
    const max_h = self.max_height();
    self.maximized_by_snap = false;
    if (maximized) {
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
    } else return;
    tui.resize();
    if (self.maximized) self.focus_active();
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
