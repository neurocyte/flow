const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const root = @import("soft_root").root;

const Plane = @import("renderer").Plane;
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
pub const Box = @import("Box.zig");
pub const Pos = struct { y: i32 = 0, x: i32 = 0 };
pub const Theme = @import("theme");
pub const scopes = @import("themes").scopes;
pub const Type = @import("config").WidgetType;
pub const StyleTag = @import("config").WidgetStyle;
pub const Style = @import("WidgetStyle.zig");

ptr: *anyopaque,
plane: *Plane,
vtable: *const VTable,

const Self = @This();

pub const WalkFn = *const fn (ctx: *anyopaque, w: Self) bool;

pub const Direction = enum { horizontal, vertical };
pub const Layout = union(enum) {
    dynamic,
    static: usize,

    pub inline fn eql(self: Layout, other: Layout) bool {
        return switch (self) {
            .dynamic => switch (other) {
                .dynamic => true,
                .static => false,
            },
            .static => |s| switch (other) {
                .dynamic => false,
                .static => |o| s == o,
            },
        };
    }
};

pub const ThemeInfo = struct {
    name: []const u8,
    storage: ?std.json.Parsed(Theme) = null,

    pub fn get(self: *@This(), allocator: std.mem.Allocator) ?Theme {
        if (load_theme_file(allocator, self.name) catch null) |parsed_theme| {
            self.storage = parsed_theme;
            return self.storage.?.value;
        }

        for (static_themes) |theme_| {
            if (std.mem.eql(u8, theme_.name, self.name))
                return theme_;
        }
        return null;
    }

    fn load_theme_file(allocator: std.mem.Allocator, theme_name: []const u8) !?std.json.Parsed(Theme) {
        return load_theme_file_internal(allocator, theme_name) catch |e| {
            std.log.err("Error loading theme '{s}' from file: {t}", .{ theme_name, e });
            return e;
        };
    }
    fn load_theme_file_internal(allocator: std.mem.Allocator, theme_name: []const u8) !?std.json.Parsed(Theme) {
        const json_str = root.read_theme(allocator, theme_name) orelse return null;
        defer allocator.free(json_str);
        return try std.json.parseFromSlice(Theme, allocator, json_str, .{ .allocate = .alloc_always });
    }
};

var themes_: ?std.StringHashMap(*ThemeInfo) = null;
var theme_names_: ?[]const []const u8 = null;
const static_themes = @import("themes").themes;

fn get_themes(allocator: std.mem.Allocator) *std.StringHashMap(*ThemeInfo) {
    if (themes_) |*themes__| return themes__;

    const theme_files = root.list_themes(allocator) catch @panic("OOM get_themes");
    var themes: std.StringHashMap(*ThemeInfo) = .init(allocator);
    defer allocator.free(theme_files);
    for (theme_files) |file| {
        const theme_info = allocator.create(ThemeInfo) catch @panic("OOM get_themes");
        theme_info.* = .{
            .name = file,
        };
        themes.put(theme_info.name, theme_info) catch @panic("OOM get_themes");
    }

    for (static_themes) |theme_| if (!themes.contains(theme_.name)) {
        const theme_info = allocator.create(ThemeInfo) catch @panic("OOM get_themes");
        theme_info.* = .{
            .name = theme_.name,
        };
        themes.put(theme_info.name, theme_info) catch @panic("OOM get_themes");
    };
    themes_ = themes;
    return &themes_.?;
}

