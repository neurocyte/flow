//! D-Bus wire format codec.
//!
//! Marshalling is signature-directed in both directions. D-Bus values are
//! represented as CBOR so the rest of the layer can treat them as opaque
//! actor-message payloads:
//!
//!   byte/int16/uint16/int32/uint32/int64/uint64/unix_fd -> cbor int
//!   boolean -> cbor bool
//!   double -> cbor float
//!   string/object_path/signature -> cbor text
//!   array `a<t>` -> cbor array
//!   array of dict entries `a{kv}` -> cbor map
//!   struct `(...)` -> cbor array
//!   variant `v` -> the contained value
//!
//! Variants are unwrapped transparently on decode (nested variants collapse to
//! the innermost value). On encode a variant is written as a two element cbor
//! array `[signature, value]` so the inner type is unambiguous.

const std = @import("std");
const cbor = @import("cbor");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Endian = std.builtin.Endian;

pub const Error = error{
    /// The declared signature contains a type code we do not implement.
    UnsupportedType,
    /// The signature is malformed (unbalanced `()`/`{}`, dangling `a`, ...).
    InvalidSignature,
    /// The message body is shorter than its signature requires.
    ShortBody,
    /// A cbor argument did not match the type the signature required.
    TypeMismatch,
} || cbor.Error || Allocator.Error || Writer.Error;

/// Alignment in bytes of the on-the-wire representation of `code`.
fn align_of(code: u8) Error!usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{', 'r', 'e' => 8,
        else => error.UnsupportedType,
    };
}

/// Return the slice of `sig` spanning one complete single type starting at
/// `sig[i.*]`, advancing `i` past it. Handles nested containers.
pub fn complete_type(sig: []const u8, i: *usize) Error![]const u8 {
    const start = i.*;
    if (start >= sig.len) return error.InvalidSignature;
    const code = sig[start];
    i.* += 1;
    switch (code) {
        'a' => _ = try complete_type(sig, i), // element type follows
        '(' => try skip_until(sig, i, '(', ')'),
        '{' => try skip_until(sig, i, '{', '}'),
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => {},
        else => return error.UnsupportedType,
    }
    return sig[start..i.*];
}

/// Advance `i` past a run opened by `open` (already consumed) up to and
/// including its matching `close`, respecting nesting.
fn skip_until(sig: []const u8, i: *usize, open: u8, close: u8) Error!void {
    var depth: usize = 1;
    while (i.* < sig.len) {
        const c = sig[i.*];
        i.* += 1;
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return;
        }
    }
    return error.InvalidSignature;
}

/// Count the top level complete types in `sig` (i.e. the argument count).
pub fn type_count(sig: []const u8) Error!usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < sig.len) : (n += 1) _ = try complete_type(sig, &i);
    return n;
}

pub const Decoder = struct {
    buf: []const u8,
    pos: usize,
    endian: Endian,

    pub fn init(buf: []const u8, pos: usize, endian: Endian) Decoder {
        return .{ .buf = buf, .pos = pos, .endian = endian };
    }

    fn alignTo(self: *Decoder, a: usize) void {
        self.pos = std.mem.alignForward(usize, self.pos, a);
    }

    fn take(self: *Decoder, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return error.ShortBody;
        defer self.pos += n;
        return self.buf[self.pos .. self.pos + n];
    }

    fn int(self: *Decoder, comptime T: type) Error!T {
        self.alignTo(@sizeOf(T));
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], self.endian);
    }

    fn string(self: *Decoder) Error![]const u8 {
        const len = try self.int(u32);
        const s = try self.take(len);
        self.pos += 1; // trailing nul
        return s;
    }

    fn sig(self: *Decoder) Error![]const u8 {
        const len = (try self.take(1))[0];
        const s = try self.take(len);
        self.pos += 1; // trailing nul
        return s;
    }
};

/// Decode `sig` worth of values from `dec` and write them as a cbor array.
pub fn decode_sig(gpa: Allocator, w: *Writer, dec: *Decoder, sig: []const u8) Error!void {
    try cbor.writeArrayHeader(w, try type_count(sig));
    var i: usize = 0;
    while (i < sig.len) {
        const t = try complete_type(sig, &i);
        try decode_value(gpa, w, dec, t);
    }
}

