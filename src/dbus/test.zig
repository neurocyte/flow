const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const dbus = @import("dbus.zig");

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_iface = "org.freedesktop.portal.Settings";

const cookie_getid = 1;
const cookie_read = 2;

const DBusTest = struct {
    allocator: std.mem.Allocator,
    bus: tp.pid,
    receiver: tp.Receiver(*@This()),
    got_getid: bool = false,
    got_read: bool = false,

    const Args = struct {
        allocator: std.mem.Allocator,
        env: *const std.process.Environ.Map,
    };

    fn start(args: Args) tp.result {
        return init(args.allocator, args.env) catch |e| tp.exit_error(e, @errorReturnTrace());
    }

    fn init(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
        const bus = try dbus.connect(allocator, .session, env);
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.bus.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| tp.exit_error(e, @errorReturnTrace());
    }

    fn checkDone(self: *@This()) tp.result {
        if (self.got_getid and self.got_read) return tp.exit("success");
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var name: []const u8 = "";
        var reason: []const u8 = "";

        if (try m.match(.{ "dbus", "connected", tp.extract(&name) })) {
            // guaranteed reply from the bus daemon
            try self.bus.send(.{
                "call",
                cookie_getid,
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "GetId",
                "",
                .{},
            });
            // read the desktop colour scheme from the portal
            try self.bus.send(.{
                "call",
                cookie_read,
                portal_dest,
                portal_path,
                settings_iface,
                "Read",
                "ss",
                .{ "org.freedesktop.appearance", "color-scheme" },
            });
        } else if (try m.match(.{ "dbus", "reply", cookie_getid, tp.more })) {
            self.got_getid = true;
            return self.checkDone();
        } else if (try m.match(.{ "dbus", "reply", cookie_read, tp.more })) {
            self.got_read = true;
            var buf: [4096]u8 = undefined;
            std.log.warn("dbus reply: {s}", .{try cbor.toJson(m.buf, &buf)});
            return self.checkDone();
        } else if (try m.match(.{ "dbus", "error", cookie_read, tp.extract(&reason), tp.more })) {
            // A well-formed error is still a full round trip (e.g. no portal).
            self.got_read = true;
            std.log.debug("dbus error for {s} {s} {s}: {s}", .{ portal_dest, portal_path, settings_iface, reason });
            return self.checkDone();
        } else if (try m.match(.{ "dbus", "error", cookie_getid, tp.extract(&reason), tp.more })) {
            return tp.unexpected(m);
        } else if (try m.match(.{ "dbus", "signal", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameAcquired", tp.any })) {
            // nothing to do
        } else if (try m.match(.{ "dbus", "signal", tp.more })) {
            return tp.unexpected(m);
        } else if (try m.match(.{ "dbus", "disconnected", tp.extract(&reason) })) {
            return tp.exit_error(error.Disconnected, null);
        } else {
            return tp.unexpected(m);
        }
    }
};

test "portal Settings.Read round trip" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    if (env.get("DBUS_SESSION_BUS_ADDRESS") == null)
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ctx = try tp.context.init(allocator, .{});
    defer ctx.deinit();

    var success = false;
    var exit_handler = tp.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "success")) ok.* = true else std.log.err("EXITED: {s}", .{status});
        }
    }.handle);

    _ = try ctx.spawn_link(
        DBusTest.Args{
            .allocator = allocator,
            .env = &env,
        },
        DBusTest.start,
        "dbus_smoke",
        &exit_handler,
        null,
    );
    ctx.run();

    if (!success) return error.TestFailed;
}
