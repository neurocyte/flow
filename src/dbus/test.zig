const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const dbus = @import("dbus.zig");

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_iface = "org.freedesktop.portal.Settings";

const appearance_ns = "org.freedesktop.appearance";
const color_scheme_key = "color-scheme";

const cookie_getid = 1;
const cookie_read = 2;

fn schemeName(value: i64) []const u8 {
    return switch (value) {
        0 => "no-preference",
        1 => "prefer-dark",
        2 => "prefer-light",
        else => "unknown",
    };
}

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
            if (keep_watching)
                std.debug.print("dbus reply: {s}", .{try cbor.toJson(m.buf, &buf)});
            return self.checkDone();
        } else if (try m.match(.{ "dbus", "error", cookie_read, tp.extract(&reason), tp.more })) {
            // A well-formed error is still a full round trip (e.g. no portal).
            self.got_read = true;
            std.debug.print("dbus error for {s} {s} {s}: {s}", .{ portal_dest, portal_path, settings_iface, reason });
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

// Subscribe to color-scheme changes and log them.
// Run with DBUS_TEST_WATCH=1 to subscribe

const cookie_watch_read = 10;
const cookie_addmatch = 11;

const match_rule =
    "type='signal'," ++
    "interface='" ++ settings_iface ++ "'," ++
    "member='SettingChanged'";

const Watcher = struct {
    allocator: std.mem.Allocator,
    bus: tp.pid,
    receiver: tp.Receiver(*@This()),

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

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var reason: []const u8 = "";
        var args: []const u8 = "";

        if (try m.match(.{ "dbus", "connected", tp.more })) {
            // register interest in SettingChanged, then read the current value
            try self.bus.send(.{
                "call",
                cookie_addmatch,
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "AddMatch",
                "s",
                .{match_rule},
            });
            try self.bus.send(.{
                "call",
                cookie_watch_read,
                portal_dest,
                portal_path,
                settings_iface,
                "Read",
                "ss",
                .{ appearance_ns, color_scheme_key },
            });
        } else if (try m.match(.{ "dbus", "reply", cookie_addmatch, tp.more })) {
            if (keep_watching)
                std.debug.print("subscribed to SettingChanged; toggle your desktop theme (Ctrl-C to stop)\n", .{});
        } else if (try m.match(.{ "dbus", "reply", cookie_watch_read, tp.extract_cbor(&args) })) {
            if (keep_watching)
                log_color_scheme("current", args)
            else
                return tp.exit("success");
        } else if (try m.match(.{ "dbus", "error", cookie_watch_read, tp.extract(&reason), tp.more })) {
            // A well-formed error is still a full round trip (e.g. no portal).
            std.debug.print("could not read {s}/{s}: {s}\n", .{ appearance_ns, color_scheme_key, reason });
            if (!keep_watching)
                return tp.exit("success");
        } else if (try m.match(.{ "dbus", "signal", tp.any, tp.any, settings_iface, "SettingChanged", tp.extract_cbor(&args) })) {
            on_setting_changed(args);
        } else if (try m.match(.{ "dbus", "signal", tp.more })) {
            // ignore unrelated signals (e.g. the daemon's NameAcquired)
        } else if (try m.match(.{ "dbus", "disconnected", tp.extract(&reason) })) {
            return tp.exit_error(error.Disconnected, null);
        } else {
            return tp.unexpected(m);
        }
    }

    fn log_color_scheme(label: []const u8, args: []const u8) void {
        var it: []const u8 = args;
        _ = cbor.decodeArrayHeader(&it) catch return;
        var value: i64 = -1;
        _ = cbor.matchValue(&it, cbor.extract(&value)) catch {};
        std.debug.print("{s} color-scheme: {d} ({s})\n", .{ label, value, schemeName(value) });
    }

    // SettingChanged body is [namespace, key, value].
    fn on_setting_changed(args: []const u8) void {
        var value: i64 = -1;
        if (cbor.match(args, .{ appearance_ns, color_scheme_key, cbor.extract(&value) }) catch false) {
            std.debug.print("color-scheme changed: {d} ({s})\n", .{ value, schemeName(value) });
            return;
        }
        var ns: []const u8 = "";
        var key: []const u8 = "";
        var raw: []const u8 = "";
        if (cbor.match(args, .{ cbor.extract(&ns), cbor.extract(&key), cbor.extract_cbor(&raw) }) catch false) {
            var buf: [4096]u8 = undefined;
            const json = cbor.toJson(raw, &buf) catch "?";
            std.debug.print("setting changed: {s}/{s} = {s}\n", .{ ns, key, json });
        }
    }
};

var keep_watching = false;

test "watch portal color-scheme changes" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    if (env.get("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    if (env.get("DBUS_TEST_WATCH") != null)
        keep_watching = true;

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
        Watcher.Args{
            .allocator = allocator,
            .env = &env,
        },
        Watcher.start,
        "dbus_watch",
        &exit_handler,
        null,
    );
    ctx.run(); // block until the bus disconnects

    if (!success) return error.TestFailed;
}
