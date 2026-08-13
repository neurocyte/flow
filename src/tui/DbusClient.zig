const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const dbus = @import("dbus");
const root = @import("soft_root").root;
const tui = @import("tui.zig");

const log = std.log.scoped(.dbus);

const dbus_dest = "org.freedesktop.DBus";
const dbus_path = "/org/freedesktop/DBus";
const dbus_iface = dbus_dest;

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_iface = "org.freedesktop.portal.Settings";
const match_rule = "type='signal',interface='" ++ settings_iface ++ "',member='SettingChanged'";

const appearance_ns = "org.freedesktop.appearance";
const color_scheme_key = "color-scheme";

pub const Error = dbus.Error;

const cookie = enum(i64) {
    add_match = 1,
    read,
};

bus: tp.pid,

pub fn init(allocator: std.mem.Allocator) !@This() {
    const env = root.get_init().environ_map;
    return .{
        .bus = try dbus.connect(allocator, .session, env),
    };
}

pub fn deinit(self: *@This()) void {
    self.bus.deinit();
}

pub fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
    return self.receive_safe(from, m) catch |e| tp.exit_error(e, @errorReturnTrace());
}

fn receive_safe(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
    var reason: []const u8 = "";
    var args: cbor.Raw = .{};

    if (try m.match(.{ "dbus", "connected", tp.more })) {
        // register interest in SettingChanged, then read the current value
        try self.bus.send(.{
            "call",
            @intFromEnum(cookie.add_match),
            dbus_dest,
            dbus_path,
            dbus_iface,
            "AddMatch",
            "s",
            .{match_rule},
        });
        try self.bus.send(.{
            "call",
            @intFromEnum(cookie.read),
            portal_dest,
            portal_path,
            settings_iface,
            "Read",
            "ss",
            .{ appearance_ns, color_scheme_key },
        });
    } else if (try m.match(.{ "dbus", "reply", @intFromEnum(cookie.add_match), tp.more })) {
        log.info("subscribed to SettingChanged events", .{});
    } else if (try m.match(.{ "dbus", "reply", @intFromEnum(cookie.read), tp.extract(&args) })) {
        on_read_reply(args);
    } else if (try m.match(.{ "dbus", "signal", tp.any, tp.any, settings_iface, "SettingChanged", tp.extract(&args) })) {
        on_setting_changed(args);
    } else if (try m.match(.{ "dbus", "error", @intFromEnum(cookie.read), tp.extract(&reason), tp.more })) {
        log.err("could not read {s}/{s}: {s}", .{ appearance_ns, color_scheme_key, reason });
    } else if (try m.match(.{ "dbus", "signal", tp.more })) {
        // ignore unrelated signals (e.g. the daemon's NameAcquired)
    } else if (try m.match(.{ "dbus", "disconnected", tp.extract(&reason) })) {
        log.err("dbus disconnected: {s}", .{reason});
    } else {
        return tp.unexpected(m);
    }
}

fn color_scheme_name(value: i64) []const u8 {
    return switch (value) {
        0 => "no-preference",
        1 => "prefer-dark",
        2 => "prefer-light",
        else => "unknown",
    };
}

fn color_scheme(value: i64) !@import("Widget.zig").Theme.Type {
    return switch (value) {
        0 => error.NoPreference,
        1 => .dark,
        2 => .light,
        else => error.Unknown,
    };
}

// Read reply body is [value].
fn on_read_reply(args: cbor.Raw) void {
    var value: i64 = undefined;

    if (cbor.match(args.bytes, .{cbor.extract(&value)}) catch false) {
        set_color_scheme_on_change(value);
    }
}

// SettingChanged body is [namespace, key, value].
fn on_setting_changed(args: cbor.Raw) void {
    var value: i64 = undefined;
    var ns: []const u8 = undefined;
    var key: []const u8 = undefined;
    var raw: cbor.Raw = undefined;

    if (cbor.match(args.bytes, .{ appearance_ns, color_scheme_key, cbor.extract(&value) }) catch false) {
        set_color_scheme_on_change(value);
    } else if (cbor.match(args.bytes, .{ cbor.extract(&ns), cbor.extract(&key), cbor.extract(&raw) }) catch false) {
        var buf: [4096]u8 = undefined;
        const json = cbor.toJson(raw.bytes, &buf) catch "?";
        log.info("setting changed: {s}/{s} = {s}", .{ ns, key, json });
    }
}

fn set_color_scheme_on_change(value: i64) void {
    log.info("desktop color-scheme changed: {d} ({s})", .{ value, color_scheme_name(value) });
    tui.set_color_scheme(color_scheme(value) catch return);
}
