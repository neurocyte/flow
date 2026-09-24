const std = @import("std");
const Widget = @import("Widget.zig");

pub const Indicator = enum { none, alt_screen, activity, bell, busy, exited, exited_error };
pub const Visibility = enum { visible, hidden };
pub const CloseResult = enum { closed, vetoed };
pub const Id = u32;
pub const ScrollAction = enum { line_up, line_down, page_up, page_down, top, bottom };

id: Id = 0,
widget: Widget,
impl: Widget,
vtable: *const VTable,

const Self = @This();

pub const VTable = struct {
    tag: []const u8,
    singleton: bool,
    title: *const fn (ctx: *anyopaque) []const u8,
    icon: *const fn (ctx: *anyopaque) []const u8,
    indicator: *const fn (ctx: *anyopaque, visibility: Visibility) Indicator,
    request_close: *const fn (ctx: *anyopaque) CloseResult,
    set_current: *const fn (ctx: *anyopaque, current: bool) void,
    write_state: ?*const fn (ctx: *anyopaque, writer: *std.Io.Writer) error{WriteFailed}!void,
    scroll: ?*const fn (ctx: *anyopaque, action: ScrollAction) void,
    copy: ?*const fn (ctx: *anyopaque) void,
    clear: ?*const fn (ctx: *anyopaque) void,
};

pub fn to(pimpl: anytype) Self {
    const child: type = @typeInfo(@TypeOf(pimpl)).pointer.child;
    const self_of = struct {
        inline fn f(ctx: *anyopaque) *child {
            return @ptrCast(@alignCast(ctx));
        }
    }.f;
    return .{
        .widget = Widget.to(pimpl),
        .impl = Widget.to(pimpl),
        .vtable = comptime &.{
            .tag = child.panel_tag,
            .singleton = if (@hasDecl(child, "panel_singleton")) child.panel_singleton else false,
            .title = struct {
                fn f(ctx: *anyopaque) []const u8 {
                    return self_of(ctx).panel_title();
                }
            }.f,
            .icon = struct {
                fn f(ctx: *anyopaque) []const u8 {
                    return if (@hasDecl(child, "panel_icon")) self_of(ctx).panel_icon() else "";
                }
            }.f,
            .indicator = struct {
                fn f(ctx: *anyopaque, visibility: Visibility) Indicator {
                    return if (@hasDecl(child, "panel_indicator")) self_of(ctx).panel_indicator(visibility) else .none;
                }
            }.f,
            .request_close = struct {
                fn f(ctx: *anyopaque) CloseResult {
                    return if (@hasDecl(child, "panel_close")) self_of(ctx).panel_close() else .closed;
                }
            }.f,
            .set_current = struct {
                fn f(ctx: *anyopaque, current: bool) void {
                    if (@hasDecl(child, "panel_set_current")) self_of(ctx).panel_set_current(current);
                }
            }.f,
            .write_state = if (@hasDecl(child, "panel_write_state")) struct {
                fn f(ctx: *anyopaque, writer: *std.Io.Writer) error{WriteFailed}!void {
                    return self_of(ctx).panel_write_state(writer);
                }
            }.f else null,
            .scroll = if (@hasDecl(child, "panel_scroll")) struct {
                fn f(ctx: *anyopaque, action: ScrollAction) void {
                    self_of(ctx).panel_scroll(action);
                }
            }.f else null,
            .copy = if (@hasDecl(child, "panel_copy")) struct {
                fn f(ctx: *anyopaque) void {
                    self_of(ctx).panel_copy();
                }
            }.f else null,
            .clear = if (@hasDecl(child, "panel_clear")) struct {
                fn f(ctx: *anyopaque) void {
                    self_of(ctx).panel_clear();
                }
            }.f else null,
        },
    };
}

pub fn to_hosted(pimpl: anytype, host: Widget) Self {
    var self = to(pimpl);
    self.widget = host;
    return self;
}

pub fn tag(self: Self) []const u8 {
    return self.vtable.tag;
}

pub fn singleton(self: Self) bool {
    return self.vtable.singleton;
}

pub fn title(self: Self) []const u8 {
    return self.vtable.title(self.impl.ptr);
}

pub fn icon(self: Self) []const u8 {
    return self.vtable.icon(self.impl.ptr);
}

pub fn indicator(self: Self, visibility: Visibility) Indicator {
    return self.vtable.indicator(self.impl.ptr, visibility);
}

pub fn request_close(self: Self) CloseResult {
    return self.vtable.request_close(self.impl.ptr);
}

pub fn set_current(self: Self, current: bool) void {
    self.vtable.set_current(self.impl.ptr, current);
}

pub fn scroll(self: Self, action: ScrollAction) void {
    if (self.vtable.scroll) |f| f(self.impl.ptr, action);
}

pub fn copy(self: Self) void {
    if (self.vtable.copy) |f| f(self.impl.ptr);
}

pub fn clear(self: Self) void {
    if (self.vtable.clear) |f| f(self.impl.ptr);
}

pub fn is(self: Self, comptime T: type) bool {
    return std.mem.eql(u8, self.vtable.tag, T.panel_tag);
}

pub fn cast(self: Self, comptime T: type) ?*T {
    return self.impl.dynamic_cast(T);
}
