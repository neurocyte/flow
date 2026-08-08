//! An ANSI VT Parser
const Parser = @This();

const std = @import("std");
const Reader = std.Io.Reader;
const ansi = @import("ansi.zig");

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

buf: std.array_list.Managed(u8),
/// a leftover byte from a ground event
pending_byte: ?u8 = null,
/// Parser state for resuming mid-escape-sequence across partial reads
state: State = .ground,
/// Saved CSI state across partial reads
csi_intermediate: ?u8 = null,
csi_pm: ?u8 = null,
/// Number of UTF-8 continuation bytes still needed to complete the current character
utf8_remaining: u3 = 0,
/// Same, but for a multi-byte character inside an OSC string.
osc_utf8_remaining: u3 = 0,

const State = enum {
    ground,
    /// Saw ESC but haven't read the next byte yet (split read after bare ESC)
    esc_seen,
    /// Saw ESC + intermediate byte(s); buf contains them; reading final byte
    escape,
    /// Mid-way through a CSI sequence; buf has params so far
    csi,
    /// Mid-way through an OSC sequence; buf has content so far
    osc,
    /// Mid-way through a multi-byte UTF-8 character; utf8_remaining bytes still needed
    ground_utf8,
};

pub fn parseReader(self: *Parser, reader: *Reader) !Event {
    // Only clear buf when starting fresh, not when resuming a partial escape sequence.
    if (self.state == .ground) self.buf.clearRetainingCapacity();

    // Resume an in-progress escape sequence (split across two reads).
    if (self.state == .esc_seen) {
        self.state = .ground;
        // Re-enter the ESC dispatch with the next byte
        const next = try reader.takeByte();
        switch (next) {
            0x4E => return .{ .ss2 = try reader.takeByte() },
            0x4F => return .{ .ss3 = try reader.takeByte() },
            0x50 => try skipUntilST(reader), // DCS
            0x58 => try skipUntilST(reader), // SOS
            0x5B => return self.parseCsi(reader), // CSI
            0x5D => return self.parseOsc(reader), // OSC
            0x5E => try skipUntilST(reader), // PM
            0x5F => return self.parseApc(reader), // APC
            0x20...0x2F => {
                try self.buf.append(next);
                return self.parseEscape(reader);
            },
            else => {
                try self.buf.append(next);
                return .{ .escape = self.buf.items };
            },
        }
    }
    if (self.state == .escape) {
        self.state = .ground;
        return self.parseEscape(reader);
    }
    if (self.state == .ground_utf8) {
        return self.resumeGroundUtf8(reader);
    }

    if (self.state == .csi) {
        self.state = .ground;
        return self.resumeCsi(reader);
    }
    if (self.state == .osc) {
        self.state = .ground;
        return self.resumeOsc(reader);
    }

    while (true) {
        const b = if (self.pending_byte) |p| p else try reader.takeByte();
        self.pending_byte = null;
        switch (b) {
            // Escape sequence
            0x1b => {
                self.buf.clearRetainingCapacity();
                const next = reader.takeByte() catch |e| switch (e) {
                    error.EndOfStream => {
                        self.state = .esc_seen;
                        return error.EndOfStream;
                    },
                    else => return e,
                };
                switch (next) {
                    0x4E => return .{ .ss2 = try reader.takeByte() },
                    0x4F => return .{ .ss3 = try reader.takeByte() },
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
            // Single-byte C1 controls, mapped to their 7-bit escape equivalents.
            0x84 => return try self.c1Escape('D'), // IND
            0x85 => return try self.c1Escape('E'), // NEL
            0x88 => return try self.c1Escape('H'), // HTS
            0x8d => return try self.c1Escape('M'), // RI
            0x8e => return .{ .ss2 = try reader.takeByte() }, // SS2
            0x8f => return .{ .ss3 = try reader.takeByte() }, // SS3
            // 8-bit string introducers.
            0x90, 0x98, 0x9e => try skipUntilST(reader), // DCS / SOS / PM
            0x9b => return self.parseCsi(reader), // CSI
            0x9d => return self.parseOsc(reader), // OSC
            0x9f => return self.parseApc(reader), // APC
            // Remaining C1 controls (including ST 0x9c) have no ground effect.
            0x80...0x83, 0x86, 0x87, 0x89...0x8c, 0x91...0x97, 0x99, 0x9a, 0x9c => {},
            else => {
                try self.buf.append(b);
                return self.parseGround(reader);
            },
        }
    }
}

/// Emit a single-byte C1 control as its 7-bit ESC-final equivalent.
fn c1Escape(self: *Parser, final: u8) !Event {
    self.buf.clearRetainingCapacity();
    try self.buf.append(final);
    return .{ .escape = self.buf.items };
}

/// Returns the number of continuation bytes expected after a given start byte,
/// or 0 if the byte is not a valid multi-byte start byte (treat as single byte).
fn utf8ContinuationCount(b: u8) u3 {
    return switch (b) {
        0x00...0x7F => 0, // ASCII, no continuations
        0xC0...0xDF => 1,
        0xE0...0xEF => 2,
        0xF0...0xF7 => 3,
        else => 0, // continuation byte or overlong - treat as single byte
    };
}

inline fn parseGround(self: *Parser, reader: *Reader) !Event {
    var buf: [1]u8 = undefined;
    {
        std.debug.assert(self.buf.items.len > 0);
        // Complete the first character already started in buf.
        const remaining = utf8ContinuationCount(self.buf.items[0]);
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            const read = try reader.readSliceShort(&buf);
            if (read == 0) {
                // Split read: save how many continuation bytes we still need.
                self.utf8_remaining = @intCast(remaining - i);
                self.state = .ground_utf8;
                return error.EndOfStream;
            }
            // If the next byte isn't a continuation byte, the sequence is malformed.
            // Emit what we have so far and leave the unexpected byte for the next event.
            if (buf[0] & 0xC0 != 0x80) {
                self.pending_byte = buf[0];
                return .{ .print = self.buf.items };
            }
            try self.buf.append(buf[0]);
        }
    }
    // Greedy loop: keep accumulating characters while data is available.
    return self.parseGroundGreedy(reader);
}

inline fn parseGroundGreedy(self: *Parser, reader: *Reader) !Event {
    var buf: [1]u8 = undefined;
    while (true) {
        if (reader.bufferedLen() == 0) return .{ .print = self.buf.items };
        const n = try reader.readSliceShort(&buf);
        if (n == 0) return .{ .print = self.buf.items };
        const b = buf[0];
        switch (b) {
            0x00...0x1f, 0x80...0x9f => {
                self.pending_byte = b;
                return .{ .print = self.buf.items };
            },
            else => {
                try self.buf.append(b);
                const remaining = utf8ContinuationCount(b);
                var i: usize = 0;
                while (i < remaining) : (i += 1) {
                    const read = try reader.readSliceShort(&buf);
                    if (read == 0) {
                        self.utf8_remaining = @intCast(remaining - i);
                        self.state = .ground_utf8;
                        return error.EndOfStream;
                    }
                    if (buf[0] & 0xC0 != 0x80) {
                        // Malformed: strip the incomplete start byte and any partial continuations.
                        for (0..i + 1) |_| _ = self.buf.pop();
                        self.pending_byte = buf[0];
                        return .{ .print = self.buf.items };
                    }
                    try self.buf.append(buf[0]);
                }
            },
        }
    }
}

/// Resume a multi-byte UTF-8 character that was split across a read boundary.
inline fn resumeGroundUtf8(self: *Parser, reader: *Reader) !Event {
    var buf: [1]u8 = undefined;
    var remaining = self.utf8_remaining;
    while (remaining > 0) : (remaining -= 1) {
        const read = try reader.readSliceShort(&buf);
        if (read == 0) {
            self.utf8_remaining = remaining;
            return error.EndOfStream;
        }
        if (buf[0] & 0xC0 != 0x80) {
            // Malformed continuation - emit what we have, re-queue byte
            self.utf8_remaining = 0;
            self.state = .ground;
            self.pending_byte = buf[0];
            return .{ .print = self.buf.items };
        }
        try self.buf.append(buf[0]);
    }
    self.utf8_remaining = 0;
    self.state = .ground;
    // Continue greedy accumulation now that the character is complete.
    // We call parseGroundGreedy directly to avoid re-completing the first byte.
    return self.parseGroundGreedy(reader);
}

/// parse until b >= 0x30
/// also appends intermediate bytes (0x20-0x2F) to buf so callers can inspect them
inline fn parseEscape(self: *Parser, reader: *Reader) !Event {
    while (true) {
        const b = reader.takeByte() catch |e| switch (e) {
            error.EndOfStream => {
                // Partial sequence - save state so next call resumes here
                self.state = .escape;
                return error.EndOfStream;
            },
            else => return e,
        };
        switch (b) {
            0x20...0x2F => try self.buf.append(b), // collect intermediates
            else => {
                try self.buf.append(b);
                return .{ .escape = self.buf.items };
            },
        }
    }
}

inline fn parseApc(self: *Parser, reader: *Reader) !Event {
    while (true) {
        const b = try reader.takeByte();
        switch (b) {
            0x00...0x17,
            0x19,
            0x1c...0x1f,
            => continue,
            0x1b => {
                _ = reader.discard(std.Io.Limit.limited(1)) catch {};
                return .{ .apc = self.buf.items };
            },
            0x9c => return .{ .apc = self.buf.items },
            else => try self.buf.append(b),
        }
    }
}

/// Skips sequences until we see an ST (String Terminator, 7-bit ESC \ or 8-bit 0x9c)
inline fn skipUntilST(reader: *Reader) !void {
    while (true) {
        switch (try reader.takeByte()) {
            0x1b => {
                _ = reader.discard(std.Io.Limit.limited(1)) catch {};
                return;
            },
            0x9c => return,
            else => {},
        }
    }
}

/// Parses an OSC sequence
inline fn parseOsc(self: *Parser, reader: *Reader) !Event {
    self.osc_utf8_remaining = 0;
    return self.resumeOsc(reader);
}

inline fn resumeOsc(self: *Parser, reader: *Reader) !Event {
    while (true) {
        const b = reader.takeByte() catch |e| switch (e) {
            error.EndOfStream => {
                self.state = .osc;
                return error.EndOfStream;
            },
            else => return e,
        };
        // Consume UTF-8 continuation bytes as content.
        if (self.osc_utf8_remaining > 0) {
            if (b & 0xc0 == 0x80) { // 0x80..0xbf: a continuation byte
                self.osc_utf8_remaining -= 1;
                try self.buf.append(b);
                continue;
            }
            self.osc_utf8_remaining = 0; // malformed sequence; handle b normally
        }
        switch (b) {
            0x00...0x06,
            0x08...0x17,
            0x19,
            0x1c...0x1f,
            => continue,
            0x1b => {
                // ST = ESC \. Consume the \ if present; if split across reads,
                // save state so the \ is discarded on resume rather than leaking.
                _ = reader.discard(std.Io.Limit.limited(1)) catch {};
                return .{ .osc = self.buf.items };
            },
            // BEL or a standalone 8-bit ST terminates.
            0x07, 0x9c => return .{ .osc = self.buf.items },
            0xc2...0xf4 => { // UTF-8 lead byte: following continuation bytes are content
                self.osc_utf8_remaining = @intCast((std.unicode.utf8ByteSequenceLength(b) catch 1) - 1);
                try self.buf.append(b);
            },
            else => try self.buf.append(b),
        }
    }
}

inline fn parseCsi(self: *Parser, reader: *Reader) !Event {
    self.csi_intermediate = null;
    self.csi_pm = null;
    return self.resumeCsi(reader);
}

inline fn resumeCsi(self: *Parser, reader: *Reader) !Event {
    while (true) {
        const b = reader.takeByte() catch |e| switch (e) {
            error.EndOfStream => {
                self.state = .csi;
                return error.EndOfStream;
            },
            else => return e,
        };
        switch (b) {
            0x20...0x2F => self.csi_intermediate = b,
            0x30...0x3B => try self.buf.append(b),
            0x3C...0x3F => self.csi_pm = b,
            // Really we should execute C0 controls, but we just ignore them
            0x40...0xFF => return .{
                .csi = .{
                    .intermediate = self.csi_intermediate,
                    .private_marker = self.csi_pm,
                    .params = self.buf.items,
                    .final = b,
                },
            },
            else => continue,
        }
    }
}