/// Decode one complete value of type `t` and write its cbor representation.
pub fn decode_value(gpa: Allocator, w: *Writer, dec: *Decoder, t: []const u8) Error!void {
    switch (t[0]) {
        'y' => try cbor.writeValue(w, (try dec.take(1))[0]),
        'b' => try cbor.writeValue(w, (try dec.int(u32)) != 0),
        'n' => try cbor.writeValue(w, try dec.int(i16)),
        'q' => try cbor.writeValue(w, try dec.int(u16)),
        'i' => try cbor.writeValue(w, try dec.int(i32)),
        'u', 'h' => try cbor.writeValue(w, try dec.int(u32)),
        'x' => try cbor.writeValue(w, try dec.int(i64)),
        't' => try cbor.writeValue(w, try dec.int(u64)),
        'd' => {
            const bits = try dec.int(u64);
            try cbor.writeValue(w, @as(f64, @bitCast(bits)));
        },
        's', 'o' => try cbor.writeValue(w, try dec.string()),
        'g' => try cbor.writeValue(w, try dec.sig()),
        'v' => {
            const inner = try dec.sig();
            var i: usize = 0;
            const it = try complete_type(inner, &i);
            try decode_value(gpa, w, dec, it); // transparent unwrap
        },
        'a' => try decode_array(gpa, w, dec, t[1..]),
        '(' => {
            dec.alignTo(8);
            const fields = t[1 .. t.len - 1];
            try cbor.writeArrayHeader(w, try type_count(fields));
            var i: usize = 0;
            while (i < fields.len) {
                const ft = try complete_type(fields, &i);
                try decode_value(gpa, w, dec, ft);
            }
        },
        else => return error.UnsupportedType,
    }
}

fn decode_array(gpa: Allocator, w: *Writer, dec: *Decoder, elem: []const u8) Error!void {
    const nbytes = try dec.int(u32);
    dec.alignTo(try align_of(elem[0]));
    const end = dec.pos + nbytes;

    // `a{kv}` becomes a cbor map; any other element type a cbor array.
    const is_dict = elem[0] == '{';

    var scratch: Writer.Allocating = .init(gpa);
    defer scratch.deinit();
    var count: usize = 0;
    while (dec.pos < end) : (count += 1) {
        if (is_dict) {
            dec.alignTo(8); // dict entry alignment
            const body = elem[1 .. elem.len - 1];
            var i: usize = 0;
            const kt = try complete_type(body, &i);
            const vt = body[i..];
            try decode_value(gpa, &scratch.writer, dec, kt);
            try decode_value(gpa, &scratch.writer, dec, vt);
        } else {
            try decode_value(gpa, &scratch.writer, dec, elem);
        }
    }
    if (is_dict) try cbor.writeMapHeader(w, count) else try cbor.writeArrayHeader(w, count);
    try w.writeAll(scratch.written());
}

/// Appends D-Bus encoded bytes; alignment is relative to the buffer start, so
/// the buffer must begin at the message's first byte.
pub const Encoder = struct {
    buf: *std.ArrayListUnmanaged(u8),
    gpa: Allocator,
    endian: Endian,

    pub fn init(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), endian: Endian) Encoder {
        return .{ .buf = buf, .gpa = gpa, .endian = endian };
    }

    pub fn pos(self: *const Encoder) usize {
        return self.buf.items.len;
    }

    pub fn pad(self: *Encoder, a: usize) Error!void {
        const target = std.mem.alignForward(usize, self.buf.items.len, a);
        try self.buf.appendNTimes(self.gpa, 0, target - self.buf.items.len);
    }

    pub fn byte(self: *Encoder, v: u8) Error!void {
        try self.buf.append(self.gpa, v);
    }

    pub fn int(self: *Encoder, comptime T: type, v: T) Error!void {
        try self.pad(@sizeOf(T));
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, self.endian);
        try self.buf.appendSlice(self.gpa, &tmp);
    }

    pub fn string(self: *Encoder, s: []const u8) Error!void {
        try self.int(u32, @intCast(s.len));
        try self.buf.appendSlice(self.gpa, s);
        try self.byte(0);
    }

    pub fn signature(self: *Encoder, s: []const u8) Error!void {
        try self.byte(@intCast(s.len));
        try self.buf.appendSlice(self.gpa, s);
        try self.byte(0);
    }
};

