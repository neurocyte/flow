storage: *Storage,

pub const GraphemeCache = @This();

pub inline fn put(self: *@This(), bytes: []const u8) []u8 {
    return self.storage.put(bytes);
}

pub const Storage = struct {
    buf: [1024 * 512]u8 = undefined,
    idx: usize = 0,

    pub fn put(self: *@This(), bytes: []const u8) []u8 {
        if (self.idx + bytes.len > self.buf.len) self.idx = 0;
        defer self.idx += bytes.len;
        @memcpy(self.buf[self.idx .. self.idx + bytes.len], bytes);
        return self.buf[self.idx .. self.idx + bytes.len];
    }

    pub fn cache(self: *@This()) GraphemeCache {
        return .{ .storage = self };
    }
};
