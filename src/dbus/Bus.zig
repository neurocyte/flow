//! A generic D-Bus transport.
//!
//! The actor owns the bus socket. It performs the SASL EXTERNAL handshake
//! and the initial `Hello`, then relays untyped messages between the bus
//! and its parent. Everything crossing the boundary is cbor; the layer
//! imposes no types of its own beyond the D-Bus signature that must
//! accompany a call.
//!
//! Messages the parent can send to the bus:
//!   {"call", cookie, destination, path, interface, member, signature, args}
//!       args is a cbor array matching signature. The reply is delivered
//!       as a "reply"/"error" carrying the same cookie.
//!
//! Messages the bus sends to the parent:
//!   {"dbus", "connected", unique_name}
//!   {"dbus", "reply", cookie, args}                     args: cbor array
//!   {"dbus", "error", cookie, error_name, args}
//!   {"dbus", "signal", sender, path, interface, member, args}
//!   {"dbus", "method_call", serial, sender, path, interface, member, args}
//!   {"dbus", "disconnected", reason}

const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const Message = @import("Message.zig");
const wire = @import("wire.zig");

const Bus = @This();
const Allocator = std.mem.Allocator;

const tag = "dbus";

allocator: Allocator,
parent: tp.pid,
path: [:0]const u8,
connector: tp.unx_connector,
sock: ?tp.socket = null,
receiver: tp.Receiver(*Bus),

rx_buf: std.ArrayList(u8) = .empty,

state: enum { auth, running } = .auth,
next_serial_: u32 = 1,
hello_serial: u32 = 0,

/// map D-Bus serial to a cookie.
pending: std.AutoHashMapUnmanaged(u32, i64) = .empty,

pub const Args = struct {
    allocator: Allocator,
    parent: tp.pid,
    path: [:0]const u8, // ownership transfered
    mode: tp.unx_mode,
};

pub fn start(args: Args) tp.result {
    return init(args) catch |e| tp.exit_error(e, @errorReturnTrace());
}

fn init(args: Args) !void {
    const connector: tp.unx_connector = try .init(tag);
    const self = try args.allocator.create(Bus);
    self.* = .{
        .allocator = args.allocator,
        .parent = args.parent,
        .path = args.path,
        .connector = connector,
        .receiver = .init(receive_fn, deinit, self),
    };
    errdefer self.deinit();
    try self.connector.connect(args.path, args.mode);
    tp.receive(&self.receiver);
}

fn deinit(self: *Bus) void {
    if (self.sock) |s| s.deinit();
    self.connector.deinit();
    self.pending.deinit(self.allocator);
    self.rx_buf.deinit(self.allocator);
    self.parent.deinit();
    self.allocator.free(self.path);
    self.allocator.destroy(self);
}

fn receive_fn(self: *Bus, from: tp.pid_ref, m: tp.message) tp.result {
    return self.receive(from, m) catch |e| tp.exit_error(e, @errorReturnTrace());
}

fn receive(self: *Bus, _: tp.pid_ref, m: tp.message) !void {
    var fd: i32 = 0;
    var buf: []const u8 = "";
    var reason: []const u8 = "";

    if (try m.match(.{ "connector", tag, "connected", tp.extract(&fd) })) {
        try self.connected(fd);
    } else if (try m.match(.{ "socket", tag, "read_complete", tp.extract(&buf) })) {
        try self.on_read(buf);
        if (self.sock) |s| try s.read();
    } else if (try m.match(.{ "socket", tag, "write_complete", tp.more })) {
        // nothing to do
    } else if (try m.match(.{ "socket", tag, "closed" })) {
        return self.disconnected("closed");
    } else if (try m.match(.{ "socket", tag, "read_error", tp.extract(&reason), tp.more })) {
        return self.disconnected(reason);
    } else if (try m.match(.{ "socket", tag, "write_error", tp.extract(&reason), tp.more })) {
        return self.disconnected(reason);
    } else if (try m.match(.{ "connector", tag, "error", tp.extract(&reason), tp.more })) {
        return self.disconnected(reason);
    } else if (try self.on_message(m)) {
        // handled
    } else {
        return tp.unexpected(m);
    }
}

fn disconnected(self: *Bus, reason: []const u8) tp.result {
    self.parent.send(.{ tag, "disconnected", reason }) catch {};
    return tp.exit_normal();
}

