pub const dizzy = @import("dizzy.zig");
pub const diffz = @import("diffz.zig");

pub const Kind = enum { insert, delete };
pub const Diff = struct {
    kind: Kind,
    line: usize,
    offset: usize,
    start: usize,
    end: usize,
    bytes: []const u8,
};

pub const Edit = struct {
    kind: Kind,
    start: usize,
    end: usize,
    bytes: []const u8,
};
