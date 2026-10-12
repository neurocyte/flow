pub const diffz = @import("diffz.zig");

pub const LineDiffKind = enum { insert, modify, delete };
pub const LineDiff = struct {
    kind: LineDiffKind,
    line: usize,
    lines: usize,
};