fn connected(self: *Bus, fd: i32) !void {
    const sock: tp.socket = try .init(tag, fd);
    self.sock = sock;

    // SASL EXTERNAL: a leading nul, then the uid as hex-encoded ascii digits.
    var line: std.Io.Writer.Allocating = .init(self.allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeByte(0);
    try w.writeAll("AUTH EXTERNAL ");
    var uid_buf: [16]u8 = undefined;
    const uid_dec = std.fmt.bufPrint(&uid_buf, "{d}", .{std.os.linux.getuid()}) catch unreachable;
    for (uid_dec) |c| try w.print("{x:0>2}", .{c});
    try w.writeAll("\r\n");

    try sock.write_binary(line.written());
    try sock.read();
}

fn on_read(self: *Bus, chunk: []const u8) !void {
    try self.rx_buf.appendSlice(self.allocator, chunk);
    switch (self.state) {
        .auth => try self.pump_auth(),
        .running => try self.pump_messages(),
    }
}

fn pump_auth(self: *Bus) !void {
    const eol = std.mem.indexOf(u8, self.rx_buf.items, "\r\n") orelse return; // need more
    const reply = self.rx_buf.items[0..eol];

    if (std.mem.startsWith(u8, reply, "OK")) {
        const sock = self.sock.?;
        try sock.write_binary("BEGIN\r\n");
        self.consume(eol + 2);
        self.state = .running;
        try self.send_hello();
        try self.pump_messages(); // in case bytes already followed
    } else {
        return error.AuthFailed;
    }
}

fn send_hello(self: *Bus) !void {
    self.hello_serial = self.next_serial();
    const buf = try Message.encode(self.allocator, .{
        .type = .method_call,
        .serial = self.hello_serial,
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "Hello",
    });
    defer self.allocator.free(buf);
    try self.sock.?.write_binary(buf);
}

fn pump_messages(self: *Bus) !void {
    while (true) {
        const total = (try Message.frame_length(self.rx_buf.items)) orelse return;
        const msg = self.rx_buf.items[0..total];
        try self.dispatch(msg);
        self.consume(total);
    }
}

fn dispatch(self: *Bus, msg: []const u8) !void {
    const h = try Message.parse(msg);
    switch (h.type) {
        .method_return => {
            if (h.reply_serial == self.hello_serial and self.hello_serial != 0) {
                try self.on_hello_reply(msg, h);
                self.hello_serial = 0;
                return;
            }
            try self.forward(msg, h, .{
                tag,
                "reply",
                self.take_cookie(h.reply_serial) orelse return,
            });
        },
        .@"error" => {
            try self.forward(msg, h, .{
                tag,
                "error",
                self.take_cookie(h.reply_serial) orelse return,
                h.error_name orelse "",
            });
        },
        .signal => {
            try self.forward(msg, h, .{
                tag,
                "signal",
                h.sender orelse "",
                h.path orelse "",
                h.interface orelse "",
                h.member orelse "",
            });
        },
        .method_call => {
            try self.forward(msg, h, .{
                tag,
                "method_call",
                h.serial,
                h.sender orelse "",
                h.path orelse "",
                h.interface orelse "",
                h.member orelse "",
            });
        },
        .invalid => {},
    }
}

fn on_hello_reply(self: *Bus, msg: []const u8, h: Message.Header) !void {
    var dec = wire.Decoder.init(msg, h.body_start, h.endian);
    var name_buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer name_buf.deinit();
    try wire.decode_sig(self.allocator, &name_buf.writer, &dec, h.signature);
    // body is a single string; extract it for a friendly "connected" message
    var it: []const u8 = name_buf.written();
    var unique: []const u8 = "";
    const len = cbor.decodeArrayHeader(&it) catch 0;
    if (len > 0) _ = cbor.matchValue(&it, cbor.extract(&unique)) catch {};
    self.parent.send(.{ tag, "connected", unique }) catch {};
}

fn forward(self: *Bus, msg: []const u8, h: Message.Header, prefix: anytype) !void {
    var args: std.Io.Writer.Allocating = .init(self.allocator);
    defer args.deinit();
    var dec = wire.Decoder.init(msg, h.body_start, h.endian);
    try wire.decode_sig(self.allocator, &args.writer, &dec, h.signature);
    self.parent.send(prefix ++ .{cbor.Raw{ .bytes = args.written() }}) catch {};
}

fn on_message(self: *Bus, m: tp.message) !bool {
    var cookie: i64 = 0;
    var dest: []const u8 = "";
    var path: []const u8 = "";
    var iface: []const u8 = "";
    var member: []const u8 = "";
    var sig: []const u8 = "";
    var args: []const u8 = "";

    if (try m.match(.{
        "call",
        tp.extract(&cookie),
        tp.extract(&dest),
        tp.extract(&path),
        tp.extract(&iface),
        tp.extract(&member),
        tp.extract(&sig),
        tp.extract_cbor(&args),
    })) {
        try self.send_call(cookie, dest, path, iface, member, sig, args);
        return true;
    }
    return false;
}

fn send_call(
    self: *Bus,
    cookie: i64,
    dest: []const u8,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    sig: []const u8,
    args: []const u8,
) !void {
    const serial = self.next_serial();
    const buf = try Message.encode(self.allocator, .{
        .type = .method_call,
        .serial = serial,
        .destination = dest,
        .path = path,
        .interface = iface,
        .member = member,
        .signature = sig,
        .args = args,
    });
    defer self.allocator.free(buf);
    try self.pending.put(self.allocator, serial, cookie);
    errdefer _ = self.pending.remove(serial);
    try self.sock.?.write_binary(buf);
}

fn next_serial(self: *Bus) u32 {
    const s = self.next_serial_;
    self.next_serial_ += 1;
    return s;
}

fn take_cookie(self: *Bus, reply_serial: ?u32) ?i64 {
    const serial = reply_serial orelse return null;
    const kv = self.pending.fetchRemove(serial) orelse return null;
    return kv.value;
}

fn consume(self: *Bus, n: usize) void {
    const rest = self.rx_buf.items.len - n;
    std.mem.copyForwards(u8, self.rx_buf.items[0..rest], self.rx_buf.items[n..]);
    self.rx_buf.items.len = rest;
}
