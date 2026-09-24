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
pub const Indicator = tab_render.Indicator;

pub const TabInfo = struct {
    id: Id,
    label: []const u8,
    icon: []const u8 = "",
    active: bool,
    indicator: Indicator = .clean,
};

pub const Source = struct {
    ctx: *anyopaque,
    count: *const fn (ctx: *anyopaque) usize,
    info: *const fn (ctx: *anyopaque, n: usize) TabInfo,
    focused: *const fn (ctx: *anyopaque) bool,
    on_select: *const fn (ctx: *anyopaque, id: Id) void,
    on_close: *const fn (ctx: *anyopaque, id: Id) void,
    on_menu: *const fn (ctx: *anyopaque) void,
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
        h.update(std.mem.asBytes(&t.indicator));
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
    if (MenuButton.create(self.allocator, self.list.plane, self) catch null) |m| blk: {
        var spacer = Widget.empty(self.allocator, self.list.plane, .dynamic) catch {
            m.deinit(self.allocator);
            break :blk;
        };
        self.list.add(spacer) catch spacer.deinit(self.allocator);
        self.list.add(m) catch m.deinit(self.allocator);
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
        }, .{ .icon = icon(info), .label = info.label, .indicator = info.indicator });
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
        return .{ .static = len + tab_render.chrome_width(plane, s, info.active, indicator_width(plane, s)) };
    }

    fn icon(info: TabInfo) []const u8 {
        return if (tui.config().show_fileicons) info.icon else "";
    }

    fn indicator_width(plane: Plane, s: *const Tabs.Style) usize {
        var width = plane.egc_chunk_width(s.close_icon, 0, 1);
        for (std.enums.values(Indicator)) |indicator|
            width = @max(width, plane.egc_chunk_width(tab_render.indicator_glyph(s, indicator).glyph, 0, 1));
        return width;
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

const MenuButton = struct {
    strip: *Self,

    const ButtonType = Button.Options(@This()).ButtonType;

    pub fn create(allocator: Allocator, parent: Plane, strip: *Self) error{OutOfMemory}!Widget {
        return Button.create_widget(@This(), allocator, parent, .{
            .ctx = .{ .strip = strip },
            .label = " ≡ ",
            .on_click = on_click,
            .on_layout = layout,
            .on_render = render,
        });
    }

    fn on_click(m: *@This(), _: *ButtonType, _: Widget.Pos) void {
        const src = m.strip.source;
        src.on_menu(src.ctx);
    }

    pub fn layout(_: *@This(), _: *ButtonType) Widget.Layout {
        return .{ .static = 3 };
    }

    pub fn render(_: *@This(), btn: *ButtonType, theme: *const Widget.Theme) bool {
        btn.plane.set_base_style(theme.editor);
        btn.plane.erase();
        btn.plane.home();
        btn.plane.set_style(if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.tab_inactive);
        btn.plane.fill(" ");
        btn.plane.home();
        _ = btn.plane.putstr(btn.opts.label) catch {};
        return false;
    }
};
