//! A small, generic D-Bus client for thespian actors.
//!
//! `connect` spawns a `Bus` transport actor that authenticates and then relays
//! untyped, cbor-encoded messages between the bus and the calling actor. See
//! `Bus` for the message protocol and `wire` for the value representation.

const std = @import("std");
const tp = @import("thespian");

pub const Bus = @import("Bus.zig");
pub const Message = @import("Message.zig");
pub const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

pub const Address = struct {
    path: [:0]const u8,
    mode: tp.unx_mode,

    pub fn resolve(allocator: Allocator, bus: BusType, env: *const std.process.Environ.Map) Error!Address {
        switch (bus) {
            .system => return .{
                .path = try allocator.dupeZ(u8, "/var/run/dbus/system_bus_socket"),
                .mode = .file,
            },
            .custom => |addr| return parseAddress(allocator, addr),
            .session => {
                const addr = env.get("DBUS_SESSION_BUS_ADDRESS") orelse
                    return error.BusAddressNotSet;
                return parseAddress(allocator, addr);
            },
        }
    }
};

pub const BusType = union(enum) {
    session,
    system,
    /// A raw address string, as in `DBUS_SESSION_BUS_ADDRESS`.
    custom: []const u8,
};

pub const Error = error{
    BusAddressNotSet,
    UnsupportedTransport,
    InvalidAddress,
    ThespianSpawnFailed,
} || Allocator.Error;

/// Parse the first unix: transport out of a (possibly ;-separated) address.
fn parseAddress(allocator: Allocator, address: []const u8) Error!Address {
    var transports = std.mem.splitScalar(u8, address, ';');
    while (transports.next()) |transport| {
        var it = std.mem.splitScalar(u8, transport, ':');
        const proto = it.first();
        if (!std.mem.eql(u8, proto, "unix")) continue;
        const params = it.next() orelse return error.InvalidAddress;

        var kv = std.mem.splitScalar(u8, params, ',');
        while (kv.next()) |pair| {
            var pit = std.mem.splitScalar(u8, pair, '=');
            const key = pit.first();
            const value = pit.next() orelse continue;
            if (std.mem.eql(u8, key, "path"))
                return .{ .path = try allocator.dupeZ(u8, value), .mode = .file };
            if (std.mem.eql(u8, key, "abstract"))
                return .{ .path = try allocator.dupeZ(u8, value), .mode = .abstract };
        }
    }
    return error.UnsupportedTransport;
}

/// Spawn a linked bus transport.
pub fn connect(allocator: Allocator, bus: BusType, env: *const std.process.Environ.Map) Error!tp.pid {
    const addr = try Address.resolve(allocator, bus, env);
    errdefer allocator.free(addr.path);
    return tp.spawn_link(allocator, Bus.Args{
        .allocator = allocator,
        .parent = tp.self_pid().clone(),
        .path = addr.path,
        .mode = addr.mode,
    }, Bus.start, "dbus");
}

test {
    _ = wire;
    _ = Message;
    _ = Bus;
    _ = @import("test.zig");
}

test parseAddress {
    const allocator = std.testing.allocator;
    {
        const a = try parseAddress(allocator, "unix:path=/run/user/1000/bus");
        defer allocator.free(a.path);
        try std.testing.expectEqualStrings("/run/user/1000/bus", a.path);
        try std.testing.expectEqual(tp.unx_mode.file, a.mode);
    }
    {
        const a = try parseAddress(allocator, "unix:abstract=/tmp/dbus-Ab3,guid=deadbeef");
        defer allocator.free(a.path);
        try std.testing.expectEqualStrings("/tmp/dbus-Ab3", a.path);
        try std.testing.expectEqual(tp.unx_mode.abstract, a.mode);
    }
    try std.testing.expectError(error.UnsupportedTransport, parseAddress(allocator, "tcp:host=localhost"));
}
