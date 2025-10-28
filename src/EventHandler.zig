const std = @import("std");
const tp = @import("thespian");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Self = @This();
const EventHandler = Self;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    send: *const fn (ctx: *anyopaque, from: tp.pid_ref, m: tp.message) tp.result,
    type_name: []const u8,
};

pub fn to_owned(pimpl: anytype) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.pointer.child;
    return .{
        .ptr = pimpl,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(ctx: *anyopaque) void {
                    return child.deinit(@as(*child, @ptrCast(@alignCast(ctx))));
                }
            }.deinit,
            .send = struct {
                pub fn receive(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) tp.result {
                    _ = try child.receive(@as(*child, @ptrCast(@alignCast(ctx))), from_, m);
                }
            }.receive,
        },
    };
}

pub fn static(T: type) Self {
    return .{
        .ptr = &none,
        .vtable = comptime &.{
            .type_name = @typeName(T),
            .deinit = struct {
                pub fn deinit(_: *anyopaque) void {}
            }.deinit,
            .send = struct {
                pub fn receive(_: *anyopaque, from_: tp.pid_ref, m: tp.message) tp.result {
                    _ = try T.receive(from_, m);
                }
            }.receive,
        },
    };
}

var none = {};

pub fn to_unowned(pimpl: anytype) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.pointer.child;
    return .{
        .ptr = pimpl,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(_: *anyopaque) void {}
            }.deinit,
            .send = if (@hasDecl(child, "send")) struct {
                pub fn send(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) tp.result {
                    _ = try child.send(@as(*child, @ptrCast(@alignCast(ctx))), from_, m);
                }
            }.send else struct {
                pub fn receive(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) tp.result {
                    _ = try child.receive(@as(*child, @ptrCast(@alignCast(ctx))), from_, m);
                }
            }.receive,
        },
    };
}

pub fn bind(pimpl: anytype, comptime f: *const fn (ctx: @TypeOf(pimpl), from: tp.pid_ref, m: tp.message) tp.result) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.pointer.child;
    return .{
        .ptr = pimpl,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(_: *anyopaque) void {}
            }.deinit,
            .send = struct {
                pub fn receive(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) tp.result {
                    return @call(.auto, f, .{ @as(*child, @ptrCast(@alignCast(ctx))), from_, m });
                }
            }.receive,
        },
    };
}

pub fn deinit(self: Self) void {
    return self.vtable.deinit(self.ptr);
}

pub fn dynamic_cast(self: Self, comptime T: type) ?*T {
    return if (std.mem.eql(u8, self.vtable.type_name, @typeName(T)))
        @as(*T, @ptrCast(@alignCast(self.ptr)))
    else
        null;
}

pub fn msg(self: Self, m: anytype) tp.result {
    var buf: [tp.max_message_size]u8 = undefined;
    return self.vtable.send(self.ptr, tp.self_pid(), tp.message.fmtbuf(&buf, m) catch |e| std.debug.panic("EventHandler.msg: {any}", .{e}));
}

pub fn send(self: Self, from_: tp.pid_ref, m: tp.message) tp.result {
    return self.vtable.send(self.ptr, from_, m);
}

pub fn empty(allocator: Allocator) !Self {
    const child: type = struct {};
    const widget = try allocator.create(child);
    errdefer allocator.destroy(widget);
    widget.* = .{};
    return .{
        .ptr = widget,
        .plane = &widget.plane,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(ctx: *anyopaque, allocator_: Allocator) void {
                    return allocator_.destroy(@as(*child, @ptrCast(@alignCast(ctx))));
                }
            }.deinit,
            .send = struct {
                pub fn receive(_: *anyopaque, _: tp.pid_ref, _: tp.message) tp.result {
                    return false;
                }
            }.receive,
        },
    };
}

pub const List = struct {
    allocator: Allocator,
    list: ArrayList(EventHandler),
    recursion_check: bool = false,

    pub fn init(allocator: Allocator) List {
        return .{
            .allocator = allocator,
            .list = .empty,
        };
    }

    pub fn deinit(self: *List) void {
        for (self.list.items) |*i|
            i.deinit();
        self.list.deinit(self.allocator);
    }

    pub fn add(self: *List, h: EventHandler) !void {
        (try self.list.addOne(self.allocator)).* = h;
    }

    pub fn remove(self: *List, h: EventHandler) !void {
        return self.remove_ptr(h.ptr);
    }

    pub fn remove_ptr(self: *List, p_: *anyopaque) void {
        for (self.list.items, 0..) |*p, i|
            if (p.ptr == p_)
                self.list.orderedRemove(i).deinit();
    }

    pub fn msg(self: *const List, m: anytype) tp.result {
        var buf: [tp.max_message_size]u8 = undefined;
        return self.send(tp.self_pid(), tp.message.fmtbuf(&buf, m) catch |e| std.debug.panic("EventHandler.List.msg: {any}", .{e}));
    }

    pub fn send(self: *const List, from: tp.pid_ref, m: tp.message) tp.result {
        if (self.recursion_check)
            @panic("recursive EventHandler call");
        const self_nonconst = @constCast(self);
        self_nonconst.recursion_check = true;
        defer self_nonconst.recursion_check = false;
        tp.trace(tp.channel.event, m);
        var buf: [tp.max_message_size]u8 = undefined;
        @memcpy(buf[0..m.buf.len], m.buf);
        const m_: tp.message = .{ .buf = buf[0..m.buf.len] };
        var e: ?error{Exit} = null;
        for (self.list.items) |*i|
            i.send(from, m_) catch |e_| {
                e = e_;
            };
        return if (e) |e_| e_;
    }
};
