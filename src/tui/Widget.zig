const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");

const Plane = @import("renderer").Plane;
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
pub const Box = @import("Box.zig");
pub const Pos = struct { y: i32 = 0, x: i32 = 0 };
pub const Theme = @import("theme");
pub const themes = @import("themes").themes;
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

pub fn focus(self: *Self) void {
    self.vtable.focus(self.ptr);
}

pub fn unfocus(self: *Self) void {
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
