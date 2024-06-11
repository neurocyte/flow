//! An ANSI VT Parser
const Parser = @This();

const std = @import("std");
const Reader = std.io.AnyReader;
const ansi = @import("ansi.zig");
const BufferedReader = std.io.BufferedReader(4096, std.io.AnyReader);

/// A terminal event
const Event = union(enum) {
    print: []const u8,
    c0: ansi.C0,
    escape: []const u8,
    ss2: u8,
    ss3: u8,
    csi: ansi.CSI,
    osc: []const u8,
    apc: []const u8,
};

buf: std.ArrayList(u8),
/// a leftover byte from a ground event
pending_byte: ?u8 = null,

pub fn parseReader(self: *Parser, buffered: *BufferedReader) !Event {
    const reader = buffered.reader().any();
    self.buf.clearRetainingCapacity();
    while (true) {
        const b = if (self.pending_byte) |p| p else try reader.readByte();
        self.pending_byte = null;
        switch (b) {
            // Escape sequence
            0x1b => {
                const next = try reader.readByte();
                switch (next) {
                    0x4E => return .{ .ss2 = try reader.readByte() },
                    0x4F => return .{ .ss3 = try reader.readByte() },
                    0x50 => try skipUntilST(reader), // DCS
                    0x58 => try skipUntilST(reader), // SOS
                    0x5B => return self.parseCsi(reader), // CSI
                    0x5D => return self.parseOsc(reader), // OSC
                    0x5E => try skipUntilST(reader), // PM
                    0x5F => return self.parseApc(reader), // APC

                    0x20...0x2F => {
                        try self.buf.append(next);
                        return self.parseEscape(reader); // ESC
                    },
                    else => {
                        try self.buf.append(next);
                        return .{ .escape = self.buf.items };
                    },
                }
            },
            // C0 control
            0x00...0x1a,
            0x1c...0x1f,
            => return .{ .c0 = @enumFromInt(b) },
            else => {
                try self.buf.append(b);
                return self.parseGround(buffered);
            },
        }
    }
}

inline fn parseGround(self: *Parser, reader: *BufferedReader) !Event {
    var buf: [1]u8 = undefined;
    {
        std.debug.assert(self.buf.items.len > 0);
        // Handle first byte
        const len = try std.unicode.utf8ByteSequenceLength(self.buf.items[0]);
        var i: usize = 1;
        while (i < len) : (i += 1) {
            const read = try reader.read(&buf);
            if (read == 0) return error.EOF;
            try self.buf.append(buf[0]);
        }
    }
    while (true) {
        if (reader.start == reader.end) return .{ .print = self.buf.items };
        const n = try reader.read(&buf);
        if (n == 0) return error.EOF;
        const b = buf[0];
        switch (b) {
            0x00...0x1f => {
                self.pending_byte = b;
                return .{ .print = self.buf.items };
            },
            else => {
                try self.buf.append(b);
                const len = try std.unicode.utf8ByteSequenceLength(b);
                var i: usize = 1;
                while (i < len) : (i += 1) {
                    const read = try reader.read(&buf);
                    if (read == 0) return error.EOF;

                    try self.buf.append(buf[0]);
                }
            },
        }
    }
}

/// parse until b >= 0x30
inline fn parseEscape(self: *Parser, reader: Reader) !Event {
    while (true) {
        const b = try reader.readByte();
        switch (b) {
            0x20...0x2F => continue,
            else => {
                try self.buf.append(b);
                return .{ .escape = self.buf.items };
            },
        }
    }
}

inline fn parseApc(self: *Parser, reader: Reader) !Event {
    while (true) {
        const b = try reader.readByte();
        switch (b) {
            0x00...0x17,
            0x19,
            0x1c...0x1f,
            => continue,
            0x1b => {
                try reader.skipBytes(1, .{ .buf_size = 1 });
                return .{ .apc = self.buf.items };
            },
            else => try self.buf.append(b),
        }
    }
}

/// Skips sequences until we see an ST (String Terminator, ESC \)
inline fn skipUntilST(reader: Reader) !void {
    try reader.skipUntilDelimiterOrEof('\x1b');
    try reader.skipBytes(1, .{ .buf_size = 1 });
}

/// Parses an OSC sequence
inline fn parseOsc(self: *Parser, reader: Reader) !Event {
    while (true) {
        const b = try reader.readByte();
        switch (b) {
            0x00...0x06,
            0x08...0x17,
            0x19,
            0x1c...0x1f,
            => continue,
            0x1b => {
                try reader.skipBytes(1, .{ .buf_size = 1 });
                return .{ .osc = self.buf.items };
            },
            0x07 => return .{ .osc = self.buf.items },
            else => try self.buf.append(b),
        }
    }
}

inline fn parseCsi(self: *Parser, reader: Reader) !Event {
    var intermediate: ?u8 = null;
    var pm: ?u8 = null;

    while (true) {
        const b = try reader.readByte();
        switch (b) {
            0x20...0x2F => intermediate = b,
            0x30...0x3B => try self.buf.append(b),
            0x3C...0x3F => pm = b, // we only allow one
            // Really we should execute C0 controls, but we just ignore them
            0x40...0xFF => return .{
                .csi = .{
                    .intermediate = intermediate,
                    .private_marker = pm,
                    .params = self.buf.items,
                    .final = b,
                },
            },
            else => continue,
        }
    }
}
