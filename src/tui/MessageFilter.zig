const std = @import("std");
const tp = @import("thespian");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Self = @This();
const MessageFilter = Self;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    filter: *const fn (ctx: *anyopaque, from: tp.pid_ref, m: tp.message) error{Exit}!bool,
    type_name: []const u8,
};

pub fn to_owned(pimpl: anytype) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.Pointer.child;
    return .{
        .ptr = pimpl,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(ctx: *anyopaque) void {
                    return child.deinit(@as(*child, @ptrCast(@alignCast(ctx))));
                }
            }.deinit,
            .filter = struct {
                pub fn filter(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
                    return child.filter(@as(*child, @ptrCast(@alignCast(ctx))), from_, m);
                }
            }.filter,
        },
    };
}

pub fn to_unowned(pimpl: anytype) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.Pointer.child;
    return .{
        .ptr = pimpl,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(_: *anyopaque) void {}
            }.deinit,
            .filter = struct {
                pub fn filter(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
                    return child.filter(@as(*child, @ptrCast(@alignCast(ctx))), from_, m);
                }
            }.filter,
        },
    };
}

pub fn bind(pimpl: anytype, comptime f: *const fn (ctx: @TypeOf(pimpl), from: tp.pid_ref, m: tp.message) error{Exit}!bool) Self {
    const impl = @typeInfo(@TypeOf(pimpl));
    const child: type = impl.Pointer.child;
    return .{
        .ptr = pimpl,
        .vtable = comptime &.{
            .type_name = @typeName(child),
            .deinit = struct {
                pub fn deinit(_: *anyopaque) void {}
            }.deinit,
            .filter = struct {
                pub fn filter(ctx: *anyopaque, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
                    return @call(.auto, f, .{ @as(*child, @ptrCast(@alignCast(ctx))), from_, m });
                }
            }.filter,
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

pub fn filter(self: Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    return self.vtable.filter(self.ptr, from_, m);
}

pub const List = struct {
    a: Allocator,
    list: ArrayList(MessageFilter),

    pub fn init(a: Allocator) List {
        return .{
            .a = a,
            .list = ArrayList(MessageFilter).init(a),
        };
    }

    pub fn deinit(self: *List) void {
        for (self.list.items) |*i|
            i.deinit();
        self.list.deinit();
    }

    pub fn add(self: *List, h: MessageFilter) !void {
        (try self.list.addOne()).* = h;
        // @import("log").print("MessageFilter", "add: {d} {s}", .{ self.list.items.len, self.list.items[self.list.items.len - 1].vtable.type_name });
    }

    pub fn remove(self: *List, h: MessageFilter) !void {
        return self.remove_ptr(h.ptr);
    }

    pub fn remove_ptr(self: *List, p_: *anyopaque) void {
        for (self.list.items, 0..) |*p, i|
            if (p.ptr == p_)
                self.list.orderedRemove(i).deinit();
    }

    pub fn filter(self: *const List, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var buf: [tp.max_message_size]u8 = undefined;
        @memcpy(buf[0..m.buf.len], m.buf);
        const m_: tp.message = .{ .buf = buf[0..m.buf.len] };
        var e: ?error{Exit} = null;
        for (self.list.items) |*i| {
            const consume = i.filter(from, m_) catch |e_| ret: {
                e = e_;
                break :ret false;
            };
            if (consume)
                return true;
        }
        return if (e) |e_| e_ else false;
    }
};
