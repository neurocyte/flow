//! D-Bus message framing.

const std = @import("std");
const cbor = @import("cbor");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Message = @This();

pub const Type = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
};

const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

pub const Flags = packed struct(u8) {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _pad: u5 = 0,
};

pub const Header = struct {
    endian: wire.Endian,
    type: Type,
    flags: Flags,
    serial: u32,
    body_len: u32,
    body_start: usize,

    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
};

pub const protocol_version = 1;
pub const fixed_header_len = 16; // 12 fixed fields + 4 byte header-array length

pub fn frame_length(buf: []const u8) wire.Error!?usize {
    if (buf.len < fixed_header_len) return null;
    const endian: wire.Endian = switch (buf[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.InvalidSignature,
    };
    const body_len = std.mem.readInt(u32, buf[4..8], endian);
    const fields_len = std.mem.readInt(u32, buf[12..16], endian);
    const body_start = std.mem.alignForward(usize, fixed_header_len + fields_len, 8);
    const total = body_start + body_len;
    return if (buf.len < total) null else total;
}

pub fn parse(buf: []const u8) wire.Error!Header {
    const endian: wire.Endian = switch (buf[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.InvalidSignature,
    };
    var h: Header = .{
        .endian = endian,
        .type = std.enums.fromInt(Type, buf[1]) orelse .invalid,
        .flags = @bitCast(buf[2]),
        .body_len = std.mem.readInt(u32, buf[4..8], endian),
        .serial = std.mem.readInt(u32, buf[8..12], endian),
        .body_start = undefined,
    };

    const fields_len = std.mem.readInt(u32, buf[12..16], endian);
    const fields_end = fixed_header_len + fields_len;
    h.body_start = std.mem.alignForward(usize, fields_end, 8);

    var dec = wire.Decoder.init(buf[0..fields_end], fixed_header_len, endian);
    while (dec.pos < fields_end) {
        dec.pos = std.mem.alignForward(usize, dec.pos, 8); // struct alignment
        if (dec.pos >= fields_end) break;
        const code = buf[dec.pos];
        dec.pos += 1;
        // Each field value is a variant: read its signature then its value.
        var out: std.Io.Writer.Discarding = .init(&.{});
        const vsig = try read_variant_sig(&dec);
        const field = std.enums.fromInt(Field, code) orelse {
            try wire.decode_value(std.heap.page_allocator, &out.writer, &dec, vsig);
            continue;
        };
        switch (field) {
            .path => h.path = try deccode_string(&dec, vsig),
            .interface => h.interface = try deccode_string(&dec, vsig),
            .member => h.member = try deccode_string(&dec, vsig),
            .error_name => h.error_name = try deccode_string(&dec, vsig),
            .destination => h.destination = try deccode_string(&dec, vsig),
            .sender => h.sender = try deccode_string(&dec, vsig),
            .signature => h.signature = try deccode_string(&dec, vsig),
            .reply_serial => h.reply_serial = try decode_u32(&dec, vsig),
            .unix_fds => _ = try decode_u32(&dec, vsig),
        }
    }
    return h;
}

fn read_variant_sig(dec: *wire.Decoder) wire.Error![]const u8 {
    const len = dec.buf[dec.pos];
    dec.pos += 1;
    const s = dec.buf[dec.pos .. dec.pos + len];
    dec.pos += len + 1; // + nul
    return s;
}

fn deccode_string(dec: *wire.Decoder, vsig: []const u8) wire.Error![]const u8 {
    if (vsig.len != 1 or (vsig[0] != 's' and vsig[0] != 'o' and vsig[0] != 'g'))
        return error.TypeMismatch;
    if (vsig[0] == 'g') {
        const len = dec.buf[dec.pos];
        dec.pos += 1;
        const s = dec.buf[dec.pos .. dec.pos + len];
        dec.pos += len + 1;
        return s;
    }
    dec.pos = std.mem.alignForward(usize, dec.pos, 4);
    const len = std.mem.readInt(u32, dec.buf[dec.pos..][0..4], dec.endian);
    dec.pos += 4;
    const s = dec.buf[dec.pos .. dec.pos + len];
    dec.pos += len + 1;
    return s;
}

fn decode_u32(dec: *wire.Decoder, vsig: []const u8) wire.Error!u32 {
    if (vsig.len != 1 or vsig[0] != 'u') return error.TypeMismatch;
    dec.pos = std.mem.alignForward(usize, dec.pos, 4);
    const v = std.mem.readInt(u32, dec.buf[dec.pos..][0..4], dec.endian);
    dec.pos += 4;
    return v;
}

pub const Encode = struct {
    type: Type,
    serial: u32,
    flags: Flags = .{},
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: []const u8 = "",
    args: []const u8 = &.{},
};

pub fn encode(gpa: Allocator, msg: Encode) wire.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var enc = wire.Encoder.init(gpa, &buf, .little);

    try enc.byte('l');
    try enc.byte(@intFromEnum(msg.type));
    try enc.byte(@as(u8, @bitCast(msg.flags)));
    try enc.byte(protocol_version);
    try enc.int(u32, 0); // body length, backpatched below
    try enc.int(u32, msg.serial);

    // Header fields: a(yv). Reserve the array length, then backpatch.
    try enc.int(u32, 0);
    const fields_len_pos = enc.pos() - 4;
    const fields_start = enc.pos();

    if (msg.path) |v| try encode_field(&enc, .path, 'o', v);
    if (msg.interface) |v| try encode_field(&enc, .interface, 's', v);
    if (msg.member) |v| try encode_field(&enc, .member, 's', v);
    if (msg.error_name) |v| try encode_field(&enc, .error_name, 's', v);
    if (msg.destination) |v| try encode_field(&enc, .destination, 's', v);
    if (msg.reply_serial) |v| try encode_field_u32(&enc, .reply_serial, v);
    if (msg.signature.len > 0) try encode_field(&enc, .signature, 'g', msg.signature);

    const fields_len: u32 = @intCast(enc.pos() - fields_start);
    std.mem.writeInt(u32, buf.items[fields_len_pos..][0..4], fields_len, .little);

    try enc.pad(8); // body starts 8-aligned
    const body_start = enc.pos();
    if (msg.signature.len > 0)
        try wire.encode_sig(&enc, msg.signature, msg.args);
    const body_len: u32 = @intCast(enc.pos() - body_start);
    std.mem.writeInt(u32, buf.items[4..8], body_len, .little);

    return buf.toOwnedSlice(gpa);
}

fn encode_field(enc: *wire.Encoder, field: Field, type_code: u8, value: []const u8) wire.Error!void {
    try enc.pad(8); // struct
    try enc.byte(@intFromEnum(field));
    try enc.signature(&.{type_code});
    switch (type_code) {
        's', 'o' => try enc.string(value),
        'g' => try enc.signature(value),
        else => unreachable,
    }
}

fn encode_field_u32(enc: *wire.Encoder, field: Field, value: u32) wire.Error!void {
    try enc.pad(8);
    try enc.byte(@intFromEnum(field));
    try enc.signature("u");
    try enc.int(u32, value);
}

const testing = std.testing;

test "encode/parse method_call round trips header + body" {
    const gpa = testing.allocator;

    var args_buf: [128]u8 = undefined;
    const args = cbor.fmt(&args_buf, .{ "org.freedesktop.appearance", "color-scheme" });

    const buf = try encode(gpa, .{
        .type = .method_call,
        .serial = 1,
        .destination = "org.freedesktop.portal.Desktop",
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.Settings",
        .member = "Read",
        .signature = "ss",
        .args = args,
    });
    defer gpa.free(buf);

    const total = (try frame_length(buf)).?;
    try testing.expectEqual(buf.len, total);

    const h = try parse(buf);
    try testing.expectEqual(Type.method_call, h.type);
    try testing.expectEqual(@as(u32, 1), h.serial);
    try testing.expectEqualStrings("org.freedesktop.portal.Desktop", h.destination.?);
    try testing.expectEqualStrings("/org/freedesktop/portal/desktop", h.path.?);
    try testing.expectEqualStrings("org.freedesktop.portal.Settings", h.interface.?);
    try testing.expectEqualStrings("Read", h.member.?);
    try testing.expectEqualStrings("ss", h.signature);

    // decode the body back to cbor and confirm it matches what we sent
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var dec = wire.Decoder.init(buf, h.body_start, h.endian);
    try wire.decode_sig(gpa, &out.writer, &dec, h.signature);
    try testing.expectEqualSlices(u8, args, out.written());
}

test "frame_length reports need-more-bytes" {
    const gpa = testing.allocator;
    const buf = try encode(gpa, .{
        .type = .signal,
        .serial = 7,
        .path = "/x",
        .interface = "a.b",
        .member = "C",
    });
    defer gpa.free(buf);

    try testing.expectEqual(@as(?usize, null), try frame_length(buf[0..3]));
    try testing.expectEqual(@as(?usize, null), try frame_length(buf[0 .. buf.len - 1]));
    try testing.expectEqual(@as(?usize, buf.len), try frame_length(buf));
}