/// Encode a cbor array of `args` into `enc` according to `sig`.
pub fn encode_sig(enc: *Encoder, sig: []const u8, args_cbor: []const u8) Error!void {
    var it = args_cbor;
    const n = cbor.decodeArrayHeader(&it) catch return error.TypeMismatch;
    var i: usize = 0;
    var seen: usize = 0;
    while (i < sig.len) : (seen += 1) {
        const t = try complete_type(sig, &i);
        if (seen >= n) return error.TypeMismatch;
        try encode_value(enc, t, &it);
    }
}

/// Encode one value of type `t`, consuming one cbor value from `it`.
pub fn encode_value(enc: *Encoder, t: []const u8, it: *[]const u8) Error!void {
    switch (t[0]) {
        'y' => try enc.byte(@intCast(try take_int(it, u8))),
        'b' => try enc.int(u32, if (try take_bool(it)) 1 else 0),
        'n' => try enc.int(i16, @intCast(try take_int(it, i64))),
        'q' => try enc.int(u16, @intCast(try take_int(it, u64))),
        'i' => try enc.int(i32, @intCast(try take_int(it, i64))),
        'u', 'h' => try enc.int(u32, @intCast(try take_int(it, u64))),
        'x' => try enc.int(i64, try take_int(it, i64)),
        't' => try enc.int(u64, try take_int(it, u64)),
        'd' => {
            var f: f64 = 0;
            if (!try cbor.matchValue(it, cbor.extract(&f))) return error.TypeMismatch;
            try enc.int(u64, @bitCast(f));
        },
        's', 'o' => try enc.string(try take_string(it)),
        'g' => try enc.signature(try take_string(it)),
        'v' => try encode_variant(enc, it),
        'a' => try encode_array(enc, t[1..], it),
        '(' => {
            var elems: []const u8 = undefined;
            if (!try cbor.matchValue(it, cbor.extract_cbor(&elems))) return error.TypeMismatch;
            var ei = elems;
            _ = cbor.decodeArrayHeader(&ei) catch return error.TypeMismatch;
            try enc.pad(8);
            const fields = t[1 .. t.len - 1];
            var i: usize = 0;
            while (i < fields.len) {
                const ft = try complete_type(fields, &i);
                try encode_value(enc, ft, &ei);
            }
        },
        else => return error.UnsupportedType,
    }
}

/// A variant is `[signature, value]` in cbor.
fn encode_variant(enc: *Encoder, it: *[]const u8) Error!void {
    var pair: []const u8 = undefined;
    if (!try cbor.matchValue(it, cbor.extract_cbor(&pair))) return error.TypeMismatch;
    var pi = pair;
    const n = cbor.decodeArrayHeader(&pi) catch return error.TypeMismatch;
    if (n != 2) return error.TypeMismatch;
    const inner_sig = try take_string(&pi);
    try enc.signature(inner_sig);
    var si: usize = 0;
    const vt = try complete_type(inner_sig, &si);
    try encode_value(enc, vt, &pi);
}

fn encode_array(enc: *Encoder, elem: []const u8, it: *[]const u8) Error!void {
    const is_dict = elem[0] == '{';

    var body: []const u8 = undefined;
    if (is_dict) {
        if (!try cbor.matchValue(it, cbor.extract_cbor(&body))) return error.TypeMismatch;
    } else {
        if (!try cbor.matchValue(it, cbor.extract_cbor(&body))) return error.TypeMismatch;
    }
    var bi = body;
    const count = if (is_dict)
        cbor.decodeMapHeader(&bi) catch return error.TypeMismatch
    else
        cbor.decodeArrayHeader(&bi) catch return error.TypeMismatch;

    // Reserve the u32 length, then backpatch it once the body is written.
    try enc.int(u32, 0);
    const len_pos = enc.pos() - 4;
    try enc.pad(try align_of(elem[0]));
    const content_start = enc.pos();

    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (is_dict) {
            try enc.pad(8);
            const dbody = elem[1 .. elem.len - 1];
            var i: usize = 0;
            const kt = try complete_type(dbody, &i);
            const vt = dbody[i..];
            try encode_value(enc, kt, &bi);
            try encode_value(enc, vt, &bi);
        } else {
            try encode_value(enc, elem, &bi);
        }
    }
    const nbytes: u32 = @intCast(enc.pos() - content_start);
    std.mem.writeInt(u32, enc.buf.items[len_pos..][0..4], nbytes, enc.endian);
}

