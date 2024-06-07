const std = @import("std");

/// Control bytes. See man 7 ascii
pub const C0 = enum(u8) {
    NUL = 0x00,
    SOH = 0x01,
    STX = 0x02,
    ETX = 0x03,
    EOT = 0x04,
    ENQ = 0x05,
    ACK = 0x06,
    BEL = 0x07,
    BS = 0x08,
    HT = 0x09,
    LF = 0x0a,
    VT = 0x0b,
    FF = 0x0c,
    CR = 0x0d,
    SO = 0x0e,
    SI = 0x0f,
    DLE = 0x10,
    DC1 = 0x11,
    DC2 = 0x12,
    DC3 = 0x13,
    DC4 = 0x14,
    NAK = 0x15,
    SYN = 0x16,
    ETB = 0x17,
    CAN = 0x18,
    EM = 0x19,
    SUB = 0x1a,
    ESC = 0x1b,
    FS = 0x1c,
    GS = 0x1d,
    RS = 0x1e,
    US = 0x1f,
};

pub const CSI = struct {
    intermediate: ?u8 = null,
    private_marker: ?u8 = null,

    final: u8,
    params: []const u8,

    pub fn hasIntermediate(self: CSI, b: u8) bool {
        return b == self.intermediate orelse return false;
    }

    pub fn hasPrivateMarker(self: CSI, b: u8) bool {
        return b == self.private_marker orelse return false;
    }

    pub fn iterator(self: CSI, comptime T: type) ParamIterator(T) {
        return .{ .bytes = self.params };
    }

    pub fn format(
        self: CSI,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        if (self.private_marker == null and self.intermediate == null)
            try std.fmt.format(writer, "CSI {s} {c}", .{
                self.params,
                self.final,
            })
        else if (self.private_marker != null and self.intermediate == null)
            try std.fmt.format(writer, "CSI {c} {s} {c}", .{
                self.private_marker.?,
                self.params,
                self.final,
            })
        else if (self.private_marker == null and self.intermediate != null)
            try std.fmt.format(writer, "CSI {s} {c} {c}", .{
                self.params,
                self.intermediate.?,
                self.final,
            })
        else
            try std.fmt.format(writer, "CSI {c} {s} {c} {c}", .{
                self.private_marker.?,
                self.params,
                self.intermediate.?,
                self.final,
            });
    }
};

pub fn ParamIterator(T: type) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        idx: usize = 0,
        /// indicates the next parameter will be a sub parameter of the current
        next_is_sub: bool = false,
        /// indicates the current parameter was an empty string
        is_empty: bool = false,

        pub fn next(self: *Self) ?T {
            // reset state
            self.next_is_sub = false;
            self.is_empty = false;

            const start = self.idx;
            var val: T = 0;
            while (self.idx < self.bytes.len) {
                defer self.idx += 1; // defer so we trigger on return as well
                const b = self.bytes[self.idx];
                switch (b) {
                    0x30...0x39 => {
                        val = (val * 10) + (b - 0x30);
                        if (self.idx == self.bytes.len - 1) return val;
                    },
                    ':', ';' => {
                        self.next_is_sub = b == ':';
                        self.is_empty = self.idx == start;
                        return val;
                    },
                    else => return null,
                }
            }
            return null;
        }

        /// verifies there are at least n more parameters
        pub fn hasAtLeast(self: *Self, n: usize) bool {
            const start = self.idx;
            defer self.idx = start;

            var i: usize = 0;
            while (self.next()) |_| {
                i += 1;
                if (i >= n) return true;
            }
            return i >= n;
        }
    };
}