fn get_theme_names() []const []const u8 {
    if (theme_names_) |names_| return names_;
    const themes = themes_ orelse return &.{};
    var i = get_themes(themes.allocator).iterator();
    var names: std.ArrayList([]const u8) = .empty;
    while (i.next()) |theme_| names.append(themes.allocator, theme_.value_ptr.*.name) catch @panic("OOM get_theme_names");
    std.mem.sort([]const u8, names.items, {}, struct {
        fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.cmp);
    theme_names_ = names.toOwnedSlice(themes.allocator) catch @panic("OOM get_theme_names");
    return theme_names_.?;
}

pub fn get_theme_by_name(allocator: std.mem.Allocator, name_: []const u8) ?Theme {
    const themes = get_themes(allocator);
    const theme = themes.get(name_) orelse return null;
    return theme.get(allocator);
}

pub fn get_next_theme_by_name(name_: []const u8) []const u8 {
    const theme_names = get_theme_names();
    var next = false;
    for (theme_names) |theme_name| {
        if (next)
            return theme_name;
        if (std.mem.eql(u8, theme_name, name_))
            next = true;
    }
    return theme_names[0];
}

pub fn get_prev_theme_by_name(name_: []const u8) []const u8 {
    const theme_names = get_theme_names();
    const last = theme_names[theme_names.len - 1];
    var prev: ?[]const u8 = null;
    for (theme_names) |theme_name| {
        if (std.mem.eql(u8, theme_name, name_))
            return prev orelse last;
        prev = theme_name;
    }
    return last;
}

pub fn list_themes() []const []const u8 {
    return get_theme_names();
}

pub const VTable = struct {
    deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    send: *const fn (ctx: *anyopaque, from: tp.pid_ref, m: tp.message) error{Exit}!bool,
    update: *const fn (ctx: *anyopaque) void,
    render: *const fn (ctx: *anyopaque, theme: *const Theme) bool,
    resize: *const fn (ctx: *anyopaque, pos: Box) void,
    layout: *const fn (ctx: *anyopaque) Layout,
    subscribe: *const fn (ctx: *anyopaque, h: EventHandler) error{NotSupported}!void,
    unsubscribe: *const fn (ctx: *anyopaque, h: EventHandler) error{NotSupported}!void,
    get: *const fn (ctx: *const anyopaque, name_: []const u8) ?Self,
    walk: *const fn (ctx: *anyopaque, walk_ctx: *anyopaque, f: WalkFn) bool,
    focus: *const fn (ctx: *anyopaque) void,
    unfocus: *const fn (ctx: *anyopaque) void,
    hover: *const fn (ctx: *const anyopaque) bool,
    type_name: []const u8,
};

pub fn to(pimpl: anytype) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.pointer.child;
    return .{
        .ptr = pimpl,
        .plane = &pimpl.plane,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(ctx: *anyopaque, allocator: Allocator) void {
                    return child.deinit(@as(*child, @ptrCast(@alignCast(ctx))), allocator);
                }
            }.deinit,
            .send = if (@hasDecl(child, "receive")) struct {
                pub fn f(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
                    return child.receive(@as(*child, @ptrCast(@alignCast(ctx))), from_, m);
                }
            }.f else struct {
                pub fn f(_: *anyopaque, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
                    return false;
                }
            }.f,
            .update = if (@hasDecl(child, "update")) struct {
                pub fn f(ctx: *anyopaque) void {
                    return child.update(@as(*child, @ptrCast(@alignCast(ctx))));
                }
            }.f else struct {
                pub fn f(_: *anyopaque) void {}
            }.f,
            .render = if (@hasDecl(child, "render")) struct {
                pub fn f(ctx: *anyopaque, theme: *const Theme) bool {
                    return child.render(@as(*child, @ptrCast(@alignCast(ctx))), theme);
                }
            }.f else struct {
                pub fn f(_: *anyopaque, _: *const Theme) bool {
                    return false;
                }
            }.f,
            .resize = if (@hasDecl(child, "handle_resize")) struct {
                pub fn f(ctx: *anyopaque, pos: Box) void {
                    return child.handle_resize(@as(*child, @ptrCast(@alignCast(ctx))), pos);
                }
            }.f else struct {
                pub fn f(ctx: *anyopaque, pos: Box) void {
                    const self: *child = @ptrCast(@alignCast(ctx));
                    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
                    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
                }
            }.f,
            .layout = if (@hasDecl(child, "layout")) struct {
                pub fn f(ctx: *anyopaque) Layout {
                    return child.layout(@as(*child, @ptrCast(@alignCast(ctx))));
                }
            }.f else struct {
                pub fn f(_: *anyopaque) Layout {
                    return .dynamic;
                }
            }.f,
            .subscribe = struct {
                pub fn subscribe(ctx: *anyopaque, h: EventHandler) error{NotSupported}!void {
                    return if (comptime @hasDecl(child, "subscribe"))
                        child.subscribe(@as(*child, @ptrCast(@alignCast(ctx))), h)
                    else
                        error.NotSupported;
                }
            }.subscribe,
            .unsubscribe = struct {
                pub fn unsubscribe(ctx: *anyopaque, h: EventHandler) error{NotSupported}!void {
                    return if (comptime @hasDecl(child, "unsubscribe"))
                        child.unsubscribe(@as(*child, @ptrCast(@alignCast(ctx))), h)
                    else
                        error.NotSupported;
                }
            }.unsubscribe,
            .get = struct {
                pub fn get(ctx: *const anyopaque, name_: []const u8) ?Self {
                    return if (comptime @hasDecl(child, "get")) child.get(@as(*const child, @ptrCast(@alignCast(ctx))), name_) else null;
                }
            }.get,
            .walk = struct {
                pub fn walk(ctx: *anyopaque, walk_ctx: *anyopaque, f: WalkFn) bool {
                    return if (comptime @hasDecl(child, "walk")) child.walk(@as(*child, @ptrCast(@alignCast(ctx))), walk_ctx, f) else false;
                }
            }.walk,
            .focus = struct {
                pub fn focus(ctx: *anyopaque) void {
                    if (comptime @hasDecl(child, "focus")) @as(*child, @ptrCast(@alignCast(ctx))).focus();
                }
            }.focus,
            .unfocus = struct {
                pub fn unfocus(ctx: *anyopaque) void {
                    if (comptime @hasDecl(child, "unfocus")) @as(*child, @ptrCast(@alignCast(ctx))).unfocus();
                }
            }.unfocus,
            .hover = struct {
                pub fn hover(ctx: *const anyopaque) bool {
                    return if (comptime @hasField(child, "hover")) @as(*const child, @ptrCast(@alignCast(ctx))).hover else false;
                }
            }.hover,
        },
    };
}

