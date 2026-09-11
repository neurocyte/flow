const std = @import("std");
const Allocator = std.mem.Allocator;

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Button = @import("Button.zig");
const Tabs = @import("status/tabs.zig");
const tab_render = @import("tab_render.zig");

pub const Id = @import("Panel.zig").Id;

pub const TabInfo = struct {
    id: Id,
    label: []const u8,
    icon: []const u8 = "",
    active: bool,
};

pub const Source = struct {
    ctx: *anyopaque,
    count: *const fn (ctx: *anyopaque) usize,
    info: *const fn (ctx: *anyopaque, n: usize) TabInfo,
    focused: *const fn (ctx: *anyopaque) bool,
    on_select: *const fn (ctx: *anyopaque, id: Id) void,
    on_close: *const fn (ctx: *anyopaque, id: Id) void,
};

const Self = @This();

allocator: Allocator,
list: *WidgetList,
source: Source,
style: *const Tabs.Style,
hash: u64 = 0,

pub fn init(self: *Self, allocator: Allocator, parent: Plane, style: *const Tabs.Style, source: Source) error{OutOfMemory}!void {
    const list = try WidgetList.createH(allocator, parent, "tab_strip", .{ .static = 1 });
    self.* = .{
        .allocator = allocator,
        .list = list,
        .source = source,
        .style = style,
    };
    list.ctx = self;
    list.on_render = render_bar;
    list.render_decoration = null;
}

pub fn widget(self: *Self) Widget {
    return self.list.widget();
}

pub fn sync(self: *Self) void {
    const hash = self.hash_tabs();
    if (hash == self.hash) return;
    self.hash = hash;
    self.rebuild();
}

fn hash_tabs(self: *Self) u64 {
    var h = std.hash.Wyhash.init(0);
    const n = self.source.count(self.source.ctx);
    for (0..n) |i| {
        const t = self.source.info(self.source.ctx, i);
        h.update(std.mem.asBytes(&t.id));
        h.update(std.mem.asBytes(&t.active));
        h.update(t.icon);
        h.update(&[_]u8{0});
        h.update(t.label);
        h.update(&[_]u8{0});
    }
    return h.final();
}

fn rebuild(self: *Self) void {
    self.list.remove_all();
    const n = self.source.count(self.source.ctx);
    for (0..n) |i| {
        const t = self.source.info(self.source.ctx, i);
        const w = Button.create_widget(Tab, self.allocator, self.list.plane, .{
            .ctx = .{ .strip = self, .id = t.id },
            .label = t.label,
            .on_click = Tab.on_click,
            .on_click2 = Tab.on_click2,
            .on_render = Tab.render,
            .on_layout = Tab.layout,
        }) catch continue;
        self.list.add(w) catch {
            w.deinit(self.allocator);
            continue;
        };
    }
    self.list.resize(self.list.deco_box);
    tui.refresh_hover(@src());
}

fn find(self: *Self, id: Id) ?TabInfo {
    const n = self.source.count(self.source.ctx);
    for (0..n) |i| {
        const t = self.source.info(self.source.ctx, i);
        if (t.id == id) return t;
    }
    return null;
}

fn render_bar(ctx: ?*anyopaque, theme: *const Widget.Theme) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    const plane = &self.list.plane;
    plane.set_base_style(theme.editor);
    plane.erase();
    plane.home();
    plane.set_style(.{
        .fg = self.style.bar_fg.from_theme(theme),
        .bg = self.style.bar_bg.from_theme(theme),
    });
    plane.fill(" ");
    plane.home();
}

const Tab = struct {
    strip: *Self,
    id: Id,
    close_pos: ?i32 = null,

    const ButtonType = Button.Options(Tab).ButtonType;

    fn render(t: *Tab, btn: *ButtonType, theme: *const Widget.Theme) bool {
        const info = t.strip.find(t.id) orelse return false;
        const hit = tab_render.render(&btn.plane, t.strip.style, theme, .{
            .hover = btn.hover,
            .active = info.active,
            .focused = t.strip.source.focused(t.strip.source.ctx),
        }, .{ .icon = icon(info), .label = info.label });
        t.close_pos = hit.close_pos;
        return false;
    }

    fn layout(t: *Tab, btn: *ButtonType) Widget.Layout {
        const info = t.strip.find(t.id) orelse return .{ .static = 0 };
        const s = t.strip.style;
        const plane = btn.plane;
        const icon_ = icon(info);
        const len_icon = if (icon_.len > 0) plane.egc_chunk_width(icon_, 0, 1) + 2 else 0;
        const len = plane.egc_chunk_width(info.label, 0, 1) + len_icon;
        const len_indicator = @max(
            plane.egc_chunk_width(s.close_icon, 0, 1),
            plane.egc_chunk_width(s.clean_indicator, 0, 1),
        );
        return .{ .static = len + tab_render.chrome_width(plane, s, info.active, len_indicator) };
    }

    fn icon(info: TabInfo) []const u8 {
        return if (tui.config().show_fileicons) info.icon else "";
    }

    fn on_click(t: *Tab, _: *ButtonType, pos: Widget.Pos) void {
        const src = t.strip.source;
        if (t.close_pos) |close_pos| if (pos.x == close_pos)
            return src.on_close(src.ctx, t.id);
        src.on_select(src.ctx, t.id);
    }

    fn on_click2(t: *Tab, _: *ButtonType, _: Widget.Pos) void {
        const src = t.strip.source;
        src.on_close(src.ctx, t.id);
    }
};