fn take_int(it: *[]const u8, comptime T: type) Error!T {
    var v: T = 0;
    if (!try cbor.matchValue(it, cbor.extract(&v))) return error.TypeMismatch;
    return v;
}

fn take_bool(it: *[]const u8) Error!bool {
    var v: bool = false;
    if (!try cbor.matchValue(it, cbor.extract(&v))) return error.TypeMismatch;
    return v;
}

fn take_string(it: *[]const u8) Error![]const u8 {
    var v: []const u8 = "";
    if (!try cbor.matchValue(it, cbor.extract(&v))) return error.TypeMismatch;
    return v;
}

const testing = std.testing;

fn expectRoundTrip(sig: []const u8, args: anytype) !void {
    const allocator = testing.allocator;

    var args_buf: [512]u8 = undefined;
    const args_cbor = cbor.fmt(&args_buf, args);

    // encode cbor args -> dbus bytes (body starts 8-aligned in a real message)
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    var enc = Encoder.init(allocator, &body, .little);
    try encode_sig(&enc, sig, args_cbor);

    // decode dbus bytes -> cbor args and compare
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var dec = Decoder.init(body.items, 0, .little);
    try decode_sig(allocator, &out.writer, &dec, sig);

    try testing.expectEqualSlices(u8, args_cbor, out.written());
    try testing.expectEqual(body.items.len, dec.pos);
}

test "scalars round trip" {
    try expectRoundTrip("s", .{"hello"});
    try expectRoundTrip("u", .{@as(u32, 2)});
    try expectRoundTrip("ss", .{ "org.freedesktop.appearance", "color-scheme" });
    try expectRoundTrip("ybnqiuxt", .{
        @as(u8, 0xab), true,         @as(i16, -3),  @as(u16, 7),
        @as(i32, -9),  @as(u32, 11), @as(i64, -13), @as(u64, 15),
    });
}

test "array and struct round trip" {
    try expectRoundTrip("as", .{.{ "a", "bb", "ccc" }});
    try expectRoundTrip("au", .{.{ @as(u32, 1), @as(u32, 2), @as(u32, 3) }});
    try expectRoundTrip("(su)", .{.{ "x", @as(u32, 42) }});
}

test "variant unwraps on decode" {
    const allocator = testing.allocator;

    // encode a `v` holding a u32 from the [signature, value] cbor form
    var args_buf: [64]u8 = undefined;
    const args_cbor = cbor.fmt(&args_buf, .{.{ "u", @as(u32, 1) }});

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    var enc = Encoder.init(allocator, &body, .little);
    try encode_sig(&enc, "v", args_cbor);

    // decode transparently yields just the value: [1]
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var dec = Decoder.init(body.items, 0, .little);
    try decode_sig(allocator, &out.writer, &dec, "v");

    var expect_buf: [16]u8 = undefined;
    const expect = cbor.fmt(&expect_buf, .{@as(u32, 1)});
    try testing.expectEqualSlices(u8, expect, out.written());
}

test "dict decodes to map" {
    const allocator = testing.allocator;

    // build a{sv} by hand: { "k": variant u32(2) } via encode
    var args_buf: [128]u8 = undefined;
    const args_cbor = cbor.fmt(&args_buf, .{.{ .k = .{ "u", @as(u32, 2) } }});

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    var enc = Encoder.init(allocator, &body, .little);
    try encode_sig(&enc, "a{sv}", args_cbor);

    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var dec = Decoder.init(body.items, 0, .little);
    try decode_sig(allocator, &out.writer, &dec, "a{sv}");

    // decoded map has variant unwrapped: { "k": 2 }
    var expect_buf: [64]u8 = undefined;
    const expect = cbor.fmt(&expect_buf, .{.{ .k = @as(u32, 2) }});
    try testing.expectEqualSlices(u8, expect, out.written());
}

test "signature helpers" {
    try testing.expectEqual(@as(usize, 2), try type_count("ss"));
    try testing.expectEqual(@as(usize, 1), try type_count("a{sv}"));
    try testing.expectEqual(@as(usize, 3), try type_count("ysv"));
    var i: usize = 0;
    try testing.expectEqualSlices(u8, "a{sv}", try complete_type("a{sv}s", &i));
    try testing.expectEqualSlices(u8, "s", try complete_type("a{sv}s", &i));
}