pub fn dynamic_cast(self: Self, comptime T: type) ?*T {
    return if (std.mem.eql(u8, self.vtable.type_name, @typeName(T)))
        @as(*T, @ptrCast(@alignCast(self.ptr)))
    else
        null;
}

pub fn need_render() void {
    tui.need_render(@src());
}

pub fn need_reflow() void {
    tp.self_pid().send(.{"reflow"}) catch {};
}

pub fn name(self: Self, buf: []u8) []const u8 {
    return self.plane.name(buf);
}

pub fn box(self: Self) Box {
    return Box.from(self.plane.*);
}

pub fn deinit(self: Self, allocator: Allocator) void {
    return self.vtable.deinit(self.ptr, allocator);
}

pub fn msg(self: *const Self, m: anytype) error{Exit}!bool {
    var buf: [tp.max_message_size]u8 = undefined;
    return self.vtable.send(self.ptr, tp.self_pid(), tp.message.fmtbuf(&buf, m) catch |e| std.debug.panic("Widget.msg: {any}", .{e}));
}

pub fn send(self: *const Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    return self.vtable.send(self.ptr, from_, m);
}

pub fn update(self: Self) void {
    return self.vtable.update(self.ptr);
}

pub fn render(self: Self, theme: *const Theme) bool {
    const more = self.vtable.render(self.ptr, theme);
    if (more)
        tp.trace(tp.channel.widget, .{ "continue_by", self.vtable.type_name });
    return more;
}

pub fn resize(self: Self, pos: Box) void {
    return self.vtable.resize(self.ptr, pos);
}

pub fn layout(self: Self) Layout {
    return self.vtable.layout(self.ptr);
}

pub fn subscribe(self: Self, h: EventHandler) !void {
    return self.vtable.subscribe(self.ptr, h);
}

pub fn unsubscribe(self: Self, h: EventHandler) !void {
    return self.vtable.unsubscribe(self.ptr, h);
}

pub fn get(self: *const Self, name_: []const u8) ?Self {
    var buf: [256]u8 = undefined;
    return if (std.mem.eql(u8, self.plane.name(&buf), name_))
        self.*
    else
        self.vtable.get(self.ptr, name_);
}

pub fn walk(self: *const Self, walk_ctx: *anyopaque, f: WalkFn) bool {
    return if (self.vtable.walk(self.ptr, walk_ctx, f)) true else f(walk_ctx, self.*);
}

pub fn focus(self: *const Self) void {
    self.vtable.focus(self.ptr);
}

pub fn unfocus(self: *const Self) void {
    self.vtable.unfocus(self.ptr);
}

pub fn hover(self: *const Self) bool {
    return self.vtable.hover(self.ptr);
}

pub fn empty(allocator: Allocator, parent: Plane, layout_: Layout) !Self {
    const child: type = struct { plane: Plane, layout: Layout };
    const widget = try allocator.create(child);
    errdefer allocator.destroy(widget);
    const n = try Plane.init(&(Box{}).opts("empty"), parent);
    widget.* = .{ .plane = n, .layout = layout_ };
    return .{
        .ptr = widget,
        .plane = &widget.plane,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(ctx: *anyopaque, allocator_: Allocator) void {
                    const self: *child = @ptrCast(@alignCast(ctx));
                    self.plane.deinit();
                    allocator_.destroy(self);
                }
            }.deinit,
            .send = struct {
                pub fn receive(_: *anyopaque, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
                    return false;
                }
            }.receive,
            .update = struct {
                pub fn update(_: *anyopaque) void {}
            }.update,
            .render = struct {
                pub fn render(_: *anyopaque, _: *const Theme) bool {
                    return false;
                }
            }.render,
            .resize = struct {
                pub fn resize(_: *anyopaque, _: Box) void {}
            }.resize,
            .layout = struct {
                pub fn layout(ctx: *anyopaque) Layout {
                    const self: *child = @ptrCast(@alignCast(ctx));
                    return self.layout;
                }
            }.layout,
            .subscribe = struct {
                pub fn subscribe(_: *anyopaque, _: EventHandler) error{NotSupported}!void {
                    return error.NotSupported;
                }
            }.subscribe,
            .unsubscribe = struct {
                pub fn unsubscribe(_: *anyopaque, _: EventHandler) error{NotSupported}!void {
                    return error.NotSupported;
                }
            }.unsubscribe,
            .get = struct {
                pub fn get(_: *const anyopaque, _: []const u8) ?Self {
                    return null;
                }
            }.get,
            .walk = struct {
                pub fn walk(_: *anyopaque, _: *anyopaque, _: WalkFn) bool {
                    return false;
                }
            }.walk,
            .focus = struct {
                pub fn focus(_: *anyopaque) void {}
            }.focus,
            .unfocus = struct {
                pub fn unfocus(_: *anyopaque) void {}
            }.unfocus,
            .hover = struct {
                pub fn hover(_: *const anyopaque) bool {
                    return false;
                }
            }.hover,
        },
    };
}
